--- Custom environment variables for a workspace (`:SshDevEnv`).
---
--- The workspace's variables live in the REMOTE workspace profile:
---
---   <remote_root>/workspace-profiles/--<host>--<ws-path>--/env.txt
---
--- Strict format, one variable per line:
---
---   KEY=VALUE
---
--- `#`-lines and blank lines are ignored. The value is everything after
--- the FIRST `=` and is used VERBATIM: no quote stripping, no `$VAR`
--- expansion, no `export` prefix. A value may be empty and may contain
--- spaces, `#` and `=`.
---
--- Injection points (all fed from one in-memory "active" map):
---
---   * remote nvim server: `Ssh.run_script` prefixes every remote script
---     with `export K='V'`, so the server process is started with the
---     variables already in its environment (user config sees them at
---     startup), and the headless plugin install does too
---   * ssh/scp children: the same map is merged into the child process
---     environment (auth keys win); note that this affects the LOCAL ssh
---     client, not the remote command -- the script prefix is what the
---     remote command actually sees
---   * a RUNNING server: saving env.txt pushes the map through the RPC
---     control channel, which assigns vim.env on the server (children
---     started from now on inherit it; already started LSPs do not)
---
--- Flow (everything but open()/apply() is pure or a thin remote call):
---
---   :SshDevEnv ─► fetch the remote env.txt (ssh cat, read-only) into a
---        │         local cache mirror, or write a fresh all-commented
---        │         template when it does not exist
---        └─► open the local copy; BufWritePost on that buffer triggers
---             apply(): parse the mirror ─► scp it back to the workspace
---             profile ─► update the active map ─► push to the running
---             server when the control channel is available.
---
---   Inside the ATTACHED remote session the command opens the very same
---   file THERE and every save pushes an apply request back to the
---   CLIENT through the control channel (SSHDEV_CONTROL_CHANNEL, opened
---   by sshdev.session at attach time).
---
--- The local copy is only the EDITING MEDIUM; the remote file is the
--- source of truth and is re-uploaded on every save.

local Auth = require('sshdev.auth')
local Proc = require('sshdev.proc')
local Scripts = require('sshdev.remote_scripts')
local Ssh = require('sshdev.ssh')
local Util = require('sshdev.util')

local M = {}

local uv = vim.uv or vim.loop

---Keys sshdev itself needs on the remote side (or that would break the
---transport when exported to a local ssh/scp child). Rejected at parse time.
local RESERVED = {
  HOME = true,
  NVIM_APPNAME = true,
  SSH_ASKPASS = true,
  SSH_ASKPASS_REQUIRE = true,
  XDG_CACHE_HOME = true,
  XDG_CONFIG_HOME = true,
  XDG_DATA_HOME = true,
  XDG_STATE_HOME = true,
}

---The variables currently injected for one destination, or empty.
local active = {
  dest = nil,
  vars = {},
}

---Lua chunk run ON the remote server through the control channel. Self
---contained: the uploaded config may not include sshdev.nvim.
local APPLY_CHUNK = [[
local vars = select(1, ...)
local old = _G.SSHDEV_ENV_APPLIED
if old == nil then
  -- the server was started with these keys exported by the start script,
  -- so a later save can unset variables removed from env.txt
  old = {}
  for k in (vim.env.SSHDEV_ENV_KEYS or ''):gmatch('%S+') do
    old[k] = true
  end
end
for k in pairs(old) do
  if vars[k] == nil then
    pcall(function() vim.env[k] = nil end)
  end
end
for k, v in pairs(vars) do
  pcall(function() vim.env[k] = v end)
end
_G.SSHDEV_ENV_APPLIED = vars
]]

---Exposed for tests (the chunk is what the control channel sends).
M._runtime_chunk = APPLY_CHUNK

