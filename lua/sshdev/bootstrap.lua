--- Everything sshdev.nvim does ON THE REMOTE HOST.
---
--- Remote layout (see |sshdev.layout|):
---
---   <remote_root>/
---   ├── nvim-bins/<nvim-version>/              nvim releases, shared
---   ├── nvim-profiles/<nvim-profile-key>/      reusable config + plugins
---   │   ├── nvim-bin -> ../../nvim-bins/<version>
---   │   ├── nvim-config/  xdg/share/  xdg/state/  xdg/cache/
---   │   └── .ready  nvim-version  config-hash  client-host
---   └── workspace-profiles/<workspace-key>/    per (client, workspace) state
---       ├── nvim-profile -> ../../nvim-profiles/<key>
---       ├── session.lua  session.vim  last_used
---       ├── server.pid  server.addr  server.log
---       └── workspace.txt  nvim-profile.txt  client-host
---
--- Remote scripts are POSIX sh, rendered from templates and executed via
--- `ssh host sh -s` with the script on stdin (zero quoting hazards). They
--- report machine-readable `SSHDEV:KEY=VALUE` lines; profile listings use
--- TAB-separated `SSHDEV:WS=` / `SSHDEV:NP=` rows.

local Auth = require('sshdev.auth')
local Layout = require('sshdev.layout')
local Scripts = require('sshdev.remote_scripts')
local Ssh = require('sshdev.ssh')
local Util = require('sshdev.util')

local M = {}

-----------------------------------------------------------------------
-- Platform helpers
-----------------------------------------------------------------------

---Neovim release asset for a remote platform (mirrors the shell logic).
---@param sys string
---@param machine string
---@return string? asset
function M.asset_name(sys, machine)
  local s = sys:lower()
  local m = machine:lower()
  if s:find('linux') then
    if m == 'x86_64' or m == 'amd64' then
      return 'nvim-linux-x86_64'
    elseif m == 'aarch64' or m == 'arm64' then
      return 'nvim-linux-aarch64'
    end
  elseif s:find('darwin') then
    if m == 'arm64' or m == 'aarch64' then
      return 'nvim-macos-arm64'
    elseif m == 'x86_64' or m == 'amd64' then
      return 'nvim-macos-x86_64'
    end
  end
  return nil
end

---Resolve which nvim release to install on the remote.
---@param cfg table
---@return string tag
---@return boolean dev_fallback
---@return string? warn
function M.resolve_version(cfg)
  local wanted = cfg.nvim_version or 'auto'
  if wanted ~= 'auto' then
    if wanted == 'nightly' or wanted == 'stable' then
      return wanted, false, nil
    end
    if not wanted:match('^v') then
      wanted = 'v' .. wanted
    end
    return wanted, false, nil
  end
  local tag, dev = Util.nvim_version_tag()
  if dev then
    return 'nightly', true, ('local nvim %s is a dev build; installing "nightly" remotely '
      .. '(pin cfg.nvim_version to control this)'):format(tag)
  end
  return tag, false, nil
end

-----------------------------------------------------------------------
-- Probe
-----------------------------------------------------------------------

