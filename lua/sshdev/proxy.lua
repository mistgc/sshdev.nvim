--- Local RPC reconnect proxy management.
---
--- `:SshDevConnect` normally hands the builtin TUI to the remote server with
--- |:connect|. That channel is the UI client's *server* channel: when the
--- ssh tunnel dies, nvim's UI client sees EOF and exits
--- (`exit_on_closed_chan()`), taking the whole local nvim process with it.
---
--- With `reconnect` enabled (the default) the attach goes through a small
--- local relay (`scripts/ui_proxy.lua`, a detached headless nvim) instead:
---
---   UI client --:connect--> 127.0.0.1:<listen>  [proxy]  <-- ssh -L --> remote
---
--- The proxy owns the ssh tunnel and the UI's channel is the local relay
--- socket, which never closes. When the tunnel dies the proxy rebuilds it,
--- connects a fresh upstream and replays the UI's own `nvim_ui_attach`
--- parameters there. The remote server sees a new UI attach and sends a full
--- screen; the local UI client sees a normal redraw and the session continues
--- untouched. `reconnect = false` keeps the direct |:connect| behaviour.
---
--- This module only starts/stops that proxy process and waits until its
--- listeners are ready; all reconnect logic lives in `scripts/ui_proxy.lua`.

local Auth = require('sshdev.auth')
local Env = require('sshdev.env')
local Proc = require('sshdev.proc')
local Ssh = require('sshdev.ssh')
local Util = require('sshdev.util')

local uv = vim.uv or vim.loop

local M = {}

---One start attempt per candidate port block.
local MAX_ATTEMPTS = 6
---How long the proxy process may take to bind its listener + write ready.
local READY_TIMEOUT_MS = 10000

---Directory for per-proxy logs and readiness markers.
---@return string? dir
---@return string? err
local function cache_dir()
  local dir = Util.fs_join(vim.fs.normalize(vim.fn.stdpath('cache')), 'sshdev')
  local ok, err = Util.mkdir_p(dir)
  if not ok then
    return nil, ('cannot create %s: %s'):format(dir, tostring(err))
  end
  return dir, nil
end

---@return string
local function new_token()
  return Util.sha_hex(('%s:%s:%d:%s'):format(
    tostring(vim.fn.getpid()),
    tostring(uv.hrtime()),
    math.random(1, 2147483647),
    tostring(vim.v.progpath)
  ))
end

---Is a local TCP port already listened on (best effort, cross-platform)?
---Band-derived from `Proc.await_tcp_accept`.
---@param port integer
---@return boolean busy
local function port_busy(port)
  return Proc.await_tcp_accept('127.0.0.1', port, 150)
end

---Find four adjacent free ports: listen, tunnel, control, admin.
---@param base integer
---@return table? ports { listen, tunnel, control, admin }
---@return string? err
local function pick_ports(base)
  for i = 0, 64 do
    local listen = base + i * 4
    if listen > 65000 then
      break
    end
    local busy = false
    for off = 0, 3 do
      if port_busy(listen + off) then
        busy = true
        break
      end
    end
    if not busy then
      return {
        listen = listen,
        tunnel = listen + 1,
        control = listen + 2,
        admin = listen + 3,
      }
    end
  end
  return nil, ('no free block of four local ports near %d'):format(base)
end

---@param job integer
---@return boolean exited
local function job_exited(job)
  local codes = vim.fn.jobwait({ job }, 0)
  return type(codes) == 'table' and codes[1] ~= -1
end

---@param path string
---@param lines integer|nil
---@return string
local function tail_file(path, lines)
  local ok, fd = pcall(uv.fs_open, path, 'r', 438)
  if not ok or not fd then
    return ''
  end
  local st = uv.fs_fstat(fd)
  local size = st and st.size or 0
  local read = size > 16384 and uv.fs_read(fd, 16384, size - 16384) or uv.fs_read(fd, 16384, 0)
  uv.fs_close(fd)
  if type(read) ~= 'string' then
    return ''
  end
  return Util.tail(read, lines or 12)
end

---@param job integer
local function kill_job(job)
  pcall(vim.fn.jobstop, job)
end

