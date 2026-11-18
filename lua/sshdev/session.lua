--- Session orchestration for sshdev.nvim.
---
--- Connect pipeline (async, driven by Proc.launch):
---
---   probe remote ─► resolve profile (local host + workspace path)
---        │
---        ├─ ensure nvim binary + read server status + sync fingerprint
---        │        (one ssh round trip)
---        │
---        ├─ server already running ─────────────────────► attach
---        │
---        └─ sync fingerprint differs / no binary ─► scp config
---                 ─► headless plugin install ─► mark synced
---                 ─► start detached server (restores session.vim)
---                 ─► ssh -N -L tunnel ─► attach
---
--- There is no quit hijacking: the remote server simply quits on :q and
--- saves session.vim on the way out, so the next connection restores it.

local Bootstrap = require('sshdev.bootstrap')
local Config = require('sshdev.config')
local History = require('sshdev.history')
local Proc = require('sshdev.proc')
local Ssh = require('sshdev.ssh')
local Util = require('sshdev.util')

local M = {}

local state = {
  info = nil, -- { dest, port, profile, key, workspace, lport, rport }
  tunnel = nil, -- ssh tunnel handle (only when WE started it)
  attached = false, -- a :connect was issued from this session
}

---Throw a user-facing error without Lua's "file:line:" prefix.
local function fail(msg)
  error(msg, 0)
end

---@return boolean ok
---@return string? err
local function guard_local()
  if vim.env.SSHDEV_REMOTE == '1' then
    return false, 'this nvim IS a sshdev remote server; refusing to nest sshdev sessions'
  end
  if not Util.nvim_at_least(0, 11) then
    return false, ('sshdev.nvim needs Neovim >= 0.11 locally (found %s): :connect/:detach are required'):format(tostring(vim.version()))
  end
  return true, nil
end

---The :connect strategy additionally needs the :connect command.
local function guard_connect()
  if vim.fn.exists(':connect') ~= 2 then
    return false, 'this Neovim has no :connect command (upgrade to >= 0.11)'
  end
  return true, nil
end

---Resolve a destination argument: a `remotes` key or a raw
---"[user@]host[:port]" spec.
---@param cfg table
---@param arg string|nil
---@return table? parsed
---@return string? err
local function resolve_dest(cfg, arg)
  if arg and cfg.remotes[arg] then
    local parsed, err = Util.parse_dest(cfg.remotes[arg])
    if not parsed then
      return nil, ('setup: remotes["%s"]: %s'):format(arg, err)
    end
    return parsed, nil
  end
  local spec = arg or cfg.host
  if not spec or spec == '' then
    return nil, 'no destination given'
  end
  local parsed, err = Util.parse_dest(spec)
  if not parsed then
    return nil, err
  end
  return parsed, nil
end

------------------------------------------------------------------------
-- Attach
------------------------------------------------------------------------

---Classify the UI we run in: the builtin TUI is the UI on channel 1,
---external GUIs attach over an RPC channel (> 1).
---@return 'headless'|'tui'|'external'
local function ui_kind()
  local uis = vim.api.nvim_list_uis()
  if #uis == 0 then
    return 'headless'
  end
  if #uis == 1 and uis[1].chan == 1 then
    return 'tui'
  end
  return 'external'
end

M.ui_kind = ui_kind

---Tell the user what actually happened after the UI client exits: both a
---detach and a real quit exit with code 0, so re-check the server.
local function report_after_ui_exit(cfg, code)
  local info = state.info
  if not info then
    if code ~= 0 then
      Util.notify(('the remote UI exited with code %d (:SSHdevAttach to retry)'):format(code), vim.log.levels.WARN)
    end
    return
  end
  local parsed = Util.parse_dest(info.dest)
  if parsed then
    parsed.port = info.port
  end
  Proc.launch(function()
    local st = Bootstrap.server_status(cfg, parsed, { profile = info.profile })
    if st and st.running then
      Util.notify('detached — the remote server keeps running (:SSHdevAttach)')
      return
    end
    state.info = nil
    Util.notify(
      ('remote server for "%s" stopped%s'):format(
        info.workspace,
        st and st.has_session and ' (session saved; :SSHdevConnect restores it)' or ''
      )
    )
  end)