---Probe the remote host. Must run in a flow.
---
---In "auto" auth mode a rejected non-interactive attempt falls back to
---asking for a password once (inputsecret) and retrying here, so every
---flow that starts with this probe (connect/install/sync/profiles/
---pickers) gains the fallback transparently.
---@param cfg table
---@param parsed table
---@return table? probe { home, sys, machine }
---@return string? err
function M.probe(cfg, parsed)
  local function attempt()
    return Ssh.run_script(cfg, parsed, Scripts.probe, {
      timeout = cfg.timeouts.ssh,
      label = 'ssh',
    })
  end

  local res = attempt()
  local fallback_note = ''
  local used_password = Auth.mode(cfg) == 'password'

  -- auto mode: the server rejected key/agent auth -> ask for a password
  -- once and retry. A cancelled prompt or a headless session keeps the
  -- ORIGINAL ssh failure (plus a note) instead of failing on the prompt.
  if res.code ~= 0 and Auth.wants_fallback(cfg, res) then
    local pw, aerr = Auth.ensure(cfg, parsed)
    if pw then
      used_password = true
      Util.log('non-interactive auth to %s was rejected; retrying with a password', parsed.dest)
      res = attempt()
    else
      fallback_note = '\n(password fallback unavailable: ' .. tostring(aerr) .. ')'
    end
  end

  if res.code ~= 0 then
    local hint = ''
    if used_password and Auth.is_auth_failure(res) then
      -- Ssh.run_script already dropped the cached password
      hint = '\n(the password was rejected; run the command again to re-enter it)'
    end
    return nil, ('ssh connection to %s failed (exit %s)%s%s%s'):format(
      parsed.dest,
      res.code,
      res.stderr ~= '' and (':\n' .. Util.tail(res.stderr, 5)) or '',
      fallback_note,
      hint
    )
  end
  local kv = Util.parse_keyvals(res.stdout)
  if kv.SH ~= 'ok' then
    return nil, 'the remote host did not run POSIX sh (is it a Linux/macOS box?)'
  end
  if not kv.HOME or kv.HOME == '' then
    return nil, 'the remote host did not report $HOME'
  end
  return {
    home = kv.HOME,
    sys = kv.SYS or 'unknown',
    machine = kv.MACHINE or 'unknown',
  }
end

-----------------------------------------------------------------------
-- Steps (run inside a flow coroutine)
-----------------------------------------------------------------------

---Ensure the versioned nvim binary, then report profile/server state.
---Deliberately read-only with respect to the profiles: an explicitly
---requested nvim profile may not exist, and nothing should be created for it
---before the client falls back to the auto profile.
---@param cfg table
---@param parsed table
---@param layout table
---@param probe table from M.probe()
---@return table? info
---@return string? err
function M.ensure(cfg, parsed, layout, probe)
  local auto_np = Util.join_remote(layout.nvim_profiles_root, Layout.auto_nvim_profile_key(layout))
  local script = Util.render(Scripts.ensure, {
    ROOT = Util.shsafe(layout.root, 'remote root'),
    VERSION = Util.shsafe(layout.nvim_version, 'nvim version'),
    MIRROR = Util.shsafe(cfg.download_mirror, 'download mirror'),
    PROXY = cfg.proxy and Util.shsafe(cfg.proxy, 'proxy') or '',
    NP = Util.shsafe(layout.nvim_profile, 'nvim profile dir'),
    AUTO_NP = Util.shsafe(auto_np, 'auto nvim profile dir'),
    WS_PROFILE = Util.shsafe(layout.workspace_profile, 'workspace profile dir'),
    PLATFORM = Util.shsafe(('%s-%s'):format(probe.sys, probe.machine), 'platform'),
    SYS = Util.shsafe(probe.sys, 'remote sys'),
    MACHINE = Util.shsafe(probe.machine, 'remote machine'),
    FIND_RUNNING = Scripts.find_running,
  })

  local res = Ssh.run_script(cfg, parsed, script, {
    timeout = cfg.timeouts.download,
    label = 'ssh',
  })
  local kv = Util.parse_keyvals(res.stdout)

  if kv.ERROR == 'unsupported-platform' then
    return nil, ('the remote platform (%s %s) has no official nvim release; '
      .. 'install Neovim >= 0.12 there manually'):format(probe.sys, probe.machine)
  end
  if kv.ERROR == 'curl-missing' or kv.ERROR == 'tar-missing' then
    return nil, ('the remote host has no %s; cannot download nvim'):format(
      kv.ERROR:gsub('%-missing', '')
    )
  end
  if kv.ERROR == 'bad-archive' then
    return nil, ('the downloaded archive for %s did not contain bin/nvim '
      .. '(check download_mirror: %s)'):format(layout.nvim_version, cfg.download_mirror)
  end
  if res.code ~= 0 or not kv.BIN then
    return nil, ('preparing nvim %s on the remote failed (exit %s):\n%s'):format(
      layout.nvim_version,
      res.code,
      Util.tail(res.stderr .. res.stdout, 10)
    )
  end

  return {
    bin = kv.BIN,
    bin_dir = kv.BIN_DIR,
    asset = kv.ASSET,
    version_line = kv.BINVERSION or '?',
    np_exists = kv.NP_EXISTS == 'yes',
    np_ready = kv.NP_READY_HASH or '',
    auto_exists = kv.AUTO_EXISTS == 'yes',
    auto_ready = kv.AUTO_READY_HASH or '',
    server = kv.SERVER,
    pid = kv.PID,
    addr = kv.ADDR,
    has_session = kv.SESSION == 'yes',
  }
