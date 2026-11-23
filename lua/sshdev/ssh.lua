--- ssh/scp plumbing for sshdev.nvim.
---
--- * `run_script`   -- execute POSIX sh on the remote; the script travels on
---                     stdin so no client-side quoting is ever needed.
--- * `upload_*`    -- scp the staged config / shim with a RELATIVE source
---                     path and `cwd` (avoids the Windows "C:" drive-letter
---                     ambiguity in scp arguments).
--- * `start_tunnel` -- a detached `ssh -N -L` job that survives nvim exiting
---                     (the UI attach via :connect stops the local server).
--- * `start_forwards` -- the user port forwards of a workspace (forward.txt):
---                     ONE detached `ssh -N` carrying a `-L` per line.
---
--- All functions take the PARSED destination table from
--- `Util.parse_dest` (with .dest / .user / .host / .port), not a raw string.
---
--- When a password is in play (cfg.auth = "password", or the "auto" mode
--- after a fallback password was entered -- see sshdev.auth) every spawn
--- gets the askpass environment overlay via Auth.env(), so ssh/scp/tunnel
--- authentication never needs a terminal.

local M = {}

local Auth = require('sshdev.auth')
local Proc = require('sshdev.proc')
local Scripts = require('sshdev.remote_scripts')
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
  -- strictly non-interactive when no password is in play: without this an
  -- ssh that wants a password (no askpass, no console) HANGS until the
  -- command timeout instead of failing fast with a Permission-denied
  -- signature (the auto fallback relies on that fast failure).
  if Auth.needs_batch(cfg, parsed) then
    vim.list_extend(args, { '-o', 'BatchMode=yes' })
  end
  vim.list_extend(args, cfg.ssh_args or {})
  return args
end

---Environment for a local ssh/scp child: the workspace's injected variables
---merged with the askpass overlay (auth keys win). The lazy require keeps the
---env <-> ssh module cycle out of load time.
---@param cfg table
---@param parsed table
---@return table|nil
local function proc_env(cfg, parsed)
  local Env = require('sshdev.env')
  return Util.merge_env(Env.spawn_overlay(parsed), Auth.env(cfg, parsed))
end

---Run a POSIX sh script on the remote host. The script is fed on stdin of
---`sh -s`; parameters are embedded by the caller via Util.render().
---
---The workspace's injected environment is exported at the top of the
---script, so the remote command sees those variables (the job's env only
---affects the LOCAL ssh process).
---Returns the await() result: { code, stdout, stderr, timed_out }.
---@param cfg table
---@param parsed table
---@param script string
---@param opts table|nil { timeout (s), label }
---@return table
function M.run_script(cfg, parsed, script, opts)
  opts = opts or {}
  local prefix = require('sshdev.env').script_prefix(parsed)
  if prefix ~= '' then
    script = prefix .. script
  end
  local args = base_args(cfg, parsed, cfg.ssh_bin, 'ssh')
  vim.list_extend(args, { '--', parsed.dest, 'sh', '-s' })
  local res = Proc.await({
    cmd = args,
    input = script,
    env = proc_env(cfg, parsed),
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
---
---opts.preserve adds `-p` (keep the local file mode/mtime on the remote --
---used for env.txt so a 0600 mirror stays 0600).
---Returns the await() result.
---@param cfg table
---@param parsed table
---@param cwd string
---@param filename string
---@param remote_path string
---@param timeout_s number|nil
---@param opts table|nil { preserve = boolean }
---@return table
function M.upload_file(cfg, parsed, cwd, filename, remote_path, timeout_s, opts)
  opts = opts or {}
  local args = base_args(cfg, parsed, cfg.scp_bin, 'scp')
  if opts.preserve then
    vim.list_extend(args, { '-p' })
  end
  vim.list_extend(args, { filename, parsed.dest .. ':' .. remote_path })
  local res = Proc.await({
    cmd = args,
    cwd = cwd,
    env = proc_env(cfg, parsed),
    timeout = timeout_s and timeout_s * 1000 or nil,
    label = 'scp',
  })
  if Auth.is_auth_failure(res) then
    Auth.forget(parsed)
  end
  return res
end

---Force a remote file's mode (e.g. env.txt 0600 after an upload).
---
---An upload cannot be trusted to deliver a restrictive mode: `scp -p` copies
---the local stat() mode, and on Windows that is 0666 even when libuv created
---the file with mode 0600 -- a secret-bearing file would silently become
---world-readable on the remote. The mode is therefore asserted with an
---explicit `chmod` over the same ssh path the other remote scripts use.
---@param cfg table
---@param parsed table
---@param remote_path string absolute remote file
---@param mode string digit mode, e.g. "600"
---@param timeout_s number|nil
---@return table res await() result; success reports `SSHDEV:CHMOD=ok`
function M.chmod_remote(cfg, parsed, remote_path, mode, timeout_s)
  local script = Util.render(Scripts.env_chmod, {
    PATH = Util.shsafe(remote_path, 'remote file'),
    MODE = Util.shsafe(tostring(mode), 'remote file mode'),
  })
  return M.run_script(cfg, parsed, script, {
    timeout = timeout_s,
    label = 'chmod',
  })
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
    env = proc_env(cfg, parsed),
    timeout = timeout_s and timeout_s * 1000 or nil,
    label = 'scp',
  })
  if Auth.is_auth_failure(res) then
    Auth.forget(parsed)
  end
  return res