end

---Run a `nvim --server <addr> --remote-ui` UI client in a terminal tab.
local function attach_via_terminal(cfg, addr)
  local prog = vim.v.progpath
  if not prog or prog == '' then
    fail('cannot determine the nvim binary path for the remote UI client')
  end

  vim.cmd('tabnew')
  local buf = vim.api.nvim_get_current_buf()

  local job = vim.fn.termopen({ prog, '--server', addr, '--remote-ui' }, {
    on_exit = function(_, code)
      vim.schedule(function()
        pcall(function()
          for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(w) == buf then
              vim.api.nvim_win_close(w, true)
              break
            end
          end
        end)
        if vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        report_after_ui_exit(cfg, code)
      end)
    end,
  })
  if job <= 0 then
    fail('failed to start the remote UI client (nvim --server ... --remote-ui)')
  end
  vim.cmd('startinsert')
end

---Pick the attach strategy.
---
---Nvim parses a |:connect| address with socket_address_tcp_host_end(), so the
---address must be a bare "host:port" (a "tcp://" scheme makes the UI client's
---connect fail and exit).
---
---|:connect| really re-attaches the UI only when the TUI is a separate UI
---client process, which is the case from Nvim 0.12 on (0.12 turned the TUI
---into a UI client; on 0.11 |:connect| in a terminal is equivalent to
---|:detach|). External GUIs implement the "connect" UI event explicitly.
---@param setting string  cfg.attach
---@param kind 'headless'|'tui'|'external'
---@return 'terminal'|'connect'|'command'
local function attach_strategy(setting, kind)
  if setting and setting ~= 'auto' then
    return setting
  end
  if kind == 'headless' then
    return 'command'
  end
  if kind == 'external' then
    return 'connect'
  end
  local v = vim.version()
  if v.major > 0 or v.minor >= 12 then
    return 'connect'
  end
  return 'terminal'
end

M.attach_strategy = attach_strategy

---Attach this UI to the remote server according to cfg.attach.
---@param cfg table
---@param addr string "host:port" through the local tunnel
local function attach_ui(cfg, addr)
  local kind = ui_kind()
  local strategy = attach_strategy(cfg.attach or 'auto', kind)
  Util.log('attach strategy: %s (ui: %s)', strategy, kind)

  if strategy == 'connect' then
    local ok, aerr = guard_connect()
    if not ok then
      fail(aerr)
    end
    if kind == 'tui' and vim.version().minor < 12 and vim.version().major == 0 then
      -- would silently detach on 0.11: use the UI-client path instead
      Util.notify(
        'Nvim < 0.12 cannot :connect from the builtin TUI (it would detach); '
          .. 'attaching with --remote-ui instead',
        vim.log.levels.WARN
      )
      attach_via_terminal(cfg, addr)
      return
    end
    state.attached = true
    local cok, cerr = pcall(vim.cmd, ('connect %s'):format(addr))
    if not cok then
      state.attached = false
      fail(':connect failed: ' .. tostring(cerr))
    end
    Util.log('UI attached via :connect %s', addr)
    return
  end

  if strategy == 'terminal' then
    attach_via_terminal(cfg, addr)
    Util.log('remote UI client started: nvim --server %s --remote-ui', addr)
    return
  end

  local cmd = ('nvim --server %s --remote-ui'):format(addr)
  Util.notify(('remote server is ready. Attach from a terminal with:\n\n  %s'):format(cmd))
  Util.log('attach command: %s', cmd)
end