---Run the same set/unset logic in THIS nvim. Used by the remote-side
---editor so a save takes effect on the server even when the client
---control channel is gone; values never become Lua source.
---@param vars table<string,string>
function M.apply_runtime(vars)
  local f = assert(load(APPLY_CHUNK))
  f(vars or {})
end

-----------------------------------------------------------------------
-- Pure helpers
-----------------------------------------------------------------------

---True when sshdev reserves this key for itself / the transport.
---@param key string
---@return boolean
local function is_reserved(key)
  return key:sub(1, 7) == 'SSHDEV_' or RESERVED[key] == true
end

---Parse env.txt content into a variable map.
---
---Every problem is collected with its line number instead of failing on
---the first one, so one save can report all bad lines. A single bad line
---makes the WHOLE file non-applicable (the caller applies none of it).
---@param text string|nil
---@return table<string,string> vars
---@return string[] errs line-anchored error messages
function M.parse(text)
  local vars, errs = {}, {}
  local first_line = {} -- key -> line number of its first occurrence
  -- an editor may write a UTF-8 BOM; it is not part of the first key
  text = tostring(text or ''):gsub('^\239\187\191', '')
  local n = 0
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    n = n + 1
    line = line:gsub('\r$', '')
    if line ~= '' and line:sub(1, 1) ~= '#' then
      local key, value = line:match('^([A-Za-z_][A-Za-z0-9_]*)=(.*)$')
      if not key then
        -- never echo the raw line: it may be a secret with a typo in it
        local bad_key = line:match('^([^=]*)=')
        if bad_key then
          errs[#errs + 1] = ('line %d: invalid variable name "%s"'):format(n, bad_key)
        else
          errs[#errs + 1] = ('line %d: expected "KEY=VALUE" (a line without "=")'):format(n)
        end
      elseif value:find('\0', 1, true) then
        errs[#errs + 1] = ('line %d: the value of "%s" must not contain NUL'):format(n, key)
      elseif value:find('\r', 1, true) then
        errs[#errs + 1] = ('line %d: the value of "%s" must not contain a carriage return'):format(
          n,
          key
        )
      elseif is_reserved(key) then
        errs[#errs + 1] = ('line %d: "%s" is reserved by sshdev'):format(n, key)
      elseif first_line[key] then
        errs[#errs + 1] = ('line %d: duplicate key "%s" (already set on line %d)'):format(
          n,
          key,
          first_line[key]
        )
      else
        first_line[key] = n
        vars[key] = value
      end
    end
  end
  return vars, errs
end

---Content for a NEW env.txt. Every line is commented out, so saving the
---fresh template injects nothing; parse(template(...)) must stay { } / { }.
---@param dest string|nil display destination ("me@host[:port]")
---@param workspace string remote workspace path
---@return string
function M.template(dest, workspace)
  local head = { '# sshdev environment variables' }
  if dest and dest ~= '' then
    head[#head + 1] = ('# destination: %s'):format(dest)
  end
  head[#head + 1] = ('# workspace:   %s'):format(workspace)
  return ([[
%s
#
# One variable per line:  KEY=VALUE
# Values are used VERBATIM: quotes are not stripped, $VAR is not expanded,
# and a value may contain spaces, "#" and "=". Lines starting with "#" are
# comments; an empty file injects nothing.
#
# These variables are injected into the remote nvim server (vim.env -- LSP,
# :terminal and jobstart children inherit them) and exported into every
# script sshdev runs over ssh. Saving applies them to a running server;
# a server that is started later gets them before the user config loads.
#
# Examples -- remove the leading "# " to activate:
# NODE_ENV=development
# DATABASE_URL=postgres://127.0.0.1:5432/app
#
# Saving uploads this file to the workspace profile and applies it. Removed
# lines unset the variable at runtime; already-started LSPs need a restart.
]]):format(table.concat(head, '\n'))
end

---Local cache mirror of the workspace's env.txt (the editing medium).
---
---The workspace profile key is a validated single path segment, so it is
---used as-is; only a separator would break out of the cache dir.
---@param ws_key string workspace profile key
---@return string
function M.local_path(ws_key)
  local key = tostring(ws_key or '')
  if key == '' or key:find('[/\\]') then
    error('sshdev: invalid workspace profile key for the local env mirror: ' .. key, 0)
  end
  return Util.fs_join(
    vim.fs.normalize(vim.fn.stdpath('cache')),
    'sshdev',
    'env',
    key,
    'env.txt'
  )
end

-----------------------------------------------------------------------
-- Active environment (per destination)
-----------------------------------------------------------------------

---Remember the variables to inject for `parsed`'s destination.
---@param vars table<string,string>
---@param parsed table from Util.parse_dest()
function M.set_active(vars, parsed)
  active = { dest = Util.format_dest(parsed), vars = vim.deepcopy(vars or {}) }
end

---Forget the active environment (new flow / teardown).
function M.clear()
  active = { dest = nil, vars = {} }
end

---The active map for this destination, or nil when empty/for another dest.
---@param parsed table
---@return table<string,string>|nil
function M.active_for(parsed)
  if not parsed or active.dest ~= Util.format_dest(parsed) then
    return nil
  end
  if next(active.vars) == nil then
    return nil
  end
  return active.vars
end

---`export KEY='value'` lines to prepend to every remote script. Empty when
---nothing is active. Values are single-quoted, never sourced.
---@param parsed table
---@return string
function M.script_prefix(parsed)
  local vars = M.active_for(parsed)
  if not vars then
    return ''
  end
  local keys = vim.tbl_keys(vars)
  table.sort(keys)
  local lines = {}
  for _, k in ipairs(keys) do
    lines[#lines + 1] = ('export %s=%s'):format(k, Util.shquote(vars[k]))
  end
  return table.concat(lines, '\n') .. '\n'
end

---Environment overlay for a local ssh/scp child process, or nil.
---@param parsed table
---@return table<string,string>|nil
function M.spawn_overlay(parsed)
  local vars = M.active_for(parsed)
  return vars and vim.deepcopy(vars) or nil
end

---Space-separated key names for the start script's SSHDEV_ENV_KEYS manifest
---(lets a runtime push unset variables removed from env.txt).
---@param parsed table
---@return string
function M.active_keys(parsed)
  local vars = M.active_for(parsed)
  if not vars then
    return ''
  end
  local keys = vim.tbl_keys(vars)
  table.sort(keys)
  return table.concat(keys, ' ')
end

---Status line for :SshDevStatus, or nil when nothing is injected.
---@return string? line
function M.status_line()
  local n = vim.tbl_count(active.vars)
  if n == 0 then
    return nil
  end
  return ('env: %d variable(s) injected (%s)'):format(n, active.dest or '?')
end

-----------------------------------------------------------------------
-- Flows (run inside a Proc.launch coroutine)
-----------------------------------------------------------------------

local function fail(msg)
  Util.report_error(msg)
  return nil
end

local function auth_hint(res)
  if Auth.is_auth_failure(res) then
    return '\n(authentication was rejected; run :SshDevConnect to re-enter the password)'
  end
  return ''
end

---Fetch the remote env.txt.
---@param ctx table { cfg, parsed, workspace_profile }
---@return string? content nil when the file is absent OR the fetch failed
---@return string? err nil on success (including "absent")
local function fetch(ctx)
  local token = tostring(Util.staging_token()):gsub('%W', '')
  local script = Util.render(Scripts.env_fetch, {
    WS_PROFILE = Util.shsafe(ctx.workspace_profile, 'workspace profile dir'),
    TOKEN = Util.shsafe(token, 'fetch token'),
  })
  local res = Ssh.run_script(ctx.cfg, ctx.parsed, script, {
    timeout = ctx.cfg.timeouts.ssh,
    label = 'ssh',
  })
  if res.code ~= 0 then
    return nil, ('reading env.txt on %s failed (exit %s):\n%s%s'):format(
      ctx.parsed.dest,
      res.code,
      Util.tail(res.stderr, 5),
      auth_hint(res)
    )
  end
  local kv = Util.parse_keyvals(res.stdout)
  if kv.FILE ~= 'yes' then
    return nil, nil
  end
  local content = Util.extract_marked(res.stdout, token)
  if content == nil then
    return nil, 'the remote env.txt reply was malformed (missing content markers)'
  end
  return content, nil
end

local function write_local(path, content)
  local fd, err = uv.fs_open(path, 'w', 384) -- 0600: the file may hold secrets
  if not fd then
    return nil, err
  end
  uv.fs_write(fd, content or '', 0)
  uv.fs_close(fd)
  uv.fs_chmod(path, 384) -- fs_open's mode is subject to umask
  return true, nil
end

local function read_local(path)
  local fd, err = uv.fs_open(path, 'r', 438)
  if not fd then
    return nil, err
  end
  local st, serr = uv.fs_fstat(fd)
  if not st then
    uv.fs_close(fd)
    return nil, serr
  end
  local data = ''
  if st.size > 0 then
    local rd, rerr = uv.fs_read(fd, st.size, 0)
    uv.fs_close(fd)
    if not rd then
      return nil, rerr
    end
    data = rd
  else
    uv.fs_close(fd)
  end
  return data, nil
end

---Find the loaded buffer whose file is `path` (normalized compare, so the
---Windows "C:\..." vs "C:/..." forms agree).
---@param path string
---@return integer? buf
local function find_buf(path)
  local want = vim.fs.normalize(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      if vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == want then
        return b
      end
    end
  end
  return nil
end

---Keep the env.txt buffer out of swap/undo files: it may hold secrets.
---@param buf integer
local function protect_buffer(buf)
  if vim.api.nvim_get_current_buf() == buf then
    pcall(vim.cmd, 'silent! swapoff')
  end
  pcall(vim.api.nvim_set_option_value, 'swapfile', false, { buf = buf })
  pcall(vim.api.nvim_set_option_value, 'undofile', false, { buf = buf })
end

---Open a window on the env.txt buffer: focus it when the current tabpage
---already shows it, open a split otherwise.
---@param path string
---@param buf integer? existing buffer id
---@return integer? buf
local function open_window(path, buf)
  if buf then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == buf then
        pcall(vim.api.nvim_set_current_win, w)
        return buf
      end
    end
  end
  pcall(vim.cmd, 'split')
  if buf then
    if pcall(vim.cmd, ('buffer %d'):format(buf)) then
      return buf
    end
    pcall(vim.cmd, 'close')
    return buf
  end
  if pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(path)) then
    return vim.api.nvim_get_current_buf()
  end
  return nil
end

---Load env.txt during a connect-ish flow and make it the active map.
---Missing file = no variables. Parse errors are reported and inject
---nothing. `env_on_connect = false` disables this auto-replay.
---@param cfg table
---@param parsed table
---@param layout table
---@return table<string,string> vars
function M.load(cfg, parsed, layout)
  if cfg.env_on_connect == false then
    return {}
  end
  local ctx = {
    cfg = cfg,
    parsed = parsed,
    workspace_profile = layout.workspace_profile,
  }
  local content, err = fetch(ctx)
  if err then
    -- the connect flow continues; a broken link is reported by ensure()
    Util.log('env: %s; continuing without variables', err)
    M.set_active({}, parsed)
    return {}
  end
  if content == nil then
    M.set_active({}, parsed)
    return {}
  end
  local vars, errs = M.parse(content)
  if #errs > 0 then
    Util.notify(
      ('env.txt has %d invalid line(s) — no variables were injected:\n  %s'):format(
        #errs,
        table.concat(errs, '\n  ')
      ),
      vim.log.levels.WARN
    )
    M.set_active({}, parsed)
    return {}
  end
  M.set_active(vars, parsed)
  -- keep the local mirror fresh for :SshDevEnv
  if layout.workspace_profile_key then
    local path = M.local_path(layout.workspace_profile_key)
    Util.mkdir_p(vim.fs.dirname(path))
    local ok, werr = write_local(path, content)
    if not ok then
      Util.log('env: cannot refresh the local mirror: %s', tostring(werr))
    end
  end
  Util.log('env: %d variable(s) loaded for %s', vim.tbl_count(vars), Util.format_dest(parsed))
  return vars
end

---Push the active map into the RUNNING remote server through the control
---channel (sets vim.env there; removed keys are unset).
---@param ctx table { control = { ch, remote_id }|nil, vars = table|nil }
---@return boolean pushed
function M.push(ctx)
  local control = ctx.control
  if not control or type(control.ch) ~= 'number' then
    return false
  end
  local vars = ctx.vars or active.vars
  local ok = pcall(
    vim.fn.rpcnotify,
    control.ch,
    'nvim_exec_lua',
    APPLY_CHUNK,
    { vars }
  )
  if not ok then
    Util.log('env: control channel lost while pushing the environment')
    return false
  end
  Util.log('env: pushed %d variable(s) to the remote server', vim.tbl_count(vars))
  return true
end

---Report into the ATTACHED remote UI through the control channel (the
---local nvim is headless while its UI is attached; the remote UI is the
---only visible surface). Falls back to the log when the channel is gone.
---@param ctx table ctx.control = { ch, remote_id } | nil
---@param msg string
---@param level integer
local function report_remote(ctx, msg, level)
  Util.log('%s', msg)
  if not ctx.control then
    return
  end
  local ok = pcall(vim.fn.rpcnotify, ctx.control.ch, 'nvim_exec_lua',
    'local m, l = ...; vim.notify(m, l or vim.log.levels.INFO)', { '[sshdev] ' .. msg, level })
  if not ok then
    Util.log('control channel lost while reporting')
  end
end

---`:SshDevEnv` flow: fetch (or create) the workspace's env.txt and open
---its local copy for editing; every save of that buffer re-applies.
---Must run inside a flow coroutine.
---@param ctx table {
---   cfg, parsed, remote_root, workspace, workspace_profile,
---   workspace_profile_key, control
--- }
function M.open(ctx)
  local path = M.local_path(ctx.workspace_profile_key)
  Util.mkdir_p(vim.fs.dirname(path))

  -- never clobber the user's live editing state: when a buffer for this
  -- file is already open, keep its content and just focus/register it.
  local buf = find_buf(path)
  local content, err = fetch(ctx)
  if buf then
    ctx.remote_missing = err ~= nil or content == nil
  else
    if err then
      return fail(err)
    end
    if content == nil then
      content = M.template(Util.format_dest(ctx.parsed), ctx.workspace)
      ctx.remote_missing = true
      Util.log('env.txt does not exist yet on %s; created a template', ctx.parsed.dest)
    else
      ctx.remote_missing = false
      Util.log('fetched env.txt from %s', ctx.workspace_profile)
    end
    local ok, werr = write_local(path, content)
    if not ok then
      return fail(('cannot write %s: %s'):format(path, tostring(werr)))
    end
  end

  buf = open_window(path, buf)
  if not buf then
    return fail(('cannot open a window on %s'):format(path))
  end
  protect_buffer(buf)

  pcall(vim.api.nvim_buf_set_var, buf, 'sshdev_env', {
    dest = Util.format_dest(ctx.parsed),
    workspace = ctx.workspace,
  })

  -- (re)register the save hook; the per-buffer group makes re-running
  -- :SshDevEnv replace the previous autocmd instead of stacking.
  local group = vim.api.nvim_create_augroup(('sshdev-env-%d'):format(buf), { clear = true })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    buffer = buf,
    callback = function()
      Proc.launch(function()
        M.apply(ctx)
      end)
    end,
  })

  Util.notify(
    ('editing environment variables of "%s" on %s — save the buffer (:w) to apply'):format(
      ctx.workspace,
      Util.format_dest(ctx.parsed)
    )
  )
end

---Apply the saved env.txt: parse the mirror, scp it back into the
---workspace profile, update the active map and push it to the running
---server when the control channel is available. Must run inside a flow.
---@param ctx table (see |M.open|; remote_missing is updated)
function M.apply(ctx)
  local path = M.local_path(ctx.workspace_profile_key)
  local content, rerr = read_local(path)
  if content == nil then
    return fail(('cannot read %s: %s'):format(path, tostring(rerr)))
  end

  local vars, errs = M.parse(content)
  if #errs > 0 then
    return Util.notify(
      ('env.txt has %d invalid line(s) — nothing was applied '
        .. '(the remote copy and the running environment are unchanged):\n  %s'):format(
        #errs,
        table.concat(errs, '\n  ')
      ),
      vim.log.levels.ERROR
    )
  end

  -- persist to the remote workspace profile: it is the source of truth
  if ctx.remote_missing then
    local script = Util.render(Scripts.env_prepare, {
      ROOT = Util.shsafe(ctx.remote_root, 'remote root'),
      WS_PROFILE = Util.shsafe(ctx.workspace_profile, 'workspace profile dir'),
    })
    local res = Ssh.run_script(ctx.cfg, ctx.parsed, script, {
      timeout = ctx.cfg.timeouts.ssh,
      label = 'ssh',
    })
    if res.code ~= 0 or not res.stdout:find('SSHDEV:ENV_DIR=ok', 1, true) then
      return fail(('preparing %s for the env file failed (exit %s):\n%s%s'):format(
        ctx.workspace_profile,
        res.code,
        Util.tail(res.stderr .. res.stdout, 8),
        auth_hint(res)
      ))
    end
    ctx.remote_missing = false
  end

  local remote_file = Util.join_remote(ctx.workspace_profile, 'env.txt')
  local up = Ssh.upload_file(
    ctx.cfg,
    ctx.parsed,
    vim.fs.dirname(path),
    'env.txt',
    remote_file,
    ctx.cfg.timeouts.ssh
  )
  if up.code ~= 0 then
    return fail(('uploading env.txt to %s failed (exit %s):\n%s%s'):format(
      ctx.parsed.dest,
      up.code,
      Util.tail(up.stderr, 5),
      auth_hint(up)
    ))
  end
  Util.log('env.txt uploaded to %s', remote_file)

  -- Force the remote mode: the upload must not decide it. On Windows the
  -- local mirror reports 0666 (libuv/stat has no POSIX modes) and `scp -p`
  -- copies that onto a file that may hold secrets, so env.txt is chmod 0600
  -- explicitly. A failed chmod does not undo the (already uploaded) content:
  -- the variables are still applied and the problem is reported.
  local perm = Ssh.chmod_remote(ctx.cfg, ctx.parsed, remote_file, '600', ctx.cfg.timeouts.ssh)
  local perm_ok = perm.code == 0 and perm.stdout:find('SSHDEV:CHMOD=ok', 1, true) ~= nil
  local perm_note = ''
  if not perm_ok then
    local tail = Util.tail(perm.stderr .. perm.stdout, 5)
    Util.log('env: could not chmod 0600 %s: %s', remote_file, tail)
    perm_note = ('\nWARNING: could not set mode 0600 on the remote env.txt:\n%s'):format(tail)
  end

  M.set_active(vars, ctx.parsed)
  local n = vim.tbl_count(vars)
  if ctx.control then
    if M.push({ control = ctx.control, vars = vars }) then
      local msg
      if n == 0 then
        msg = 'env.txt saved: all injected variables removed from the running server'
      else
        msg = ('env saved (%d variable(s)) — applied to the running server; '
          .. 'restart LSPs/terminals to pick them up'):format(n)
      end
      return Util.notify(msg .. perm_note)
    end
    return Util.notify(
      ('env saved (%d variable(s)) — uploaded, but the running server could not '
        .. 'be reached; it applies on the next :SshDevConnect/start'):format(n) .. perm_note
    )
  end
  Util.notify(
    (
      n == 0 and 'env.txt saved: no variables (they take effect when the server restarts)'
        or ('env saved (%d variable(s)) — takes effect on the next :SshDevConnect/start'):format(n)
    ) .. perm_note
  )
end

---REMOTELY-triggered apply: env.txt was saved inside the ATTACHED remote
---nvim (M.open_remote pushed the request over the control channel). The
---remote copy is already the source of truth -- fetch it into the local
---mirror, parse, push, and report the outcome back into the remote UI.
---@param ctx table like |M.open| plus control = { ch, remote_id }
function M.apply_remote(ctx)
  local content, err = fetch(ctx)
  if err then
    return report_remote(ctx, ('the client could not re-read env.txt on %s; '
      .. 'nothing was changed'):format(Util.format_dest(ctx.parsed)), vim.log.levels.ERROR)
  end
  if content == nil then
    content = '' -- the file vanished remotely: treat it as "no variables"
  end
  local path = M.local_path(ctx.workspace_profile_key)
  Util.mkdir_p(vim.fs.dirname(path))
  local ok, werr = write_local(path, content)
  if not ok then
    return report_remote(ctx, ('cannot write the local env mirror: %s'):format(tostring(werr)),
      vim.log.levels.ERROR)
  end
  local vars, errs = M.parse(content)
  if #errs > 0 then
    return report_remote(ctx,
      ('env.txt has %d invalid line(s) — nothing was applied:\n  %s'):format(
        #errs,
        table.concat(errs, '\n  ')
      ), vim.log.levels.ERROR)
  end
  M.set_active(vars, ctx.parsed)
  local n = vim.tbl_count(vars)
  if not M.push({ control = ctx.control, vars = vars }) then
    return report_remote(
      ctx,
      'env.txt parsed, but the client could not reach the running server; '
        .. 'reconnect to apply the variables',
      vim.log.levels.WARN
    )
  end
  if n == 0 then
    return report_remote(
      ctx,
      'env.txt saved: all injected variables removed from the running server',
      vim.log.levels.INFO
    )
  end
  report_remote(ctx, ('env applied (%d variable(s)) to the running server; '
    .. 'restart LSPs/terminals to pick them up'):format(n), vim.log.levels.INFO)
end

-----------------------------------------------------------------------
-- Remote-side editor (runs INSIDE the attached sshdev remote nvim)
-----------------------------------------------------------------------

local function file_exists(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == 'file'
end

---First line of a small text file (workspace.txt metadata), or nil.
local function read_first_line(path)
  local fd = uv.fs_open(path, 'r', 438)
  if not fd then
    return nil
  end
  local data = ''
  local st = uv.fs_fstat(fd)
  if st and st.size > 0 then
    data = uv.fs_read(fd, st.size, 0) or ''
  end
  uv.fs_close(fd)
  return (data:match('^[^\r\n]*'))
end

---REMOTE side of :SshDevEnv, for the session the UI is ATTACHED to.
---
---env.txt lives on THIS host, so editing it here is natural. On every save
---the remote pushes an apply request through the control channel the
---client opened when it attached; the client then updates vim.env on this
---server and reports the outcome back into this UI.
---@param profile string workspace profile dir ($SSHDEV_WORKSPACE_PROFILE)
function M.open_remote(profile)
  -- POSIX-absolute on the remote; drive-letter paths are accepted so the
  -- same code runs in local tests on Windows
  local absolute = type(profile) == 'string' and profile ~= ''
    and (profile:sub(1, 1) == '/' or profile:match('^%a:[/\\]') ~= nil)
  if not absolute then
    return Util.notify(
      'this sshdev remote has no workspace profile; nothing to edit',
      vim.log.levels.WARN
    )
  end

  if type(_G.SSHDEV_CONTROL_CHANNEL) ~= 'number' then
    return Util.notify(
      'this is the sshdev remote server and the client control channel is not '
        .. 'available: manage the environment from the client -- :detach (exits '
        .. 'this UI; the server keeps running), then in a NEW local nvim '
        .. ':SshDevEnv + :w, and :SshDevAttach to return',
      vim.log.levels.WARN
    )
  end

  local workspace = read_first_line(Util.join_remote(profile, 'workspace.txt')) or '(unknown)'
  local path = Util.join_remote(profile, 'env.txt')

  if not file_exists(path) then
    local fd, err = uv.fs_open(path, 'w', 384)
    if not fd then
      return Util.notify(('cannot create %s: %s'):format(path, tostring(err)), vim.log.levels.ERROR)
    end
    uv.fs_write(fd, M.template(nil, workspace), 0)
    uv.fs_close(fd)
    uv.fs_chmod(path, 384)
    Util.log('created the remote env.txt template for %s', workspace)
  end

  local buf = find_buf(path)
  buf = open_window(path, buf)
  if not buf then
    return Util.notify(('cannot open a window on %s'):format(path), vim.log.levels.ERROR)
  end
  protect_buffer(buf)

  pcall(vim.api.nvim_buf_set_var, buf, 'sshdev_env', {
    workspace = workspace,
    remote = true,
  })

  -- every save pushes a CLIENT-side apply through the control channel
  local group = vim.api.nvim_create_augroup(('sshdev-env-%d'):format(buf), { clear = true })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    buffer = buf,
    callback = function()
      -- Apply on THIS server first: the save must take effect even when
      -- the client control channel is gone.
      local content, rerr = read_local(path)
      if content == nil then
        return Util.notify(('cannot read %s: %s'):format(path, tostring(rerr)),
          vim.log.levels.ERROR)
      end
      -- env.txt may hold secrets: assert the restrictive mode on every save
      -- (heals a mode widened by a backup/rename write, an older client or a
      -- pre-fix scp upload); no client round trip is needed for it.
      uv.fs_chmod(path, 384) -- 0600
      local vars, errs = M.parse(content)
      if #errs > 0 then
        return Util.notify(
          ('env.txt has %d invalid line(s) — nothing was applied:\n  %s'):format(
            #errs,
            table.concat(errs, '\n  ')
          ),
          vim.log.levels.ERROR
        )
      end
      M.apply_runtime(vars)

      -- then ask the client to refresh its mirror/active map and push the
      -- same state (idempotent; keeps ssh/scp env in sync for later commands)
      local ch = _G.SSHDEV_CONTROL_CHANNEL
      if type(ch) ~= 'number' then
        return Util.notify(
          'env.txt saved and applied to this server; the client control channel '
            .. 'is gone, so its mirror and ssh/scp environment refresh on the next '
            .. ':SshDevConnect',
          vim.log.levels.WARN
        )
      end
      local ok = pcall(vim.fn.rpcnotify, ch, 'nvim_exec_lua',
        'require("sshdev.session")._remote_env_apply(select(1, ...))', { profile })
      if ok then
        Util.notify('env.txt saved — applied to this server; the client is refreshing its mirror')
      else
        Util.notify(
          'env.txt saved and applied to this server, but the client could not be '
            .. 'reached; its mirror refreshes on the next :SshDevConnect',
          vim.log.levels.WARN
        )
      end
    end,
  })

  Util.notify(
    ('editing environment variables of "%s" (remote) — save the buffer (:w) to apply'):format(
      workspace
    )
  )
end

return M
