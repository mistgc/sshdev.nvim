--- Session orchestration for sshdev.nvim.
---
--- The connect pipeline (runs async, driven by Proc.launch):
---
---   probe remote ──► resolve workspace + nvim version ──► server running?
---        │                                                    │
---        │ no                                            yes │
---        ▼                                                    ▼
---   download nvim (proxy) ──► scp config+shim ──►      attach:
---   install plugins ──► start detached server ──►   ssh -N -L tunnel ──►
---                                                        :connect tcp://127.0.0.1:<port>
---
--- State (current session info + tunnel handle) lives in this module.

local M = {}

local Bootstrap = require('sshdev.bootstrap')
local Config = require('sshdev.config')
local Proc = require('sshdev.proc')
local Ssh = require('sshdev.ssh')
local Util = require('sshdev.util')

local state = {
  info = nil, -- { dest, ws, ws_dir, cwd, lport, rport }
  tunnel = nil, -- ssh tunnel handle (only when WE started it)
  attached = false, -- a :connect was issued from this session
}

---Throw a user-facing error without the "file:line:" prefix that Lua adds
---by default; flow errors are reported verbatim via Util.report_error.
local function fail(msg)
  error(msg, 0)
end

---Guards for operations launched from the local nvim.
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

---The attach step additionally needs the :connect command.
local function guard_attach()
  if vim.fn.exists(':connect') ~= 2 then
    return false, 'this Neovim has no :connect command (upgrade to >= 0.11)'
  end
  return true, nil
end

---Resolve a destination argument: either a `remotes` key or a raw
---"[user@]host[:port][:path]" spec. Returns (parsed, remotes_key, err).
---@param cfg table
---@param arg string|nil
---@return table? parsed
---@return string? remotes_key
---@return string? err
local function resolve_dest(cfg, arg)
  if arg and cfg.remotes[arg] then
    local parsed, err = Util.parse_dest(cfg.remotes[arg])
    if not parsed then
      return nil, nil, ('setup: remotes["%s"]: %s'):format(arg, err)
    end
    return parsed, arg, nil
  end
  local spec = arg or cfg.host
  if not spec or spec == '' then
    return nil, nil, 'no destination: pass [user@]host[:port] to :SSHdevConnect, configure setup({ host = ... }), or add a remotes entry'
  end
  local parsed, err = Util.parse_dest(spec)
  if not parsed then
    return nil, nil, err
  end
  return parsed, nil, nil
end

---Classify the UI we are running in.
---
---The builtin TUI is the UI on channel 1; external GUIs attach over an RPC
---channel (> 1). This matters because |:connect| only really re-attaches
---when the UI implements the "connect" UI event; the builtin TUI does NOT
---(per |:connect|, "if the current UI hasn't implemented the connect UI
---event, this command is equivalent to |:detach|"), so for a terminal the
---supported way to attach is a `nvim --server ... --remote-ui` client.
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

---After the remote UI client exits, tell the user what actually happened:
---a detach (server alive) and a real quit (:SSHdevQuit/:cq, server gone)
---both exit with code 0, so the remote server state must be re-checked.
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
    local st = Bootstrap.server_status(cfg, parsed, { ws_dir = info.ws_dir })
    if st and st.running then
      Util.notify('detached — the remote server keeps running (:SSHdevAttach)')
      return
    end
    state.info = nil
    Util.notify(('the remote server for workspace "%s" has stopped'):format(info.ws))
  end)
end