---Open the tunnel (or reuse an existing one) and attach.
---Must run inside a flow coroutine.
local function run_attach(cfg, parsed, ctx, rport)
  if state.tunnel then
    state.tunnel.kill()
    state.tunnel = nil
  end

  local lbase = Util.local_port(parsed.dest, ctx.profile)
  local lport
  if Proc.await_tcp_probe('127.0.0.1', lbase, 400, 2000) then
    lport = lbase
    Util.log('reusing the existing tunnel at 127.0.0.1:%d', lbase)
  else
    lport = select(1, Ssh.pick_local_port(lbase))
    if not lport then
      fail(('no free local port near %d (something holds the range)'):format(lbase))
    end
    if lport ~= lbase then
      Util.log('port %d is busy; the new tunnel uses %d', lbase, lport)
    end
    state.tunnel = Ssh.start_tunnel(cfg, parsed, lport, rport)
  end

  state.info = {
    dest = Util.format_dest(parsed),
    port = parsed.port,
    profile = ctx.profile,
    key = ctx.key,
    workspace = ctx.workspace,
    lport = lport,
    rport = rport,
  }

  -- The ssh client needs a moment to authenticate and install the forward.
  local uv = vim.uv or vim.loop
  local deadline = uv.now() + cfg.timeouts.attach * 1000
  local reached = false
  local attempt = 0
  while uv.now() < deadline do
    attempt = attempt + 1
    if state.tunnel and not state.tunnel.alive then
      fail(('the ssh tunnel died (exit %s):\n%s'):format(
        tostring(state.tunnel.exit_code or '?'),
        state.tunnel.stderr_tail()
      ))
    end
    if Proc.await_tcp_probe('127.0.0.1', lport, 300, 1500) then
      reached = true
      break
    end
    Util.log('tunnel not answering yet (attempt %d)', attempt)
    Proc.sleep(300)
  end
  if not reached then
    local tail = state.tunnel and state.tunnel.stderr_tail() or '(reused tunnel)'
    if state.tunnel then
      state.tunnel.kill()
      state.tunnel = nil
    end
    fail(('the remote nvim server did not answer through the tunnel at 127.0.0.1:%d '
      .. 'after %ds.\n%s/server.log on the remote and :SSHdevLog may help.\n%s'):format(
      lport,
      cfg.timeouts.attach,
      ctx.profile,
      tail
    ))
  end

  Util.log('tunnel up: 127.0.0.1:%d -> %s:127.0.0.1:%d', lport, parsed.dest, rport)
  Util.status('attaching to the remote server ...')
  attach_ui(cfg, ('127.0.0.1:%d'):format(lport))
  History.record(cfg, {
    dest = Util.format_dest(parsed),
    workspace = ctx.workspace,
    profile_key = ctx.key,
  })
end

------------------------------------------------------------------------
-- Shared front half
------------------------------------------------------------------------

---Guards + destination resolution + probe + profile context.
---@param opts table
---@return table? cfg
---@return table? parsed
---@return table? ctx
local function prepare(opts)
  local cfg = Config.get()
  if opts.cfg then
    cfg = vim.tbl_deep_extend('force', cfg, opts.cfg)
  end

  local ok, err = guard_local()
  if not ok then
    Util.report_error(err)
    return nil
  end

  local parsed, derr = resolve_dest(cfg, opts.dest)
  if not parsed then
    Util.report_error(derr)
    return nil
  end
  -- a path embedded in the destination ("host:~/proj") is also accepted
  local workspace = opts.workspace or parsed.path or cfg.workspace
  if opts.workspace and parsed.path then
    Util.report_error('destination already contains a workspace path; drop the second argument')
    return nil
  end

  local probe, perr = Bootstrap.probe(cfg, parsed)
  if not probe then
    Util.report_error(perr)
    return nil
  end

  local version, dev, warn = Bootstrap.resolve_version(cfg)
  if warn then
    Util.status(warn)
    Util.log('%s', warn)
  end
  if dev then
    Util.log('installing the nightly build remotely (local nvim is a dev build)')
  end

  local ctx, cerr = Bootstrap.profile_ctx(cfg, parsed, probe, workspace)
  if not ctx then
    Util.report_error(cerr)
    return nil
  end
  ctx.version = version
  Util.log('profile "%s" -> %s (workspace %s)', ctx.key, ctx.profile, ctx.workspace)
  return cfg, parsed, ctx
end

------------------------------------------------------------------------
-- Public flows
------------------------------------------------------------------------