end

---Create/refresh profile directories, relative links and metadata files.
---Must run after the nvim profile decision (auto vs explicit reuse).
---@param cfg table
---@param parsed table
---@param layout table
---@param opts table|nil {
---   own: boolean|nil       this client owns the nvim profile (default true);
---                          false = an explicitly reused profile: its bin
---                          link and metadata must never be rewritten,
---   staging: boolean|nil   a config upload follows (default true),
--- }
---@return boolean? ok
---@return string? err
function M.prepare(cfg, parsed, layout, opts)
  opts = opts or {}
  local own = opts.own ~= false
  local staging = ''
  if own and opts.staging ~= false then
    staging = layout.staging_dir
  end
  local script = Util.render(Scripts.prepare, {
    ROOT = Util.shsafe(layout.root, 'remote root'),
    NP = Util.shsafe(layout.nvim_profile, 'nvim profile dir'),
    NP_KEY = Util.shsafe(layout.nvim_profile_key, 'nvim profile key'),
    WS_PROFILE = Util.shsafe(layout.workspace_profile, 'workspace profile dir'),
    WS_KEY = Util.shsafe(layout.workspace_profile_key, 'workspace profile key'),
    WORKSPACE = Util.shsafe(layout.workspace, 'workspace'),
    STAGING = Util.shsafe(staging, 'staging dir'),
    VERSION = Util.shsafe(layout.nvim_version, 'nvim version'),
    HOST = Util.shsafe(layout.hostname, 'local hostname'),
    NP_BIN_TARGET = Util.shsafe(layout.nvim_bin_link_target, 'nvim bin link target'),
    NP_LINK_TARGET = Util.shsafe(layout.nvim_profile_link_target, 'nvim profile link target'),
    OWN = own and '1' or '0',
  })
  local res = Ssh.run_script(cfg, parsed, script, {
    timeout = cfg.timeouts.ssh,
    label = 'ssh',
  })
  if res.code ~= 0 or not res.stdout:find('SSHDEV:PREPARED=1', 1, true) then
    local kv = Util.parse_keyvals(res.stdout)
    if kv.ERROR == 'bin-link' then
      return nil, ('nvim profile %s has no usable nvim binary (%s/nvim-bin); '
        .. 'run :SSHdevProfiles %s to see the usable profiles'):format(
        layout.nvim_profile_key,
        layout.nvim_profile,
        parsed.dest
      )
    end
    if kv.ERROR == 'bad-profile-path' or kv.ERROR == 'bad-workspace-path' then
      return nil, ('refusing to prepare an unexpected profile path '
        .. '(nvim profile %s, workspace profile %s): %s'):format(
        layout.nvim_profile,
        layout.workspace_profile,
        kv.ERROR
      )
    end
    return nil, ('preparing %s failed (exit %s):\n%s'):format(
      layout.workspace_profile,
      res.code,
      Util.tail(res.stderr .. res.stdout, 10)
    )
  end
  return true
end

---Upload the remote session helper into the workspace profile.
---@param cfg table
---@param parsed table
---@param layout table
---@return boolean? ok
---@return string? err
function M.upload_helper(cfg, parsed, layout)
  local root = Util.plugin_root()
  if not root then
    return nil, 'cannot locate the sshdev.nvim plugin directory'
  end
  local res = Ssh.upload_file(
    cfg,
    parsed,
    Util.fs_join(root, 'scripts'),
    'remote_session.lua',
    layout.helper_file,
    cfg.timeouts.ssh
  )
  if res.code ~= 0 then
    return nil, ('uploading the remote session helper failed (exit %s):\n%s'):format(
      res.code,
      Util.tail(res.stderr, 10)
    )
  end
  return true
end

