--- Custom ssh port forwards for a workspace (`:SshDevForward`).
---
--- The workspace's forwards live in the REMOTE workspace profile:
---
---   <remote_root>/workspace-profiles/--<host>--<ws-path>--/forward.txt
---
--- One forward per line:
---
---   3080 = 127.0.0.1:3080
---   8080 = 127.0.0.1:8080
---
--- meaning: this client's 127.0.0.1:3080/8080 forward to the SERVER's
--- 127.0.0.1:3080/8080 (the target address is resolved on the remote
--- host, so it may be any host the server can reach, e.g. db.internal).
--- `#`-lines and blank lines are ignored; saving a file with no forwards
--- stops the running ones.
---
--- Flow (everything but open()/apply() is pure, so it is unit-testable):
---
---   :SshDevForward ─► fetch the remote forward.txt (ssh cat, read-only)
---        │              into a local cache mirror, or write a fresh
---        │              all-commented template when it does not exist
---        └─► open the local copy; BufWritePost on that buffer triggers
---             apply(): parse ─► scp back to the workspace profile ─►
---             kill the previous forward tunnel ─► start ONE detached
---             `ssh -N` carrying a `-L` per line ─► wait until it
---             verifiably accepts connections (a dead start rolls the
---             previous set back and reports ssh's own error).
---
--- The local copy is only the EDITING MEDIUM; the remote file is the
--- source of truth and is re-uploaded on every save. One forward tunnel
--- handle is kept per nvim instance (the plugin is single-session), and
--- it is killed by :SshDevStop / VimLeavePre like the session tunnel --
--- re-run :SshDevForward and save to re-establish the forwards.

local Auth = require('sshdev.auth')
local Proc = require('sshdev.proc')
local Scripts = require('sshdev.remote_scripts')
local Ssh = require('sshdev.ssh')
local Util = require('sshdev.util')

local M = {}

local uv = vim.uv or vim.loop

---The one running forward tunnel (a Ssh.start_forwards() handle), or nil.
local applied = nil

-----------------------------------------------------------------------
-- Pure helpers
-----------------------------------------------------------------------

---Parse forward.txt content into forward specs.
---
---One forward per line:  <local-port> = <remote-host>:<remote-port>
---Blank lines and `#`-comment lines are ignored; whitespace around the
---tokens is tolerated (also \r, in case the file was written with DOS
---line endings). Every problem is collected with its line number instead
---of failing on the first one, so one save can report all bad lines.
---
---A remote host may be a hostname or IPv4 literal; IPv6 literals are not
---supported (the same limitation as destinations, see Util.parse_dest()).
---@param text string|nil
---@return table[] specs { lport = integer, rhost = string, rport = integer }
---@return string[] errs line-anchored error messages
function M.parse(text)
  local specs, errs = {}, {}
  local first_line = {} -- lport -> line number of its first spec
  local n = 0
  for line in tostring(text or ''):gmatch('[^\r\n]+') do
    n = n + 1
    local s = line:match('^%s*(.-)%s*$')
    if s ~= '' and s:sub(1, 1) ~= '#' then
      local lport_s, rhost, rport_s = s:match('^(%d+)%s*=%s*([%w%.%-_]+):(%d+)$')
      local lport, rport = tonumber(lport_s), tonumber(rport_s)
      if not lport or not rport then
        errs[#errs + 1] = ('line %d: expected "<local-port> = <remote-host>:<remote-port>", got: %s'):format(n, s)
      elseif lport < 1 or lport > 65535 then
        errs[#errs + 1] = ('line %d: local port %d is out of range 1-65535'):format(n, lport)
      elseif rport < 1 or rport > 65535 then
        errs[#errs + 1] = ('line %d: remote port %d is out of range 1-65535'):format(n, rport)
      elseif first_line[lport] then
        errs[#errs + 1] = ('line %d: local port %d is already used on line %d'):format(n, lport, first_line[lport])
      else
        first_line[lport] = n
        specs[#specs + 1] = { lport = lport, rhost = rhost, rport = rport }
      end
    end
  end
  return specs, errs
end

---Human one-liner for a spec list: "3080 -> 127.0.0.1:3080, ...".
---@param specs table[]|nil
---@return string
function M.describe(specs)
  local parts = {}
  for _, s in ipairs(specs or {}) do
    parts[#parts + 1] = ('%d -> %s:%d'):format(s.lport, s.rhost, s.rport)
  end
  return table.concat(parts, ', ')
end

---Content for a NEW forward.txt. Every line is commented out, so saving
---the fresh template applies nothing; parse(template(...)) must stay
---{ } / { }.
---@param dest string display destination ("me@host[:port]")
---@param workspace string remote workspace path
---@return string
function M.template(dest, workspace)
  return ([[
# sshdev port forwards
# destination: %s
# workspace:   %s
#
# One forward per line:  <local-port> = <remote-host>:<remote-port>
# The local port is opened on THIS machine (loopback only); the target
# is resolved on the SERVER, so "127.0.0.1:3080" below means the server's
# own 127.0.0.1:3080. Lines starting with "#" are comments.
#
# Examples -- remove the leading "# " to activate:
# 3080 = 127.0.0.1:3080
# 8080 = 127.0.0.1:8080
#
# Saving this file uploads it to the remote workspace profile and
# (re)starts the forwards; comment out or delete lines to stop them.
]]):format(dest, workspace)
end

---Extract the exact forward.txt content reported by the forward_fetch
---script between its BEGIN/END markers (the token makes marker confusion
---impossible). Returns nil when the markers are absent.
---
---Transport realities: Proc.await drops EMPTY lines, so blank lines never
---survive the fetch (they are semantically void to the parser anyway), and
---a content line ending in a bare \r is stripped (CRLF files normalize to
---LF). A remote file without a trailing newline gains one -- harmless,
---:w writes one anyway.
---@param stdout string|nil
---@param token string the token rendered into the script
---@return string? content
function M.extract_content(stdout, token)
  local begin_marker = 'SSHDEV:BEGIN-' .. tostring(token)
  local end_marker = 'SSHDEV:END-' .. tostring(token)
  local lines = {}
  local inside = false
  for line in tostring(stdout or ''):gmatch('[^\r\n]+') do
    if line == begin_marker then
      inside = true
      lines = {}
    elseif line == end_marker then
      return table.concat(lines, '\n')
    elseif inside then
      lines[#lines + 1] = line:gsub('\r$', '')
    end
  end
  return nil
end

---Local cache mirror of the workspace's forward.txt (the editing medium).
---
---The workspace profile key is a validated single path segment (built by
---Util.workspace_profile_key or checked in Config.validate), so it is used
---as-is; only a separator would break out of the cache dir and is rejected.
---@param ws_key string workspace profile key
---@return string
function M.local_path(ws_key)
  local key = tostring(ws_key or '')
  if key == '' or key:find('[/\\]') then
    error('sshdev: invalid workspace profile key for the local forward mirror: ' .. key, 0)
  end
  return Util.fs_join(
    vim.fs.normalize(vim.fn.stdpath('cache')),
    'sshdev',
    'forward',
    key,
    'forward.txt'
  )
end

-----------------------------------------------------------------------
-- Lifecycle
-----------------------------------------------------------------------

---Stop the current forward tunnel (no error when there is none).
function M.kill()
  if applied then
    applied.kill()
    applied = nil
  end
end

---A copy of the current forward tunnel state (nil when none is applied).
---@return table? handle { dest, alive, specs }
function M.applied()
  if not applied then
    return nil
  end
  return {
    dest = applied.dest,
    alive = applied.alive,
    specs = vim.deepcopy(applied.specs or {}),
  }
end

---Status line for :SshDevStatus, or nil when no forwards were applied.
---@return string? line
function M.status_line()
  if not applied then
    return nil
  end
  return ('forwards: %s (%s)'):format(
    applied.alive and 'up' or 'down',
    M.describe(applied.specs or {})
  )
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

---Fetch the remote forward.txt. Returns:
---   content, false   the file's exact content
---   nil,     false    the file does not exist (caller writes a template)
---   nil,     true     the ssh round trip failed (already reported)
---@param ctx table
---@return string? content
---@return boolean failed
local function fetch(ctx)
  local token = tostring(Util.staging_token()):gsub('%W', '')
  local script = Util.render(Scripts.forward_fetch, {
    WS_PROFILE = Util.shsafe(ctx.workspace_profile, 'workspace profile dir'),
    TOKEN = Util.shsafe(token, 'fetch token'),
  })
  local res = Ssh.run_script(ctx.cfg, ctx.parsed, script, {
    timeout = ctx.cfg.timeouts.ssh,
    label = 'ssh',
  })
  if res.code ~= 0 then
    return fail(('reading forward.txt on %s failed (exit %s):\n%s%s'):format(
      ctx.parsed.dest,
      res.code,
      Util.tail(res.stderr, 5),
      auth_hint(res)
    )), true
  end
  local kv = Util.parse_keyvals(res.stdout)
  if kv.FORWARD ~= 'yes' then
    return nil, false
  end
  local content = M.extract_content(res.stdout, token)
  if content == nil then
    return fail('the remote forward.txt reply was malformed (missing content markers)'), true
  end
  return content, false
end

local function write_local(path, content)
  local fd, err = uv.fs_open(path, 'w', 438)
  if not fd then
    return nil, err
  end
  uv.fs_write(fd, content or '', 0)
  uv.fs_close(fd)
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

---Open a window on the forward.txt buffer: focus it when the current
---tabpage already shows it, open a split otherwise. Returns nil when the
---file cannot be displayed at all (then no autocmd must be registered).
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
    -- (rare) the split could not be filled; drop it, the buffer stays
    pcall(vim.cmd, 'close')
    return buf
  end
  if pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(path)) then
    return vim.api.nvim_get_current_buf()
  end
  return nil
end

---`:SshDevForward` flow: fetch (or create) the workspace's forward.txt and
---open its local copy for editing; every save of that buffer re-applies.
---Must run inside a flow coroutine; failures are reported, not thrown.
---
---ctx from sshdev.session.forward():
---   cfg                    active configuration
---   parsed                 destination table (Util.parse_dest)
---   remote_root            absolute sshdev root on the remote
---   workspace              remote workspace path
---   workspace_profile      remote workspace profile dir
---   workspace_profile_key   its directory name
---@param ctx table
function M.open(ctx)
  local path = M.local_path(ctx.workspace_profile_key)
  Util.mkdir_p(vim.fs.dirname(path))

  -- never clobber the user's live editing state: when a buffer for this
  -- file is already open, keep its content and just focus/register it.
  local buf = find_buf(path)
  local content, failed = fetch(ctx)
  if buf then
    -- a failed fetch is treated as "missing": the next save then runs
    -- the idempotent mkdir -p before uploading.
    ctx.remote_missing = failed or content == nil
  else
    if failed then
      return
    end
    if content == nil then
      content = M.template(Util.format_dest(ctx.parsed), ctx.workspace)
      ctx.remote_missing = true
      Util.log('forward.txt does not exist yet on %s; created a template', ctx.parsed.dest)
    else
      ctx.remote_missing = false
      Util.log('fetched forward.txt from %s', ctx.workspace_profile)
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

  -- context display for statuslines and debugging
  pcall(vim.api.nvim_buf_set_var, buf, 'sshdev_forward', {
    dest = Util.format_dest(ctx.parsed),
    workspace = ctx.workspace,
  })

  -- (re)register the save hook; the per-buffer group makes re-running
  -- :SshDevForward replace the previous autocmd instead of stacking.
  local group = vim.api.nvim_create_augroup(('sshdev-forward-%d'):format(buf), { clear = true })
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
    ('editing port forwards of "%s" on %s — save the buffer (:w) to apply'):format(
      ctx.workspace,
      Util.format_dest(ctx.parsed)
    )
  )
end

---Wait until a forward tunnel VERIFIABLY serves its ports.
---
---ssh needs a moment to authenticate and install the local listeners;
---ExitOnForwardFailure makes a failed bind (a busy port, a Windows
---reserved range, a rejected auth) kill the process -- and on a real link
---that happens well after a fixed sleep would declare success. The probe
---itself can be fooled when a FOREIGN process already listens on the
---probed port (libuv's bind check cannot see those on Windows), so an
---accepted connect is only trusted after the process also survives a
---short grace window: bind failures land right after authentication.
---
---Returns 'up' (answered + survived), 'dead', 'timeout' or 'stale' (a
---newer flow took the state over; the caller must bow out silently).
---@param ctx table
---@param handle table Ssh.start_forwards() handle
---@param first_port integer any port of the spec set (ssh installs all
---listeners as one unit and exits instead of binding a partial set)
---@return 'up'|'dead'|'timeout'|'stale'
local function await_up(ctx, handle, first_port)
  local deadline = uv.now() + ctx.cfg.timeouts.attach * 1000
  while uv.now() < deadline do
    if applied ~= handle then
      return 'stale'
    end
    if not handle.alive then
      return 'dead'
    end
    if Proc.await_tcp_accept('127.0.0.1', first_port, 800) then
      local grace = uv.now() + 1500
      while uv.now() < grace do
        if applied ~= handle then
          return 'stale'
        end
        if not handle.alive then
          return 'dead'
        end
        Proc.sleep(150)
      end
      return 'up'
    end
    Proc.sleep(200)
  end
  if not handle.alive then
    return 'dead'
  end
  return 'timeout'
end

---Best-effort rollback after a failed replace: bring the PREVIOUS forward
---set back up (this save already killed it). Runs only when the new tunnel
---died definitively; a newer flow taking over mid-rollback aborts it.
---@param ctx table
---@param old table? the previous handle
---@param was_alive boolean it was alive when this save started
local function rollback(ctx, old, was_alive)
  if not old or not was_alive or not old.specs or #old.specs == 0 then
    return
  end
  if applied ~= nil then
    return -- someone else already owns the state
  end
  local handle = Ssh.start_forwards(ctx.cfg, ctx.parsed, old.specs)
  applied = handle
  local verdict = await_up(ctx, handle, old.specs[1].lport)
  if verdict == 'up' then
    Util.log('rolled back to the previous forwards: %s', M.describe(old.specs))
    Util.notify('previous forwards restored: ' .. M.describe(old.specs), vim.log.levels.WARN)
    return
  end
  if verdict == 'dead' and applied == handle then
    applied = nil
    Util.log('rollback failed: the previous forwards could not restart')
    return
  end
  -- 'stale': a newer flow owns the state; 'timeout': left registered,
  -- the status tells the truth either way.
  Util.log('rollback verdict: %s', verdict)
end

---Apply the saved forward.txt: parse it, scp it back into the workspace
---profile, then replace the forward tunnel. Must run inside a flow
---coroutine; every failure is reported and leaves the previous forwards
---running (the replace step restores them when the new tunnel dies).
---@param ctx table (see |M.open|; remote_missing is updated)
function M.apply(ctx)
  local path = M.local_path(ctx.workspace_profile_key)
  local content, rerr = read_local(path)
  if content == nil then
    return fail(('cannot read %s: %s'):format(path, tostring(rerr)))
  end

  local specs, errs = M.parse(content)
  if #errs > 0 then
    return Util.notify(
      ('forward.txt has %d invalid line(s) — nothing was applied '
        .. '(the remote copy and the running forwards are unchanged):\n  %s'):format(
        #errs,
        table.concat(errs, '\n  ')
      ),
      vim.log.levels.ERROR
    )
  end

  -- persist to the remote workspace profile: it is the source of truth
  -- (re-openable from any nvim instance, survives the local cache).
  if ctx.remote_missing then
    local script = Util.render(Scripts.forward_prepare, {
      ROOT = Util.shsafe(ctx.remote_root, 'remote root'),
      WS_PROFILE = Util.shsafe(ctx.workspace_profile, 'workspace profile dir'),
    })
    local res = Ssh.run_script(ctx.cfg, ctx.parsed, script, {
      timeout = ctx.cfg.timeouts.ssh,
      label = 'ssh',
    })
    if res.code ~= 0 or not res.stdout:find('SSHDEV:FORWARD_DIR=ok', 1, true) then
      return fail(('preparing %s for the forward file failed (exit %s):\n%s%s'):format(
        ctx.workspace_profile,
        res.code,
        Util.tail(res.stderr .. res.stdout, 8),
        auth_hint(res)
      ))
    end
    ctx.remote_missing = false
  end
  local remote_file = Util.join_remote(ctx.workspace_profile, 'forward.txt')
  local up = Ssh.upload_file(
    ctx.cfg,
    ctx.parsed,
    vim.fs.dirname(path),
    'forward.txt',
    remote_file,
    ctx.cfg.timeouts.ssh
  )
  if up.code ~= 0 then
    return fail(('uploading forward.txt to %s failed (exit %s):\n%s%s'):format(
      ctx.parsed.dest,
      up.code,
      Util.tail(up.stderr, 5),
      auth_hint(up)
    ))
  end
  Util.log('forward.txt uploaded to %s', remote_file)

  -- Replace the running forwards. Port availability is checked BEFORE the
  -- old tunnel is killed (so an error leaves it running); ports held by
  -- our own live handle are expected and skipped. The bind check is
  -- best-effort (on Windows libuv binds with SO_REUSEADDR and succeeds
  -- over a foreign listener), so the authoritative verdict is the
  -- verified wait below, not this check.
  local old = applied
  local old_was_alive = old and old.alive or false
  local busy = {}
  for _, s in ipairs(specs) do
    -- a port held by our own LIVE handle is expected: the kill below frees it
    local ours = false
    if old and old.alive then
      for _, o in ipairs(old.specs or {}) do
        if o.lport == s.lport then
          ours = true
          break
        end
      end
    end
    if not ours and not Ssh.local_port_free(s.lport) then
      busy[#busy + 1] = tostring(s.lport)
    end
  end
  if #busy > 0 then
    return fail(('cannot forward: local port(s) %s already in use '
      .. '(a leftover ssh from a crashed nvim may hold one; check with '
      .. '"ss -ltn" / "netstat -an"). The previous forwards keep running.'):format(
      table.concat(busy, ', ')
    ))
  end

  M.kill()
  if #specs == 0 then
    return Util.notify('forward.txt saved: no forwards configured (previous forwards stopped)')
  end

  -- give our own just-killed listener sockets a moment to close
  Proc.sleep(200)
  local handle = Ssh.start_forwards(ctx.cfg, ctx.parsed, specs)
  applied = handle

  local verdict = await_up(ctx, handle, specs[1].lport)
  if verdict == 'stale' then
    -- a newer save (or :SshDevStop / nvim exiting) replaced this tunnel
    -- mid-flight: it owns the state now, this flow bows out silently
    -- (its handle was killed by whoever took over).
    return
  end

  if verdict == 'up' then
    Util.log('forwards up on %s: %s', ctx.parsed.dest, M.describe(specs))
    Util.notify(
      ('forwards applied (%s): %s'):format(Util.format_dest(ctx.parsed), M.describe(specs))
    )
    -- A very slow link can deliver the bind failure only AFTER the probe
    -- and its grace window passed; keep watching a few more seconds and
    -- correct the verdict (rollback + ssh's own message) if so. A newer
    -- flow taking over ends this silently.
    local watch = uv.now() + 10000
    while uv.now() < watch do
      if applied ~= handle then
        return
      end
      if not handle.alive then
        applied = nil
        rollback(ctx, old, old_was_alive)
        return fail(('the forward tunnel to %s died right after the start (exit %s):\n%s'):format(
          ctx.parsed.dest,
          tostring(handle.exit_code or '?'),
          handle.stderr_tail()
        ))
      end
      Proc.sleep(250)
    end
    return
  end

  if verdict == 'timeout' then
    -- not answering yet, but not dead either (very slow link): leave it
    -- running and registered; :SshDevStatus tells the truth either way.
    return Util.notify(
      ('the forwards on %s did not answer within %ds — still starting? '
        .. 'check :SshDevStatus'):format(ctx.parsed.dest, ctx.cfg.timeouts.attach),
      vim.log.levels.WARN
    )
  end

  -- verdict == 'dead': definitive failure. Restore the previous set (this
  -- save killed it) and report ssh's own error message.
  applied = nil
  rollback(ctx, old, old_was_alive)
  return fail(('the forward tunnel to %s died (exit %s):\n%s'):format(
    ctx.parsed.dest,
    tostring(handle.exit_code or '?'),
    handle.stderr_tail()
  ))
end

return M
