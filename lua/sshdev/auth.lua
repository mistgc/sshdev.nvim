--- Password authentication for sshdev.nvim.
---
--- The `auth` option (setup() or a one-shot --auth=... command flag)
--- selects how authentication proceeds:
---
---   "auto" (default)
---       keys / ssh-agent first, fully non-interactive. When the server
---       REJECTS that, sshdev asks for a password once (|inputsecret()|),
---       retries and keeps it for the rest of the nvim session.
---   "password"
---       ask before the first ssh call (known password-only host; skips
---       the failed non-interactive round trip).
---   "key"
---       strictly non-interactive: never prompt or inject askpass.
---
--- Once a password is in play (entered in either mode), every ssh/scp/
--- tunnel spawn receives
---       SSH_ASKPASS=<stdpath("cache")>/sshdev/askpass.cmd|.sh
---       SSH_ASKPASS_REQUIRE=force
---       SSHDEV_PASS=<password>
--- and OpenSSH calls the helper whenever it needs a password -- from
--- piped (no tty) processes, nvim jobstart children and detached
--- `ssh -N -L` tunnels alike (verified on Windows OpenSSH 9.5p2). A
--- working key keeps working: ssh tries keys first, the helper is only
--- consulted when a password is actually needed.
---
--- The helper is a STATIC script that just prints $SSHDEV_PASS: it
--- contains no secret, so keeping it in the cache dir is harmless.
--- Clients >= 8.4 honor SSH_ASKPASS_REQUIRE; older ones get the legacy
--- DISPLAY gate as a fallback.
---
--- The password is asked ONCE per destination and kept ONLY in this
--- module's table for the lifetime of the local nvim session -- never
--- written to disk, history or the log. It therefore lives in the
--- environment of the spawned ssh/scp children (including a tunnel that
--- outlives nvim) -- the documented, accepted trade-off of this mode.

local M = {}

local Util = require('sshdev.util')

local uv = vim.uv or vim.loop

local state = {
  ---[dest_key] = password; the key is Util.format_dest(parsed) WITH the ssh
  ---port, so the same host on two ports stays two entries.
  passwords = {},
}

---Cache key for a parsed destination.
---@param parsed table
---@return string
local function dest_key(parsed)
  return Util.format_dest(parsed)
end

local function is_windows()
  return vim.fn.has('win32') == 1
end

-----------------------------------------------------------------------
-- askpass helper (static: it reads $SSHDEV_PASS, never a secret)
-----------------------------------------------------------------------

---Windows: cmd delayed expansion (!VAR!) happens AFTER the line is parsed,
---so metacharacters in the expanded value (&, |, <, >, %) cannot inject
---commands. The cost: a literal "!" in a password gets mangled (warned
---about at prompt time). NOTE: every line must end in a real CRLF pair --
---cmd reports "Invalid parameter to SETLOCAL command" for a lone CR.
local WIN_HELPER = '@echo off\r\nsetlocal enabledelayedexpansion\r\necho !SSHDEV_PASS!\r\n'

---POSIX: plain single-quoted printf; nothing re-parses the value.
local UNIX_HELPER = '#!/bin/sh\nprintf \'%s\\n\' "$SSHDEV_PASS"\n'

---Write the askpass helper (fresh every time: it is a 3-line static file,
---so rewriting is cheap, heals any stale/corrupt copy in the cache dir and
---picks up content changes after an upgrade) and return its path.
---@return string? path
---@return string? err
function M.helper_path()
  local dir = Util.fs_join(vim.fs.normalize(vim.fn.stdpath('cache')), 'sshdev')
  local path = is_windows() and Util.fs_join(dir, 'askpass.cmd') or Util.fs_join(dir, 'askpass.sh')
  local ok, merr = Util.mkdir_p(dir)
  if not ok then
    return nil, ('cannot create %s: %s'):format(dir, tostring(merr))
  end
  local fd, werr = uv.fs_open(path, 'w', 448)
  if not fd then
    return nil, ('cannot write %s: %s'):format(path, tostring(werr))
  end
  uv.fs_write(fd, is_windows() and WIN_HELPER or UNIX_HELPER, 0)
  uv.fs_close(fd)
  if not is_windows() then
    -- ssh only executes askpass programs with the executable bit set
    uv.fs_chmod(path, 448) -- 0o700
  end
  return path
end

-----------------------------------------------------------------------
-- Auth mode + password cache + prompting
-----------------------------------------------------------------------

---Normalized auth mode for a configuration:
---  "auto"      key/agent first; on rejection ask for a password once
---              and retry (the default)
---  "password"  ask before the first ssh call (known password-only host)
---  "key"       strictly non-interactive: never prompt or inject askpass
---@param cfg table
---@return string
function M.mode(cfg)
  local a = cfg and cfg.auth
  if a == 'password' or a == 'key' then
    return a
  end
  return 'auto'
end

---Is password authentication allowed at all for this configuration?
---@param cfg table
---@return boolean
function M.allows_password(cfg)
  return M.mode(cfg) ~= 'key'
end

---The cached password for a destination, if any (never prompts).
---@param parsed table
---@return string? password
function M.cached(parsed)
  return state.passwords[dest_key(parsed)]
end

