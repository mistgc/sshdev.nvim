--- ssh/scp plumbing for sshdev.nvim.
---
--- * `run_script`   -- execute POSIX sh on the remote; the script travels on
---                     stdin so no client-side quoting is ever needed.
--- * `upload_*`    -- scp the staged config / shim with a RELATIVE source
---                     path and `cwd` (avoids the Windows "C:" drive-letter
---                     ambiguity in scp arguments).
--- * `start_tunnel` -- a detached `ssh -N -L` job that survives nvim exiting
---                     (the UI attach via :connect stops the local server).
---
--- All functions take the PARSED destination table from
--- `Util.parse_dest` (with .dest / .user / .host / .port), not a raw string.
---
--- In password mode (cfg.auth = "password", see sshdev.auth) every spawn
--- gets the askpass environment overlay via Auth.env(), so ssh/scp/tunnel
--- authentication never needs a terminal.

local M = {}

local Auth = require('sshdev.auth')
local Proc = require('sshdev.proc')
local Util = require('sshdev.util')

---libuv handle (vim.uv in >= 0.10, vim.loop as legacy alias).
local uv = vim.uv or vim.loop

---Base ssh options applied to every invocation: bounded connect timeout,
---keepalives so dead networks are detected, and accept-new host keys
---(OpenSSH >= 7.6 required).
---@param cfg table
---@param parsed table
---@param bin string
---@param flagstyle 'ssh'|'scp'
---@return string[]
local function base_args(cfg, parsed, bin, flagstyle)
  local args = { bin }
  vim.list_extend(args, {
    '-o',
    'ConnectTimeout=15',
    '-o',
    'ServerAliveInterval=15',
    '-o',
    'ServerAliveCountMax=3',
    '-o',
    'StrictHostKeyChecking=accept-new',
  })
  if parsed.port then
    if flagstyle == 'scp' then
      vim.list_extend(args, { '-P', tostring(parsed.port) })
    else
      vim.list_extend(args, { '-p', tostring(parsed.port) })
    end
  end
  vim.list_extend(args, cfg.ssh_args or {})
  return args
end

---Run a POSIX sh script on the remote host. The script is fed on stdin of
---`sh -s`; parameters are embedded by the caller via Util.render().
---Returns the await() result: { code, stdout, stderr, timed_out }.
---@param cfg table
---@param parsed table
---@param script string
---@param opts table|nil { timeout (s), label }
---@return table
function M.run_script(cfg, parsed, script, opts)
  opts = opts or {}
  local args = base_args(cfg, parsed, cfg.ssh_bin, 'ssh')
  vim.list_extend(args, { '--', parsed.dest, 'sh', '-s' })
  local res = Proc.await({
    cmd = args,
    input = script,
    env = Auth.env(cfg, parsed),
    timeout = opts.timeout and opts.timeout * 1000 or nil,
    label = opts.label,
  })
  if Auth.is_auth_failure(res) then
    Auth.forget(parsed)
  end
  return res
end

---scp one local file (relative to `cwd`) to an absolute remote path.
---
---The remote path is passed RAW (no shell quoting): OpenSSH >= 9 scp uses
---the SFTP protocol by default, where the remote path never goes through a
---remote shell, and literal quotes in it make Windows' scp fail with
---"realpath ...: No such file / path canonicalization failed".
---Returns the await() result.
---@param cfg table
---@param parsed table
---@param cwd string
---@param filename string
---@param remote_path string
---@param timeout_s number|nil
---@return table
function M.upload_file(cfg, parsed, cwd, filename, remote_path, timeout_s)
  local args = base_args(cfg, parsed, cfg.scp_bin, 'scp')
  vim.list_extend(args, { filename, parsed.dest .. ':' .. remote_path })
  local res = Proc.await({
    cmd = args,
    cwd = cwd,
    env = Auth.env(cfg, parsed),
    timeout = timeout_s and timeout_s * 1000 or nil,
    label = 'scp',
  })
  if Auth.is_auth_failure(res) then
    Auth.forget(parsed)
  end
  return res