---Environment for the proxy process itself: the workspace's injected
---variables plus the askpass overlay, so the tunnel it (re)spawns can
---authenticate without a terminal.
---@param cfg table
---@param parsed table
---@return table|nil env
---@return string? err
local function proxy_env(cfg, parsed)
  local ok, auth_env = pcall(Auth.env, cfg, parsed)
  if not ok then
    return nil, tostring(auth_env)
  end
  return Util.merge_env(Env.spawn_overlay(parsed), auth_env), nil
end

---Start one proxy on the given ports. Runs inside a flow.
---@param cfg table
---@param parsed table
---@param ports table
---@param rport integer
---@param env table|nil
---@return table? handle
---@return string? err
local function start_on_ports(cfg, parsed, ports, rport, env)
  local root = Util.plugin_root()
  if not root then
    return nil, 'cannot locate the sshdev.nvim plugin directory'
  end
  local script = Util.fs_join(root, 'scripts', 'ui_proxy.lua')
  local st = uv.fs_stat(script)
  if not st or st.type ~= 'file' then
    return nil, ('cannot find %s; is the sshdev.nvim installation complete?'):format(script)
  end
  local dir, derr = cache_dir()
  if not dir then
    return nil, derr
  end

  local token = new_token()
  local ready = Util.fs_join(dir, ('proxy-%s.ready'):format(token))
  local log = Util.fs_join(dir, ('proxy-%s.log'):format(token))
  -- the log is created/truncated by the proxy itself; remove leftovers
  pcall(uv.fs_unlink, ready)

  local lua_path = table.concat({
    Util.fs_join(root, 'lua', '?.lua'),
    Util.fs_join(root, 'lua', '?', 'init.lua'),
  }, ';')

  local conf = {
    listen = ports.listen,
    tunnel = ports.tunnel,
    control = ports.control,
    admin = ports.admin,
    rport = rport,
    -- the detached local server (:connect detaches it from the UI client)
    -- that spawned this proxy; the proxy reaps it when the session really
    -- ends, so a headless orphan never survives the UI
    parent_pid = vim.fn.getpid(),
    ssh_argv = Ssh.proxy_tunnel_args(cfg, parsed, ports.tunnel, ports.control, rport),
    log = log,
    ready = ready,
    token = token,
    lua_path = lua_path,
    title = ('sshdev: reconnecting to %s…'):format(Util.format_dest(parsed)),
    debug = vim.env.SSHDEV_PROXY_DEBUG == '1',
  }

  local job_env = vim.tbl_extend('force', env or {}, {
    SSHDEV_PROXY_CONFIG = vim.json.encode(conf),
  })
  local argv = {
    vim.v.progpath,
    '--headless',
    '-u',
    'NONE',
    '-i',
    'NONE',
    '-c',
    'luafile ' .. vim.fn.fnameescape(script),
  }
  local job = vim.fn.jobstart(argv, {
    detach = true,
    env = job_env,
    on_stderr = function(_, data)
      for _, l in ipairs(type(data) == 'table' and data or {}) do
        if l ~= '' then
          Util.log('[proxy] %s', l)
        end
      end
    end,
  })
  if type(job) ~= 'number' or job <= 0 then
    return nil, 'failed to start the reconnect proxy (nvim --headless)'
  end

  local handle = {
    job = job,
    ports = ports,
    log = log,
    ready = ready,
    token = token,
  }

  ---Tear down a partially started proxy (graceful admin stop when possible).
  ---@param why string
  ---@return nil
  ---@return string
  local function abort(why)
    M.stop(handle)
    return nil, why
  end

  -- 1. the proxy process must bind its listener and write the ready marker
  local deadline = uv.now() + READY_TIMEOUT_MS
  local marked = false
  while uv.now() < deadline do
    if job_exited(job) then
      pcall(uv.fs_unlink, ready)
      return nil, ('the reconnect proxy exited during startup:\n%s'):format(tail_file(log, 10))
    end
    if uv.fs_stat(ready) then
      marked = true
      break
    end
    Proc.sleep(50)
  end
  if not marked then
    return abort(('the reconnect proxy did not become ready:\n%s'):format(tail_file(log, 10)))
  end
  pcall(uv.fs_unlink, ready)

  -- 2. the listen port must accept, and the control forward of the ssh
  --    tunnel must be installed (the caller validates the remote RPC).
  if not Proc.await_tcp_accept('127.0.0.1', ports.listen, 1000) then
    return abort(('the reconnect proxy is not listening on 127.0.0.1:%d:\n%s'):format(
      ports.listen,
      tail_file(log, 10)
    ))
  end
  local ctl_deadline = uv.now() + cfg.timeouts.attach * 1000
  while uv.now() < ctl_deadline do
    if job_exited(job) then
      return abort(('the reconnect proxy exited while opening the tunnel:\n%s'):format(
        tail_file(log, 10)
      ))
    end
    if Proc.await_tcp_accept('127.0.0.1', ports.control, 300) then
      return handle, nil
    end
    Proc.sleep(150)
  end
  return abort(('the reconnect proxy tunnel did not come up within %ds:\n%s'):format(
    cfg.timeouts.attach,
    tail_file(log, 10)
  ))