---`:SSHdevConnect[!] [dest] [workspace]` — full pipeline or fast re-attach.
---@param opts table { dest?, workspace?, force?, reuse_only? }
function M.connect(opts)
  opts = opts or {}
  Proc.launch(function()
    local cfg, parsed, ctx = prepare(opts)
    if not cfg then
      return
    end

    Util.status(('preparing nvim %s on the remote ...'):format(ctx.version))
    local info, ierr = Bootstrap.ensure(cfg, parsed, ctx)
    if not info then
      fail(ierr)
    end
    Util.log('remote nvim: %s (%s)', info.bin, info.version_line)

    -- Fast path: a server is already running for this profile.
    if info.server == 'running' then
      if opts.force then
        Util.status('restarting the remote server ...')
        local kok, kerr = Bootstrap.stop_server(cfg, parsed, ctx)
        if not kok then
          Util.notify(kerr, vim.log.levels.WARN)
        end
      else
        if not opts.reuse_only then
          Util.status('server already running — attaching')
        end
        local rport = tonumber((info.addr or ''):match(':(%d+)$'))
        if not rport then
          fail('the remote server is running but its listen address is unknown; run :SSHdevConnect! to restart it')
        end
        return run_attach(cfg, parsed, ctx, rport)
      end
    elseif opts.reuse_only then
      fail('no remote server is running for this workspace; use :SSHdevConnect')
    end

    -- Cold path: sync config only when it actually changed.
    local fingerprint = Util.config_fingerprint(cfg)
    local needs_sync = opts.force or cfg.force_sync or info.synced ~= fingerprint

    if needs_sync then
      Util.status('uploading config (scp) ...')
      local up, uerr = Bootstrap.upload_config(cfg, parsed, ctx)
      if not up then
        fail(uerr)
      end
      local helper, herr = Bootstrap.upload_session_helper(cfg, parsed, ctx)
      if not helper then
        fail(herr)
      end
      Util.status('installing plugins on the remote ...')
      local inst, insterr = Bootstrap.install_plugins(cfg, parsed, ctx)
      if not inst then
        fail(insterr)
      end
      Bootstrap.mark_synced(cfg, parsed, ctx, fingerprint)
    else
      Util.log('config unchanged since last sync (fingerprint %s)', fingerprint)
      -- still make sure the session helper is present (cheap, tiny file)
      Bootstrap.upload_session_helper(cfg, parsed, ctx)
    end

    -- Start the server.
    local rbase = Util.remote_port(parsed.dest, ctx.profile)
    local server, serr
    for attempt = 0, 2 do
      local rport = rbase + attempt
      Util.status(('starting remote server on 127.0.0.1:%d ...'):format(rport))
      server, serr = Bootstrap.start_server(cfg, parsed, ctx, rport, opts.restore_session)
      if server then
        break
      end
      Util.log('start attempt failed: %s', tostring(serr))
    end
    if not server then
      fail(serr)
    end

    local rport = tonumber((server.addr or ''):match(':(%d+)$')) or rbase
    run_attach(cfg, parsed, ctx, rport)
  end)
end

---`:SSHdevInstall [dest] [workspace]` — bootstrap only, no server/attach.
function M.install(opts)
  opts = opts or {}
  Proc.launch(function()
    local cfg, parsed, ctx = prepare(opts)
    if not cfg then
      return
    end
    Util.status(('preparing nvim %s on the remote ...'):format(ctx.version))
    local info, ierr = Bootstrap.ensure(cfg, parsed, ctx)
    if not info then
      fail(ierr)
    end
    Util.log('remote nvim: %s (%s)', info.bin, info.version_line)

    Util.status('uploading config (scp) ...')
    local up, uerr = Bootstrap.upload_config(cfg, parsed, ctx)
    if not up then
      fail(uerr)
    end
    local helper, herr = Bootstrap.upload_session_helper(cfg, parsed, ctx)
    if not helper then
      fail(herr)
    end
    Util.status('installing plugins on the remote ...')
    local inst, insterr = Bootstrap.install_plugins(cfg, parsed, ctx)
    if not inst then
      fail(insterr)
    end
    Bootstrap.mark_synced(cfg, parsed, ctx, Util.config_fingerprint(cfg))
    Util.notify(('profile "%s" is ready — :SSHdevConnect to attach'):format(ctx.key))
  end)
end

