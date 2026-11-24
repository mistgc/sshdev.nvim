--- sshdev.nvim local UI reconnect proxy.
---
--- Started by `lua/sshdev/proxy.lua` as a detached headless nvim:
---
---   nvim --headless -u NONE -i NONE -c "luafile <this file>"
---
--- with the configuration in `$SSHDEV_PROXY_CONFIG` (JSON):
---
---   {
---     "listen": 24717,          -- local port the UI attaches to (:connect host:port)
---     "tunnel": 24718,          -- local port of the ssh -L for the UI RPC stream
---     "control": 24719,         -- second ssh -L for the client control channel
---     "admin": 24720,           -- one-shot local port: graceful stop
---     "rport": 25747,           -- remote nvim --listen port
---     "parent_pid": 1234,       -- detached local server to reap at session end
---     "ssh_argv": ["ssh", ...], -- full ssh command line for the tunnel
---     "log": "…/proxy-<token>.log",
---     "ready": "…/proxy-<token>.ready",
---     "token": "…",
---     "lua_path": "…/lua/?/init.lua;…/lua/?.lua"
---   }
---
--- What it does: a transparent msgpack-RPC relay between the local UI client
--- and the remote server.
---
---   server/workstation                proxy (this file)              remote
---   UI client  --- RPC bytes --->  listen P  --- relay --->  ssh -L T -> rport
---                                   | owns the ssh tunnel (-L T, -L C)
---                                   | rebuilds it on failure
---                                   | replays the UI attach after a reconnect
---
--- A UI client whose *server* channel closes exits with the process (nvim's
--- `exit_on_closed_chan`), which is why the relay — not the UI — owns the
--- network link: the UI's channel is the local relay socket and never dies.
--- When the upstream ssh connection drops, the proxy keeps the UI channel
--- open, rebuilds the tunnel and connects a fresh upstream, then sends the
--- UI's own `nvim_ui_attach` parameters on the new channel. From the remote
--- server's point of view a new UI simply attached, so it sends a full
--- screen; from the UI client's point of view nothing happened at all.
---
--- Everything here runs with `-u NONE`: it must not depend on the user's
--- config, plugins or this repository being on the runtimepath beyond the
--- `sshdev.proxy_proto` pure helpers required below.

local raw_config = vim.env.SSHDEV_PROXY_CONFIG or ''
if raw_config == '' then
  os.exit(2)
end
local ok, cfg = pcall(vim.json.decode, raw_config)
if not ok or type(cfg) ~= 'table' then
  os.exit(2)
end
if type(cfg.lua_path) == 'string' and cfg.lua_path ~= '' then
  package.path = cfg.lua_path .. ';' .. package.path
end
local Proto = require('sshdev.proxy_proto')

local uv = vim.uv
local logpath = cfg.log
local readypath = cfg.ready
local title = cfg.title or 'sshdev: reconnecting…'

---@param fmt string
local function log(fmt, ...)
  local msg = select('#', ...) > 0 and fmt:format(...) or fmt
  local line = ('[%s] %s\n'):format(os.date('%H:%M:%S'), msg)
  local fd = io.open(logpath, 'a')
  if fd then
    fd:write(line)
    fd:close()
  end
end

local function write_ready()
  local fd = uv.fs_open(readypath, 'w', 384) -- 0600
  if not fd then
    log('cannot write the ready file %s', readypath)
    return
  end
  uv.fs_write(fd, tostring(cfg.token or 'ready'), 0)
  uv.fs_close(fd)
end

local function remove_ready()
  pcall(uv.fs_unlink, readypath)
end