---Run a `nvim --server <addr> --remote-ui` UI client in a terminal tab.
---@param cfg table
---@param addr string "host:port"
local function attach_via_terminal(cfg, addr)
  local prog = vim.v.progpath
  if not prog or prog == '' then
    fail('cannot determine the nvim binary path for the remote UI client')
  end

  vim.cmd('tabnew')
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, ('sshdev://%s'):format(addr))

  local job = vim.fn.termopen({
    prog,
    '--server',
    addr,
    '--remote-ui',
  }, {
    on_exit = function(_, code)
      vim.schedule(function()
        -- Drop the terminal tab so the user is back in the local nvim.
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
  -- land the cursor in the terminal so keys go straight to the remote nvim
  vim.cmd('startinsert')
end

---Attach this UI to the remote server according to cfg.attach.
---@param cfg table
---@param addr string "host:port" through the local tunnel
---@param ctx table
local function attach_ui(cfg, addr, ctx)
  local kind = ui_kind()
  local strategy = cfg.attach or 'auto'
  if strategy == 'auto' then
    if kind == 'tui' then
      strategy = 'terminal'
    elseif kind == 'external' then
      strategy = 'connect'
    else
      strategy = 'command'
    end
  end

  Util.log('attach strategy: %s (ui: %s)', strategy, kind)

  if strategy == 'connect' then
    local ok, aerr = guard_attach()
    if not ok then
      fail(aerr)
    end
    state.attached = true
    local cok, cerr = pcall(vim.cmd, ('connect tcp://%s'):format(addr))
    if not cok then
      state.attached = false
      fail(':connect failed: ' .. tostring(cerr))
    end
    Util.log('UI attached via :connect tcp://%s', addr)
    return
  end

  if strategy == 'terminal' then
    attach_via_terminal(cfg, addr)
    Util.log('remote UI client started: nvim --server %s --remote-ui', addr)
    return
  end

  -- strategy == 'command': tell the user exactly what to run
  local cmd = ('nvim --server %s --remote-ui'):format(addr)
  Util.notify(('remote server is ready. Attach from a terminal with:\n\n  %s\n\n'
    .. 'the tunnel stays up as long as this nvim runs (or is detached).'):format(cmd))
  Util.log('attach command: %s', cmd)
end

---Open the tunnel and attach the UI to the remote server.
---Must run inside a flow coroutine.
---
---The local port is deterministic per (destination, workspace). When a
---working tunnel for that port already exists (a previous local nvim died
---after attaching, leaving its detached tunnel behind), it is REUSED —
---this is the normal reconnect path. When the port is held by a stale
---tunnel whose remote side is gone, a fresh port is picked instead.
local function run_attach(cfg, parsed, ctx, rport)
  if state.tunnel then
    state.tunnel.kill()
    state.tunnel = nil
  end

  local lbase = Util.local_port(parsed.dest, ctx.ws)
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
      Util.log('port %d is held by a stale tunnel or another process; using %d', lbase, lport)
      Util.notify(
        ('port %d was busy (likely a stale ssh tunnel); the new tunnel uses %d'):format(lbase, lport),
        vim.log.levels.WARN
      )
    end
    local t = Ssh.start_tunnel(cfg, parsed, lport, rport)
    state.tunnel = t
  end

  state.info = {
    dest = parsed.dest,
    port = parsed.port,
    ws = ctx.ws,
    ws_dir = ctx.ws_dir,
    cwd = ctx.cwd,
    lport = lport,
    rport = rport,
  }

  -- Verify through the tunnel (both fresh and reused).
  --
  -- The ssh client needs a moment to authenticate and install the forward;
  -- until then the local port refuses connections. Poll with a delay until
  -- cfg.timeouts.attach expires instead of burning all attempts at once.
  local uv = vim.uv or vim.loop
  local deadline = uv.now() + cfg.timeouts.attach * 1000
  local reached = false
  local attempt = 0
  while uv.now() < deadline do
    attempt = attempt + 1
    -- a dead tunnel will never answer: fail fast with its stderr
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
      ctx.ws_dir,
      tail
    ))
  end

  Util.log('tunnel up: 127.0.0.1:%d -> %s:127.0.0.1:%d', lport, parsed.dest, rport)
  Util.status('attaching to the remote server ...')

  attach_ui(cfg, ('127.0.0.1:%d'):format(lport), ctx)
end

---Shared front half of every flow: guards, dest parsing, probe, ctx.
---Returns (cfg, parsed, ctx) or nil (already reported).
local function prepare(opts, need_attach_guard)
  local cfg = Config.get()

  if opts.cfg then -- per-call overrides (e.g. force in tests)
    cfg = vim.tbl_deep_extend('force', cfg, opts.cfg)
  end

  local ok, err = guard_local()
  if not ok then
    Util.report_error(err)
    return nil
  end
  if need_attach_guard then
    local aok, aerr = guard_attach()
    if not aok then
      Util.report_error(aerr)
      return nil
    end
  end

  local parsed, remotes_key, derr = resolve_dest(cfg, opts.dest)
  if not parsed then
    Util.report_error(derr)
    return nil
  end

  if opts.path and parsed.path then
    Util.report_error('destination already contains a path; drop the second argument')
    return nil
  end
  local path = opts.path or parsed.path or cfg.remote_dir

  local probe, perr = Bootstrap.probe(cfg, parsed)
  if not probe then
    Util.report_error(perr)
    return nil
  end
  Util.log('remote: %s %s, home=%s', probe.sys, probe.machine, probe.home)

  local version, dev, warn = Bootstrap.resolve_version(cfg)
  if warn then
    Util.notify(warn, vim.log.levels.WARN)
    Util.log('%s', warn)
  end
  local asset = Bootstrap.asset_name(probe.sys, probe.machine)
  if not asset then
    Util.report_error(('the remote platform (%s %s) has no official nvim release; '
      .. 'install Neovim >= 0.11 there manually and reconnect'):format(probe.sys, probe.machine))
    return nil
  end

  local ctx, cerr = Bootstrap.workspace_ctx(cfg, parsed, probe, path, remotes_key)
  if not ctx then
    Util.report_error(cerr)
    return nil
  end
  ctx.version = version
  ctx.asset = asset
  ctx.hijack = cfg.hijack_quit ~= false
  Util.log('workspace "%s" -> %s (cwd %s)', ctx.ws, ctx.ws_dir, ctx.cwd)

  return cfg, parsed, ctx
end

---`:SSHdevConnect[!] [dest] [dir]` — full pipeline or fast re-attach.
---@param opts table { dest?, path?, force?, reuse_only? }
function M.connect(opts)
  opts = opts or {}
  Proc.launch(function()
    local cfg, parsed, ctx = prepare(opts, true)
    if not cfg then
      return
    end

    local st, sterr = Bootstrap.server_status(cfg, parsed, ctx)
    if not st then
      Util.log('status check failed (%s); assuming no server is running', tostring(sterr))
      st = { running = false }
    end

    -- Fast path: server already running -> re-attach without touching it.
    if opts.reuse_only and not st.running then
      fail('no remote server is running for this workspace; use :SSHdevConnect to bootstrap one')
    end

    if st.running then
      if not st.addr then
        fail('the remote server is running but its listen address is unknown; run :SSHdevConnect! to restart it')
      end
      local rport = tonumber((st.addr):match(':(%d+)$'))
      if not rport then
        fail('cannot parse the remote listen address: ' .. tostring(st.addr))
      end
      if opts.force then
        Util.log('stopping the existing server for a forced resync')
        local kok, kerr = Bootstrap.stop_server(cfg, parsed, ctx)
        if not kok then
          Util.notify(kerr, vim.log.levels.WARN)
        end
      else
        if not opts.reuse_only then
          Util.status('server already running — attaching (use :SSHdevConnect! to resync)')
        end
        return run_attach(cfg, parsed, ctx, rport)
      end
    end

    -- Fresh bootstrap.
    Util.status(('bootstrapping nvim %s on the remote ...'):format(ctx.version))
    local binres, berr = Bootstrap.ensure_binary(cfg, parsed, ctx)
    if not binres then
      fail(berr)
    end
    ctx.bin = binres.bin
    Util.log('remote nvim: %s (%s)', ctx.bin, binres.version_line)

    Util.status('uploading config (scp) ...')
    local up, uerr = Bootstrap.upload_config(cfg, parsed, ctx)
    if not up then
      fail(uerr)
    end
    local shim_ok, shim_err = Bootstrap.upload_shim(cfg, parsed, ctx)
    if not shim_ok then
      fail(shim_err)
    end
    Util.log('config + shim uploaded to %s', ctx.ws_dir)

    Util.status('installing plugins on the remote ...')
    local inst, ierr = Bootstrap.install_plugins(cfg, parsed, ctx)
    if not inst then
      fail(ierr)
    end

    local rbase = Util.remote_port(parsed.dest, ctx.ws)
    local server, serr
    for attempt = 0, 2 do
      local rport = rbase + attempt
      Util.log('starting the remote server on 127.0.0.1:%d (attempt %d)', rport, attempt + 1)
      server, serr = Bootstrap.start_server(cfg, parsed, ctx, rport)
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

---`:SSHdevInstall [dest] [dir]` — bootstrap only (no server, no attach).
function M.install(opts)
  opts = opts or {}
  Proc.launch(function()
    local cfg, parsed, ctx = prepare(opts, false)
    if not cfg then
      return
    end
    Util.status(('bootstrapping nvim %s on the remote ...'):format(ctx.version))
    local binres, berr = Bootstrap.ensure_binary(cfg, parsed, ctx)
    if not binres then
      fail(berr)
    end
    ctx.bin = binres.bin
    Util.log('remote nvim: %s (%s)', ctx.bin, binres.version_line)

    Util.status('uploading config (scp) ...')
    local up, uerr = Bootstrap.upload_config(cfg, parsed, ctx)
    if not up then
      fail(uerr)
    end
    local shim_ok, shim_err = Bootstrap.upload_shim(cfg, parsed, ctx)
    if not shim_ok then
      fail(shim_err)
    end

    Util.status('installing plugins on the remote ...')
    local inst, ierr = Bootstrap.install_plugins(cfg, parsed, ctx)
    if not inst then
      fail(ierr)
    end
    Util.notify(('bootstrap done — run :SSHdevConnect %s to attach'):format(opts.dest or ''))
  end)
end

---`:SSHdevSync [dest] [dir]` — re-upload config + shim only.
function M.sync(opts)
  opts = opts or {}
  Proc.launch(function()
    local cfg, parsed, ctx = prepare(opts, false)
    if not cfg then
      return
    end
    Util.status('uploading config (scp) ...')
    local up, uerr = Bootstrap.upload_config(cfg, parsed, ctx)
    if not up then
      fail(uerr)
    end
    local shim_ok, shim_err = Bootstrap.upload_shim(cfg, parsed, ctx)
    if not shim_ok then
      fail(shim_err)
    end
    Util.notify('synced — use :SSHdevConnect! to restart the server with it')
  end)
end

---`:SSHdevStop` — stop the remote server and the local tunnel.
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
    local ok, err = Bootstrap.stop_server(cfg, parsed, { ws_dir = info.ws_dir, ws = info.ws })
    if not ok then
      fail(err)
    end
    state.info = nil
    Util.notify(('remote server for workspace "%s" stopped'):format(info.ws))
  end)
end

---`:SSHdevStatus` — show session, tunnel, and remote server state.
function M.status()
  Proc.launch(function()
    local cfg = Config.get()
    local lines = {}
    local tag, dev = Util.nvim_version_tag()
    lines[#lines + 1] = ('local nvim: %s%s'):format(tag, dev and ' (dev build)' or '')

    if state.info then
      local info = state.info
      lines[#lines + 1] = ('session: %s (workspace "%s")'):format(info.dest, info.ws)
      lines[#lines + 1] = ('remote dir: %s'):format(info.cwd)
      lines[#lines + 1] = ('sshdev root: %s'):format(info.ws_dir)
      local up = (state.tunnel and state.tunnel.alive) or state.attached
      lines[#lines + 1] = ('tunnel: %s (127.0.0.1:%d -> remote 127.0.0.1:%d)'):format(
        up and 'up' or 'down',
        info.lport or -1,
        info.rport or -1
      )
      local parsed = Util.parse_dest(info.dest)
      if parsed then
        parsed.port = info.port
      end
      local st, _ = Bootstrap.server_status(cfg, parsed, { ws_dir = info.ws_dir })
      if st and st.running then
        lines[#lines + 1] = ('remote server: running (pid %s, %s)'):format(st.pid or '?', st.addr or '?')
      else
        lines[#lines + 1] = 'remote server: not running'
      end
    else
      lines[#lines + 1] = 'no active local session (remote servers may still be running)'
    end

    local remotes = vim.tbl_keys(cfg.remotes or {})
    table.sort(remotes)
    if cfg.host then
      remotes[#remotes + 1] = cfg.host
    end
    if #remotes > 0 then
      lines[#lines + 1] = 'destinations: ' .. table.concat(remotes, ', ')
    end

    for _, l in ipairs(lines) do
      Util.log('%s', l)
    end
    Util.notify(table.concat(lines, '\n'))
  end)
end

---Kill the local tunnel handle (VimLeavePre) — EXCEPT right after an
---attach: the local nvim server stops itself when the UI :connects away
---(upstream :connect semantics), which fires VimLeavePre, and killing
---the tunnel then would instantly sever the just-attached session.
---In every other case the remote server keeps running (that is the
---point); reconnect with :SSHdevConnect.
function M.teardown_local()
  if state.attached then
    return
  end
  if state.tunnel then
    state.tunnel.kill()
    state.tunnel = nil
  end
end

---Introspection for tests / status.
function M.state()
  return {
    info = state.info and vim.deepcopy(state.info) or nil,
    tunnel_alive = state.tunnel and state.tunnel.alive or false,
  }
end

return M