---scp the staged local config into the nvim profile's staging directory.
---@param cfg table
---@param parsed table
---@param layout table
---@return boolean? ok
---@return string? err
function M.upload_config(cfg, parsed, layout)
  local parent, derr = Util.stage_config(cfg)
  if not parent then
    return nil, ('staging your config failed: %s'):format(tostring(derr))
  end
  local up = Ssh.upload_dir(
    cfg,
    parsed,
    parent,
    'nvim-config',
    layout.staging_dir,
    cfg.timeouts.ssh
  )
  -- always drop the per-connection local stage dir
  Util.rmrf(parent)
  if up.code ~= 0 then
    return nil, ('scp of your config failed (exit %s):\n%s'):format(up.code, Util.tail(up.stderr, 10))
  end
  return true
end

---Swap the uploaded config in and install the plugins (once per profile).
---@param cfg table
---@param parsed table
---@param layout table
---@param opts table|nil { force = boolean }
---@return table? result { installed, reused }
---@return string? err
function M.commit_profile(cfg, parsed, layout, opts)
  opts = opts or {}
  local extra = ''
  for _, c in ipairs(cfg.install_commands or {}) do
    extra = extra .. ' -c ' .. Util.shquote(c)
  end
  local script = Util.render(Scripts.commit, {
    ROOT = Util.shsafe(layout.root, 'remote root'),
    NP = Util.shsafe(layout.nvim_profile, 'nvim profile dir'),
    STAGING = Util.shsafe(layout.staging_dir, 'staging dir'),
    BIN = Util.shsafe(Layout.bin_path(layout), 'remote nvim binary'),
    HASH = Util.shsafe(layout.config_hash, 'config content hash'),
    LOCK_WAIT = tostring(math.max(1, math.floor(cfg.timeouts.lock))),
    FORCE = opts.force and '1' or '0',
    INSTALL_CMDS = extra,
  })
  local res = Ssh.run_script(cfg, parsed, script, {
    timeout = cfg.timeouts.install + cfg.timeouts.lock + 60,
    label = 'install',
  })
  if res.stdout ~= '' then
    Util.log('[install] %s', res.stdout)
  end
  local kv = Util.parse_keyvals(res.stdout)

  if kv.ERROR == 'locked' then
    return nil, ('another sshdev client is still bootstrapping the nvim profile %s; '
      .. 'retry in a moment'):format(layout.nvim_profile_key)
  end
  if kv.ERROR == 'no-config' then
    return nil, ('the uploaded config for nvim profile %s is missing; '
      .. 'run :SSHdevConnect! to retry the upload'):format(layout.nvim_profile_key)
  end
  if kv.ERROR == 'install' or res.code ~= 0 then
    return nil, ('installing plugins into nvim profile %s failed (exit %s) — see :SSHdevLog'):format(
      layout.nvim_profile_key,
      res.code
    )
  end
  if kv.NP == 'installed' then
    return { installed = true, reused = false }
  end
  if kv.NP == 'ready' then
    return { installed = false, reused = true }
  end
  return nil, 'unexpected response from the remote profile install script:\n'
    .. Util.tail(res.stdout, 15)
end

---Start the detached remote server. Returns (server, err).
---@param cfg table
---@param parsed table
---@param layout table
---@param rport integer
---@param restore boolean|nil restore session.vim on start
---@return table? server { running, addr, pid, fresh }
---@return string? err
function M.start_server(cfg, parsed, layout, rport, restore)
  local session_file = layout.session_file
  local script = Util.render(Scripts.start, {
    WS_PROFILE = Util.shsafe(layout.workspace_profile, 'workspace profile dir'),
    NP = Util.shsafe(layout.nvim_profile, 'nvim profile dir'),
    WORKSPACE = Util.shsafe(layout.workspace, 'workspace'),
    BIN = Util.shsafe(Layout.bin_path(layout), 'remote nvim binary'),
    RPORT = tostring(rport),
    FIND_RUNNING = Scripts.find_running,
    SESSION = Util.shsafe(cfg.session and session_file or '', 'session file'),
    RESTORE = (cfg.session and restore ~= false) and '1' or '0',
    HELPER = Util.shsafe(layout.helper_file, 'session helper'),
  })
  local res = Ssh.run_script(cfg, parsed, script, {
    timeout = cfg.timeouts.ssh,
    label = 'ssh',
  })
  if res.code ~= 0 then
    return nil, ('starting the remote server failed (exit %s):\n%s'):format(
      res.code,
      Util.tail(res.stdout .. res.stderr, 15)
    )
  end
  local kv = Util.parse_keyvals(res.stdout)
  if kv.SERVER == 'running' then
    return { running = true, addr = kv.ADDR, pid = kv.PID, fresh = false }
  end
  if kv.SERVER == 'started' then
    return { running = true, addr = kv.ADDR, pid = kv.PID, fresh = true }
  end
  if kv.SERVER == 'dead' then
    return nil, 'the remote nvim server died immediately after start:\n' .. Util.tail(res.stdout, 15)
  end
  return nil, 'unexpected response from the remote start script:\n' .. Util.tail(res.stdout, 15)