end

---Start a reconnect proxy for the session. Must run inside a flow.
---@param cfg table
---@param parsed table
---@param rport integer remote nvim listen port
---@param opts table|nil { key = workspace profile key }
---@return table? handle
---@return string? err
function M.start(cfg, parsed, rport, opts)
  opts = opts or {}
  local env, eerr = proxy_env(cfg, parsed)
  if eerr then
    return nil, eerr
  end
  local base = Util.local_port(parsed.dest, opts.key or '')
  local errors = {}
  for _ = 1, MAX_ATTEMPTS do
    local ports, perr = pick_ports(base)
    if not ports then
      return nil, perr
    end
    local handle, err = start_on_ports(cfg, parsed, ports, rport, env)
    if handle then
      Util.log(
        'reconnect proxy ready: UI 127.0.0.1:%d, tunnel %d, control %d, admin %d',
        ports.listen,
        ports.tunnel,
        ports.control,
        ports.admin
      )
      return handle, nil
    end
    errors[#errors + 1] = err
    Util.log('proxy start attempt failed: %s', tostring(err))
    base = ports.listen + 4
  end
  return nil, ('could not start the reconnect proxy:\n%s'):format(table.concat(errors, '\n'))
end

---Is the proxy process still alive?
---@param handle table|nil
---@return boolean
function M.alive(handle)
  return handle ~= nil and type(handle.job) == 'number' and not job_exited(handle.job)
end

---Stop the proxy (gracefully through its admin port when possible).
---Safe from a main-loop context; never throws.
---@param handle table|nil
function M.stop(handle)
  if not handle then
    return
  end
  if type(handle.ports) == 'table' and type(handle.ports.admin) == 'number' then
    pcall(function()
      local ch = vim.fn.sockconnect('tcp', ('127.0.0.1:%d'):format(handle.ports.admin), {
        timeout = 300,
      })
      if type(ch) == 'number' and ch > 0 then
        vim.fn.chanclose(ch)
      end
    end)
  end
  if M.alive(handle) then
    kill_job(handle.job)
  end
  if type(handle.ready) == 'string' then
    pcall(uv.fs_unlink, handle.ready)
  end
  Util.log('reconnect proxy stopped')
end

---Human-readable status line for :SshDevStatus.
---@param handle table|nil
---@return string?
function M.status_line(handle)
  if not handle then
    return nil
  end
  local ports = handle.ports or {}
  local up = M.alive(handle)
  return ('reconnect proxy: %s (UI 127.0.0.1:%s, tunnel %s, control %s)'):format(
    up and 'running' or 'stopped',
    tostring(ports.listen or '?'),
    tostring(ports.tunnel or '?'),
    tostring(ports.control or '?')
  )
end

---Path of the proxy log (for error reporting / :SshDevLog).
---@param handle table|nil
---@return string?
function M.log_path(handle)
  return handle and handle.log or nil
end

---Tail of the proxy log, for user-facing error messages.
---@param handle table|nil
---@param lines integer|nil
---@return string
function M.log_tail(handle, lines)
  if not handle or type(handle.log) ~= 'string' then
    return '(no proxy log)'
  end
  local tail = tail_file(handle.log, lines or 12)
  return tail ~= '' and tail or '(empty proxy log)'
end

return M