end

---scp one local directory (relative to `cwd`) INTO `remote_parent`
---(resulting in remote_parent/<dirname>/). The parent must exist.
---Returns the await() result.
---@param cfg table
---@param parsed table
---@param cwd string
---@param dirname string
---@param remote_parent string
---@param timeout_s number|nil
---@return table
function M.upload_dir(cfg, parsed, cwd, dirname, remote_parent, timeout_s)
  local args = base_args(cfg, parsed, cfg.scp_bin, 'scp')
  vim.list_extend(args, { '-C', '-r', dirname, parsed.dest .. ':' .. remote_parent })
  local res = Proc.await({
    cmd = args,
    cwd = cwd,
    env = Auth.env(cfg, parsed),
    timeout = timeout_s and timeout_s * 1000 or nil,
    label = 'scp',
  })
  if Auth.is_auth_failure(res) then
    Auth.forget(parsed)
  end
  return res
end

---Start the local forward `ssh -N -L 127.0.0.1:lport -> 127.0.0.1:rport`.
---
---ControlMaster is explicitly disabled for the tunnel: a multiplexed
---tunnel would die together with a short-lived ControlPersist master;
---this job must live as long as the remote session does. The job runs
---detached from nvim so the UI attach (:connect, which stops the local
---nvim server) does not kill it.
---
---Returns a handle table { job, alive, kill(), dest, lport, rport }.
---@param cfg table
---@param parsed table
---@param lport integer
---@param rport integer
---@return table
function M.start_tunnel(cfg, parsed, lport, rport)
  local args = base_args(cfg, parsed, cfg.ssh_bin, 'ssh')
  vim.list_extend(args, {
    '-N',
    '-L',
    ('127.0.0.1:%d:127.0.0.1:%d'):format(lport, rport),
    '-o',
    'ControlMaster=no',
    '-o',
    'ExitOnForwardFailure=yes',
    '--',
    parsed.dest,
  })
  -- password mode: the detached ssh process authenticates through askpass
  -- (verified on Windows: detached, console-less children still run it)
  local env = Auth.env(cfg, parsed)
  local t = {
    dest = parsed.dest,
    lport = lport,
    rport = rport,
    alive = false,
    stderr = {},
  }
  function t.stderr_tail()
    return Util.tail(table.concat(t.stderr, '\n'), 8)
  end
  function t.kill()
    if t.job and t.job > 0 then
      pcall(vim.fn.jobstop, t.job)
    end
    t.job = nil
    t.alive = false
  end
  t.job = vim.fn.jobstart(args, {
    detach = true,
    env = env,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if l ~= '' then
          t.stderr[#t.stderr + 1] = l
          if #t.stderr > 20 then
            table.remove(t.stderr, 1)
          end
          Util.log('[tunnel] %s', l)
        end
      end
    end,
    on_exit = function(_, code)
      t.alive = false
      t.exit_code = code
      Util.log('[tunnel] exited code=%s', tostring(code))
      if code ~= 0 and Auth.auth_failure_in(t.stderr_tail()) then
        Auth.forget(parsed)
      end
    end,
  })
  t.alive = type(t.job) == 'number' and t.job > 0
  if not t.alive then
    t.job = nil
  end
  return t
end

---Best-effort check whether a local TCP port is free (bind + close).
---@param port integer
---@return boolean
function M.local_port_free(port)
  local tcp = uv.new_tcp()
  if not tcp then
    return false
  end
  local ok = tcp:bind('127.0.0.1', port)
  pcall(function()
    tcp:close()
  end)
  return ok == true or ok == 0
end

---Find a free local port at or above `base` (deterministic base).
---@param base integer
---@return integer? port
---@return string? err
function M.pick_local_port(base)
  local port = base
  for _ = 1, 16 do
    if M.local_port_free(port) then
      return port
    end
    port = port + 1
  end
  return nil, ('no free local port found near %d'):format(base)
end

return M