---Proxy state.
local state = {
  srv = nil, -- listening socket (P)
  admin = nil, -- graceful-stop listener
  down = nil, -- the one UI client connection
  down_has_data = false, -- this downstream sent any bytes
  up = nil, -- upstream connection (to the ssh tunnel at T)
  up_pending = nil, -- in-flight upstream connect handle
  tunnel = nil, -- ssh job id
  tunnel_alive = false,
  tunnel_stderr = {},
  pending = '', -- downstream bytes not parsed yet
  reconnecting = false,
  loss_pending = false, -- upstream EOF seen, deciding between reconnect/quit
  attach_args = nil, -- last nvim_ui_attach arguments (width, height, opts)
  client_info = nil, -- last nvim_set_client_info arguments
  attach_sent = false, -- attach already replayed on the current upstream
  had_ui = false,
  admin_stop = false,
  ever_connected = false,
  stopping = false,
  retry_at = 0,
  backoff = 1000,
  debug_frames = 0,
  start_ms = uv.now(),
}

local TICK_MS = 100
---If the plugin started this proxy but never completed :connect (a crash,
---a killed nvim), do not linger as an invisible headless process forever.
local UI_DEADLINE_MS = 180000

local function schedule(fn, ms)
  vim.defer_fn(fn, ms or 0)
end

local function close_handle(h)
  if h and not h:is_closing() then
    h:close()
  end
end

---Stop the ssh tunnel. Safe from a fast event context (jobstop is nvim API).
local function stop_tunnel()
  local job = state.tunnel
  state.tunnel = nil
  state.tunnel_alive = false
  if not job then
    return
  end
  local function stop()
    pcall(vim.fn.jobstop, job)
  end
  if vim.in_fast_event() then
    vim.schedule(stop)
  else
    stop()
  end
end

local function quit(reason)
  if state.stopping then
    return
  end
  state.stopping = true
  log('exiting: %s', tostring(reason))
  -- The local server is detached from the UI client by :connect and would
  -- otherwise outlive the session as a headless orphan once the UI is gone.
  -- Only reap it for a real session end: an explicit stop (admin port) is
  -- the plugin tearing the proxy down from that very server.
  local reap_parent = state.had_ui
    and not state.admin_stop
    and type(cfg.parent_pid) == 'number'
    and cfg.parent_pid > 0
  close_handle(state.down)
  state.down = nil
  close_handle(state.up_pending)
  state.up_pending = nil
  close_handle(state.up)
  state.up = nil
  close_handle(state.srv)
  state.srv = nil
  close_handle(state.admin)
  state.admin = nil
  stop_tunnel()
  remove_ready()
  if reap_parent then
    log('reaping the detached local server (pid %d)', cfg.parent_pid)
    pcall(uv.kill, cfg.parent_pid, 'sigterm')
  end
  schedule(function()
    pcall(vim.cmd, 'qa!')
  end, 0)
end

local function auth_failure()
  for _, l in ipairs(state.tunnel_stderr) do
    if l:find('Permission denied%s*%(%a') then
      return true
    end
  end
  return false
end

local function bind_failure()
  for _, l in ipairs(state.tunnel_stderr) do
    local lower = l:lower()
    if
      lower:find('address already in use', 1, true)
      or lower:find('cannot listen to port', 1, true)
    then
      return true
    end
  end
  return false
end