end

---Spawn a detached `ssh` tunnel job and return its handle.
---
---ControlMaster is explicitly disabled for every tunnel: a multiplexed
---tunnel would die together with a short-lived ControlPersist master;
---these jobs must live as long as the remote session does. They run
---detached from nvim so the UI attach (:connect, which stops the local
---nvim server) does not kill them.
---
---`meta` carries the caller-specific handle fields (dest/lport/rport for
---the session tunnel, specs for the forward tunnel); the shared handle is
---{ job, alive, exit_code, kill(), stderr_tail(), ...meta }.
---@param cfg table
---@param parsed table
---@param args string[] full argv for the tunnel ssh
---@param meta table
---@return table handle
local function spawn_detached_tunnel(cfg, parsed, args, meta)
  -- password mode: the detached ssh process authenticates through askpass
  -- (verified on Windows: detached, console-less children still run it);
  -- the workspace's injected variables are merged underneath the auth keys
  local env = proc_env(cfg, parsed)
  local t = vim.tbl_extend('keep', meta, {
    alive = false,
    stderr = {},
  })
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

---argv for the session tunnel: `ssh -N -L 127.0.0.1:lport -> 127.0.0.1:rport`,
---plus optional extra forwards (the reconnect proxy adds a second `-L` for
---the client control channel). Pure (spawns nothing), so the argument
---construction is unit-testable.
---@param cfg table
---@param parsed table
---@param lport integer
---@param rport integer
---@param extra table[]|nil additional forwards { lport, rport }
---@return string[] args
function M.tunnel_args(cfg, parsed, lport, rport, extra)
  local args = base_args(cfg, parsed, cfg.ssh_bin, 'ssh')
  vim.list_extend(args, {
    '-N',
    '-L',
    ('127.0.0.1:%d:127.0.0.1:%d'):format(lport, rport),
  })
  for _, f in ipairs(extra or {}) do
    vim.list_extend(args, {
      '-L',
      ('127.0.0.1:%d:127.0.0.1:%d'):format(f[1], f[2]),
    })
  end
  vim.list_extend(args, {
    '-o',
    'ControlMaster=no',
    '-o',
    'ExitOnForwardFailure=yes',
    '--',
    parsed.dest,
  })
  return args
end

---argv for the reconnect proxy's tunnel: the UI stream forward plus the
---control-channel forward, both on loopback.
---@param cfg table
---@param parsed table
---@param lport integer UI stream forward
---@param cport integer control-channel forward
---@param rport integer remote listen port
---@return string[] args
function M.proxy_tunnel_args(cfg, parsed, lport, cport, rport)
  return M.tunnel_args(cfg, parsed, lport, rport, { { cport, rport } })
end

---Start the local forward `ssh -N -L 127.0.0.1:lport -> 127.0.0.1:rport`.
---
---Returns a handle table { job, alive, kill(), dest, lport, rport }.
---@param cfg table
---@param parsed table
---@param lport integer
---@param rport integer
---@return table
function M.start_tunnel(cfg, parsed, lport, rport)
  local args = M.tunnel_args(cfg, parsed, lport, rport)
  return spawn_detached_tunnel(cfg, parsed, args, {
    dest = parsed.dest,
    lport = lport,
    rport = rport,
  })
end

---argv for the user port-forward tunnel: ONE `ssh -N` carrying every `-L`
---forward of the workspace's forward.txt. Pure (spawns nothing), so the
---argument construction is unit-testable.
---
---Each spec is { lport, rhost, rport } from sshdev.forward.parse(). The
---local side binds 127.0.0.1 (loopback only, like the session tunnel);
---ExitOnForwardFailure makes ssh exit when a port cannot be bound instead
---of silently dropping that one forward.
---@param cfg table
---@param parsed table
---@param specs table[] { lport = integer, rhost = string, rport = integer }
---@return string[] args
function M.forward_tunnel_args(cfg, parsed, specs)
  local args = base_args(cfg, parsed, cfg.ssh_bin, 'ssh')
  vim.list_extend(args, { '-N', '-o', 'ControlMaster=no', '-o', 'ExitOnForwardFailure=yes' })
  for _, s in ipairs(specs) do
    vim.list_extend(args, {
      '-L',
      ('127.0.0.1:%d:%s:%d'):format(s.lport, s.rhost, s.rport),
    })
  end
  vim.list_extend(args, { '--', parsed.dest })
  return args
end

---Start the user port-forward tunnel (see |forward_tunnel_args|). All
---forwards share ONE detached ssh process that is killed and replaced as a
---unit whenever forward.txt is saved again.
---
---Returns a handle table { job, alive, kill(), dest, specs }.
---@param cfg table
---@param parsed table
---@param specs table[] { lport = integer, rhost = string, rport = integer }
---@return table
function M.start_forwards(cfg, parsed, specs)
  local args = M.forward_tunnel_args(cfg, parsed, specs)
  return spawn_detached_tunnel(cfg, parsed, args, {
    dest = parsed.dest,
    specs = vim.deepcopy(specs),
  })
end

---Best-effort check whether a local TCP port is free (bind + close).
---Accurate on POSIX; on Windows libuv binds with SO_REUSEADDR, which
---succeeds even over another process's listener, so a "free" result is
---no guarantee there -- the authoritative verdict for the user forwards
---is the verified post-spawn wait (sshdev.forward), which catches
---whatever ssh could not bind.
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