---`:SSHdevSync [dest] [workspace]` — re-upload config + helper only.
function M.sync(opts)
  opts = opts or {}
  Proc.launch(function()
    local cfg, parsed, ctx = prepare(opts)
    if not cfg then
      return
    end
    Util.status('uploading config (scp) ...')
    local up, uerr = Bootstrap.upload_config(cfg, parsed, ctx)
    if not up then
      fail(uerr)
    end
    local helper, herr = Bootstrap.upload_session_helper(cfg, parsed, ctx)
    if not helper then
      fail(herr)
    end
    Bootstrap.mark_synced(cfg, parsed, ctx, Util.config_fingerprint(cfg))
    Util.notify(('synced to %s — use :SSHdevConnect! to restart the server'):format(ctx.profile))
  end)
end

---`:SSHdevStop` — stop the remote server (saves session.vim) + tunnel.
function M.stop()
  Proc.launch(function()
    local cfg = Config.get()
    if state.tunnel then
      state.tunnel.kill()
      state.tunnel = nil
    end
    local info = state.info
    if not info then
      return Util.notify('no active sshdev session to stop (local state only)')
    end
    local parsed = Util.parse_dest(info.dest)
    if parsed then
      parsed.port = info.port
    end
    local ok, err = Bootstrap.stop_server(cfg, parsed, { profile = info.profile })
    if not ok then
      fail(err)
    end
    state.info = nil
    Util.notify(('remote server for "%s" stopped (session saved)'):format(info.workspace))
  end)
end

---`:SSHdevStatus` — session, tunnel, remote server, remembered connections.
function M.status()
  Proc.launch(function()
    local cfg = Config.get()
    local lines = {}
    local tag, dev = Util.nvim_version_tag()
    lines[#lines + 1] = ('local nvim: %s%s'):format(tag, dev and ' (dev build)' or '')

    if state.info then
      local info = state.info
      local up = (state.tunnel and state.tunnel.alive) or state.attached
      lines[#lines + 1] = ('session: %s'):format(info.dest)
      lines[#lines + 1] = ('workspace: %s'):format(info.workspace)
      lines[#lines + 1] = ('profile: %s'):format(info.profile)
      lines[#lines + 1] = ('tunnel: %s (127.0.0.1:%d -> 127.0.0.1:%d)'):format(
        up and 'up' or 'down',
        info.lport or -1,
        info.rport or -1
      )
      local parsed = Util.parse_dest(info.dest)
      if parsed then
        parsed.port = info.port
      end
      local st = Bootstrap.server_status(cfg, parsed, { profile = info.profile })
      if st and st.running then
        lines[#lines + 1] = ('remote server: running (pid %s, %s)'):format(st.pid or '?', st.addr or '?')
        lines[#lines + 1] = ('saved session: %s'):format(st.has_session and 'yes' or 'no')
      else
        lines[#lines + 1] = 'remote server: not running'
      end
    else
      lines[#lines + 1] = 'no active local session (remote servers may still be running)'
    end

    local entries = History.list()
    if #entries > 0 then
      lines[#lines + 1] = ('remembered connections: %d (:SSHdevConnect to pick one)'):format(#entries)
    end

    for _, l in ipairs(lines) do
      Util.log('%s', l)
    end
    Util.notify(table.concat(lines, '\n'))
  end)
end

---Open the connection picker (`:SSHdevConnect` with no arguments).
---@param opts table|nil
function M.pick(opts)
  opts = opts or {}
  local cfg = Config.get()
  local Picker = require('sshdev.picker')
  Picker.select(cfg, function(entry)
    if not entry then
      return
    end
    M.connect({
      dest = entry.dest,
      workspace = entry.workspace,
      force = opts.force,
    })
  end)
end

---Kill the local tunnel handle (VimLeavePre), except right after a
---successful :connect where the local server may stop itself.
function M.teardown_local()
  if state.attached then
    return
  end
  if state.tunnel then
    state.tunnel.kill()
    state.tunnel = nil
  end
end

---Introspection for tests.
function M.state()
  return {
    info = state.info and vim.deepcopy(state.info) or nil,
    tunnel_alive = state.tunnel and state.tunnel.alive or false,
  }
end

return M