local function start_tunnel()
  if state.stopping or state.tunnel_alive then
    return
  end
  state.tunnel_stderr = {}
  local job = vim.fn.jobstart(cfg.ssh_argv, {
    -- NOT detached: the tunnel must die with the proxy, which owns the
    -- session's network link. The proxy itself is detached by the plugin so
    -- it survives the local server going headless on :connect.
    on_stderr = function(_, data)
      if type(data) ~= 'table' then
        return
      end
      for _, l in ipairs(data) do
        if l ~= '' then
          state.tunnel_stderr[#state.tunnel_stderr + 1] = l
          if #state.tunnel_stderr > 20 then
            table.remove(state.tunnel_stderr, 1)
          end
        end
      end
    end,
    on_exit = function(_, code)
      state.tunnel_alive = false
      log('tunnel exited (code %s)', tostring(code))
      schedule(function()
        if state.stopping or state.tunnel ~= nil then
          return
        end
        if auth_failure() then
          quit('ssh authentication failed')
          return
        end
        -- The first tunnel attempt failing on a busy local port means the
        -- plugin's port guess collided: exit, and let it retry elsewhere.
        if not state.ever_connected and bind_failure() then
          quit('ssh tunnel could not bind its local ports')
          return
        end
        state.retry_at = uv.now() + state.backoff
        state.backoff = math.min(state.backoff * 2, 30000)
      end)
    end,
  })
  if type(job) ~= 'number' or job <= 0 then
    log('cannot spawn the ssh tunnel')
    schedule(function()
      state.retry_at = uv.now() + state.backoff
      state.backoff = math.min(state.backoff * 2, 30000)
    end)
    return
  end
  state.tunnel = job
  state.tunnel_alive = true
  log('tunnel started (job %d)', job)
end

---Send the captured nvim_ui_attach (and client info) on the current upstream.
---@return boolean sent
local function send_attach()
  if not state.up or not state.attach_args or state.attach_sent then
    return false
  end
  state.up:write(vim.mpack.encode({ 2, 'nvim_ui_attach', state.attach_args }))
  if state.client_info then
    state.up:write(vim.mpack.encode({ 2, 'nvim_set_client_info', state.client_info }))
  end
  state.attach_sent = true
  log(
    'sent nvim_ui_attach (%sx%s) upstream',
    tostring(state.attach_args[1]),
    tostring(state.attach_args[2])
  )
  return true
end

---Parse complete downstream messages.
---
---The proxy owns the attach handshake: the UI's own nvim_ui_attach is
---captured (and replayed on every new upstream), input messages are dropped
---while the link is down, and a resize updates the saved attach geometry.
---@param data string
local function parse_downstream(data)
  state.pending = state.pending .. data
  while state.pending ~= '' do
    local frame, rest, ok = Proto.next_frame(state.pending)
    if not frame then
      if not ok then
        log('dropping %d unparseable downstream byte(s)', #state.pending)
        state.pending = ''
      end
      return
    end
    state.pending = rest
    local info = Proto.message_info(frame)
    if info and info.method == 'nvim_ui_attach' then
      state.had_ui = true
      state.attach_args = info.args
      state.attach_sent = false
      log(
        'captured nvim_ui_attach (%sx%s)',
        tostring(state.attach_args[1]),
        tostring(state.attach_args[2])
      )
      if state.up and not state.reconnecting then
        send_attach()
      end
    elseif info and info.method == 'nvim_set_client_info' then
      state.client_info = info.args
      if state.up and state.attach_sent and not state.reconnecting then
        state.up:write(frame)
      end
    elseif info and info.method == 'nvim_ui_try_resize' and state.attach_args then
      state.attach_args[1] = info.args[1]
      state.attach_args[2] = info.args[2]
      if state.up and state.attach_sent then
        state.up:write(frame)
      end
    elseif state.up and state.attach_sent and not (state.reconnecting and Proto.is_input(info)) then
      state.up:write(frame)
    end
  end
end

---The upstream RPC channel ended. Either the remote server closed it (quit,
---detach) or the network died. The tunnel's own exit tells them apart.
local function on_upstream_lost()
  if state.stopping then
    return
  end
  state.loss_pending = true
  schedule(function()
    state.loss_pending = false
    if state.stopping or state.up then
      return
    end
    local alive = state.tunnel_alive
    if state.tunnel and vim.fn.jobwait({ state.tunnel }, 0)[1] ~= -1 then
      alive = false
    end
    if alive then
      -- ssh is fine but the RPC channel died: the remote server stopped (or
      -- detached the UI). Do not resurrect it.
      quit('the remote server closed the UI channel')
      return
    end
    -- Network drop: keep the UI channel open, rebuild the tunnel.
    state.reconnecting = true
    state.attach_sent = false
    stop_tunnel()
    close_handle(state.up_pending)
    state.up_pending = nil
    close_handle(state.up)
    state.up = nil
    state.backoff = 1000
    state.retry_at = uv.now()
    if state.down and not state.down:is_closing() then
      -- visible hint in the terminal title while the screen is frozen
      state.down:write(Proto.encode_title(title))
    end
    log('reconnecting: the network link dropped')
  end, 300)
end

local function try_upstream()
  if state.stopping or state.up or state.up_pending or not state.tunnel_alive then
    return
  end
  local up = uv.new_tcp()
  state.up_pending = up
  up:connect('127.0.0.1', cfg.tunnel, function(err)
    if state.up_pending ~= up then
      close_handle(up)
      return
    end
    state.up_pending = nil
    if err then
      close_handle(up)
      return
    end
    state.up = up
    state.attach_sent = false
    if cfg.debug then
      state.debug_frames = 8
    end
    up:read_start(function(er, data)
      if er or data == nil or data == '' then
        close_handle(up)
        if state.up == up then
          state.up = nil
        end
        on_upstream_lost()
        return
      end
      state.ever_connected = true
      if cfg.debug and state.debug_frames > 0 then
        state.debug_frames = state.debug_frames - 1
        log('upstream data: %d byte(s)', #data)
      end
      if state.attach_sent then
        state.backoff = 1000
        state.reconnecting = false
      end
      if state.down and not state.down:is_closing() then
        state.down:write(data)
      end
    end)
    log('upstream connected')
    send_attach()
  end)
end

local function accept_down()
  local down = uv.new_tcp()
  local ok = state.srv:accept(down)
  if not ok then
    close_handle(down)
    return
  end
  if state.down and not state.down:is_closing() then
    if state.had_ui then
      -- the one UI is already attached: readiness probe or a duplicate
      log('ignoring an extra connection while the UI is attached')
      close_handle(down)
      return
    end
    close_handle(state.down)
  end
  state.down = down
  state.down_has_data = false
  log('UI connected')
  down:read_start(function(er, data)
    if er or data == nil or data == '' then
      close_handle(down)
      local had_data = state.down_has_data
      if state.down == down then
        state.down = nil
        state.down_has_data = false
      end
      -- A readiness probe connects and closes without sending anything;
      -- never mistake it for the UI going away.
      if had_data and not state.stopping then
        quit('the UI client disconnected')
      end
      return
    end
    state.down_has_data = true
    parse_downstream(data)
  end)
  if not state.up then
    try_upstream()
  end
end

local function tick()
  if state.stopping then
    return
  end
  if not state.had_ui and uv.now() - state.start_ms > UI_DEADLINE_MS then
    quit('no UI attached to the proxy')
    return
  end
  local now = uv.now()
  if not state.up and not state.loss_pending and now >= state.retry_at then
    if not state.tunnel_alive then
      start_tunnel()
    end
    if state.tunnel_alive and not state.up_pending then
      try_upstream()
    end
    state.retry_at = now + 200
  end
  schedule(tick, TICK_MS)
end

local function main()
  local srv = uv.new_tcp()
  if not srv then
    log('cannot allocate the listening socket')
    quit('no listening socket')
    return
  end
  if not srv:bind('127.0.0.1', cfg.listen) then
    log('cannot bind 127.0.0.1:%d', cfg.listen)
    quit('cannot bind the proxy port')
    return
  end
  state.srv = srv
  srv:listen(16, function(err)
    if err then
      log('listen error: %s', tostring(err))
      return
    end
    accept_down()
  end)
  write_ready()
  log(
    'listening on 127.0.0.1:%d (tunnel %d, control %d, remote 127.0.0.1:%d)',
    cfg.listen,
    cfg.tunnel,
    cfg.control,
    cfg.rport
  )

  local admin = uv.new_tcp()
  if admin and admin:bind('127.0.0.1', cfg.admin) then
    state.admin = admin
    admin:listen(4, function()
      local c = uv.new_tcp()
      admin:accept(c)
      close_handle(c)
      state.admin_stop = true
      quit('stop requested by the client')
    end)
  end

  start_tunnel()
  schedule(tick, 0)
end

main()