end

---Server status for a workspace profile:
---ctx may be a full layout or any table with workspace_profile/nvim_profile.
---@param cfg table
---@param parsed table
---@param ctx table { workspace_profile, nvim_profile }
---@return table? status { running, pid, addr, has_session, np_exists, np_ready }
---@return string? err
function M.server_status(cfg, parsed, ctx)
  local script = Util.render(Scripts.status, {
    WS_PROFILE = Util.shsafe(ctx.workspace_profile, 'workspace profile dir'),
    NP = Util.shsafe(ctx.nvim_profile, 'nvim profile dir'),
    FIND_RUNNING = Scripts.find_running,
  })
  local res = Ssh.run_script(cfg, parsed, script, { timeout = cfg.timeouts.ssh, label = 'ssh' })
  if res.code ~= 0 then
    return nil, ('checking the remote server failed (exit %s)'):format(res.code)
  end
  local kv = Util.parse_keyvals(res.stdout)
  return {
    running = kv.SERVER == 'running',
    pid = kv.PID,
    addr = kv.ADDR,
    has_session = kv.SESSION == 'yes',
    np_exists = kv.NP_EXISTS == 'yes',
    np_ready = kv.NP_READY_HASH or '',
  }
end

---Stop the server (SIGTERM first so nvim can save session.vim).
---@param cfg table
---@param parsed table
---@param ctx table { workspace_profile }
---@return boolean? ok
---@return string? err
function M.stop_server(cfg, parsed, ctx)
  local script = Util.render(Scripts.stop, {
    WS_PROFILE = Util.shsafe(ctx.workspace_profile, 'workspace profile dir'),
    FIND_RUNNING = Scripts.find_running,
  })
  local res = Ssh.run_script(cfg, parsed, script, { timeout = cfg.timeouts.ssh, label = 'ssh' })
  if res.code ~= 0 then
    return nil, ('stopping the remote server failed (exit %s)'):format(res.code)
  end
  return true
end

---List the workspace profiles owned by the current client host.
---@param cfg table
---@param parsed table
---@param root string absolute remote root
---@return table[]? entries
---@return string? err
function M.list_workspace_profiles(cfg, parsed, root)
  local script = Util.render(Scripts.list_workspace, {
    ROOT = Util.shsafe(root, 'remote root'),
    HOST = Util.shsafe(Util.os_hostname(), 'local hostname'),
  })
  local res = Ssh.run_script(cfg, parsed, script, { timeout = cfg.timeouts.ssh, label = 'ssh' })
  if res.code ~= 0 then
    return nil, ('listing remote workspace profiles failed (exit %s):\n%s'):format(
      res.code,
      Util.tail(res.stderr, 8)
    )
  end
  return Scripts.parse_workspace_list(res.stdout)
end

---List the nvim profiles owned by the current client host.
---@param cfg table
---@param parsed table
---@param root string absolute remote root
---@return table[]? entries
---@return string? err
function M.list_nvim_profiles(cfg, parsed, root)
  local script = Util.render(Scripts.list_nvim, {
    ROOT = Util.shsafe(root, 'remote root'),
    HOST = Util.shsafe(Util.os_hostname(), 'local hostname'),
  })
  local res = Ssh.run_script(cfg, parsed, script, { timeout = cfg.timeouts.ssh, label = 'ssh' })
  if res.code ~= 0 then
    return nil, ('listing remote nvim profiles failed (exit %s):\n%s'):format(
      res.code,
      Util.tail(res.stderr, 8)
    )
  end
  return Scripts.parse_nvim_list(res.stdout)
end

return M