---Return the password for a destination, prompting (|inputsecret()|) when
---it is not cached yet. Safe only in a main-loop context: every sshdev
---flow is resumed via vim.schedule, and the only callers (Ssh.* and
---Session.prepare_probe) run inside such flows.
---@param cfg table
---@param parsed table
---@return string? password
---@return string? err
function M.ensure(cfg, parsed)
  local key = dest_key(parsed)
  if state.passwords[key] then
    return state.passwords[key]
  end
  if vim.in_fast_event() then
    return nil, 'cannot prompt for a password from a fast event context'
  end
  if #vim.api.nvim_list_uis() == 0 then
    return nil, ('password auth needs an interactive UI: cache the password for %s '
      .. 'from a TUI/GUI session first, or use key authentication'):format(key)
  end
  local pw = vim.fn.inputsecret(('[sshdev] ssh password for %s: '):format(key))
  if type(pw) ~= 'string' or pw == '' then
    return nil, ('password entry for %s cancelled'):format(key)
  end
  if pw:find('[\r\n]') then
    return nil, 'the password contains a newline; askpass cannot pass that through'
  end
  if is_windows() and pw:find('!') then
    Util.notify('the Windows askpass helper cannot pass a "!" in a password '
      .. '(cmd delayed expansion); prefer key auth or a password without "!"', vim.log.levels.WARN)
  end
  state.passwords[key] = pw
  Util.log('password for %s cached in memory (askpass mode)', key)
  return pw
end

---Env overlay for ssh/scp spawns when a password is in play, or nil.
---
---  "key"                  always nil (strictly non-interactive)
---  "auto"                 nil until a password is cached; the overlay
---                         once one is (entered after a rejected key
---                         attempt, see Bootstrap.probe's fallback)
---  "password"             prompt when nothing is cached (unless
---                         opts.no_prompt, which then yields nil)
---
---The "password" prompt path throws a level-0 error when the entry is
---cancelled: the Ssh callers are flows whose error machinery reports the
---message, and no ssh process is ever started without the askpass
---variables. The "auto" mode never prompts here -- its prompt happens at
---the probe fallback and can fail soft.
---@param cfg table
---@param parsed table
---@param opts table|nil { no_prompt = boolean }
---@return table? env
function M.env(cfg, parsed, opts)
  local mode = M.mode(cfg)
  if mode == 'key' then
    return nil
  end
  opts = opts or {}
  local pw = M.cached(parsed)
  if not pw then
    if mode ~= 'password' or opts.no_prompt then
      return nil
    end
    local err
    pw, err = M.ensure(cfg, parsed)
    if not pw then
      error('sshdev: ' .. tostring(err), 0)
    end
  end
  local helper, herr = M.helper_path()
  if not helper then
    error('sshdev: ' .. tostring(herr), 0)
  end
  local env = {
    SSH_ASKPASS = helper,
    -- force: use askpass even when a tty exists (and without one)
    SSH_ASKPASS_REQUIRE = 'force',
    SSHDEV_PASS = pw,
  }
  if not vim.env.DISPLAY or vim.env.DISPLAY == '' then
    -- legacy gate for OpenSSH clients predating SSH_ASKPASS_REQUIRE
    env.DISPLAY = ':0'
  end
  return env
end

-----------------------------------------------------------------------
-- Auth failure detection / cache invalidation
-----------------------------------------------------------------------

---True when output carries the ssh connection-level auth rejection
---signature ("Permission denied (publickey,password).") -- as opposed to
---a remote FILE permission error, which has no method list.
---@param text string|nil
---@return boolean
function M.auth_failure_in(text)
  return (tostring(text or '')):find('Permission denied%s*%([%a,%-]+%)') ~= nil
end

---True when an await() result looks like rejected authentication.
---@param res table|nil { code, stderr }
---@return boolean
function M.is_auth_failure(res)
  return res ~= nil and M.auth_failure_in(res.stderr)
end

---True when, after an ssh attempt, the "auto" auth mode should fall back
---to asking for a password: the result looks like the server REJECTED our
---non-interactive (key/agent) authentication. Pure (unit-testable); the
---caller then prompts via ensure() and retries the step once.
---@param cfg table
---@param res table|nil await() result
---@return boolean
function M.wants_fallback(cfg, res)
  return M.mode(cfg) == 'auto' and M.is_auth_failure(res)
end

---True when a spawn must be strictly non-interactive (BatchMode): the
---auto mode has NO password cached yet, or the key mode forbids passwords
---outright. Without this, an ssh that needs a password but has no askpass
---and no console HANGS on the prompt until the command timeout kills it
---(observed on Windows jobstart children: exit 143, empty stderr) instead
---of failing fast with a "Permission denied (...)" signature.
---
---The state is read per spawn: once a fallback password is cached (or the
---password mode prompted), spawns drop BatchMode and use the askpass
---overlay instead.
---@param cfg table
---@param parsed table
---@return boolean
function M.needs_batch(cfg, parsed)
  local mode = M.mode(cfg)
  if mode == 'password' then
    return false -- env() prompts (or the cache hits) before any spawn
  end
  if mode == 'key' then
    return true
  end
  return M.cached(parsed) == nil -- auto: nothing cached -> key/agent only
end

---Drop the cached password for a destination (authentication failed; the
---next connect prompts again). Accepts a parsed table or a ready key.
---@param parsed_or_key table|string
function M.forget(parsed_or_key)
  local key = type(parsed_or_key) == 'string' and parsed_or_key or dest_key(parsed_or_key)
  if state.passwords[key] then
    state.passwords[key] = nil
    Util.log('cleared the cached password for %s (authentication rejected)', key)
  end
end

---Drop every cached password.
function M.forget_all()
  state.passwords = {}
end

---Test/integration hook: inject a cached password without prompting.
---@param key string Util.format_dest() key
---@param password string
function M._cache_set(key, password)
  state.passwords[key] = password
end

return M
