--- Remote directory layout for sshdev.nvim.
---
---   <remote_root>/
---   ├── nvim-bins/<nvim-version>/
---   ├── nvim-profiles/--<host>-<version>-<hash8>--/
---   │   ├── nvim-bin -> ../../nvim-bins/<version>
---   │   ├── nvim-config/  xdg/share/  xdg/state/  xdg/cache/
---   │   └── ...
---   └── workspace-profiles/--<host>--<workspace-path>--/
---       ├── nvim-profile -> ../../nvim-profiles/<key>
---       ├── session.lua  session.vim  forward.txt  server.pid ...
---       └── ...
---
--- This module is PURE: it derives the full layout from a remote $HOME, the
--- local hostname, the resolved nvim version and the local config content
--- hash. The remote scripts only execute paths computed here, which keeps a
--- single source of truth for the layout and makes it unit-testable.

local Keys = require('sshdev.keys')
local Util = require('sshdev.util')

local M = {}

---Generate a short path-safe token for a staging directory.
---@return string
function M.staging_token()
  return Util.staging_token()
end

---Normalize a remote workspace path.
---@param workspace string|nil raw path ("~/proj", "/srv/app")
---@param home string remote $HOME
---@return string? abs
---@return string? err
function M.normalize_workspace(workspace, home)
  local ws = workspace
  if ws == nil or ws == '' then
    ws = home
  end
  if type(ws) ~= 'string' then
    return nil, 'the workspace must be a remote path string'
  end
  ws = Util.expand_remote_home(ws, home)
  if ws:sub(1, 1) ~= '/' then
    return nil, ('workspace %q must be an absolute remote path or "~/..."'):format(ws)
  end
  if ws:find("['\r\n\t]") then
    return nil, 'the workspace path must not contain quotes, tabs or newlines'
  end
  ws = ws:gsub('/+$', '')
  if ws == '' then
    ws = '/'
  end
  return ws
end

---Build the complete remote layout.
---@param opts table {
---   home: string remote $HOME,
---   remote_root: string|nil, hostname: string|nil,
---   nvim_version: string, config_hash: string,
---   workspace: string|nil, workspace_profile_name: string|nil,
---   nvim_profile_key: string|nil ("auto" or explicit key),
---   token: string|nil staging token (tests),
--- }
---@return table? layout
---@return string? err
function M.build(opts)
  opts = opts or {}
  local home = opts.home
  if type(home) ~= 'string' or home == '' then
    return nil, 'the remote $HOME is unknown; cannot build the sshdev layout'
  end

  local hostname = Util.sanitize_segment(opts.hostname or Util.os_hostname(), 32)
  local version = opts.nvim_version
  if not Keys.is_valid_version(version) then
    return nil, ('invalid nvim version %q: use letters, digits, ".", "_" and "-"'):format(
      tostring(version)
    )
  end

  local config_hash = tostring(opts.config_hash or '')
  local hash8 = Keys.config_hash8(config_hash)
  if not hash8 then
    return nil, 'the local config content hash is missing or too short'
  end

  local explicit = not Keys.is_auto(opts.nvim_profile_key)
  local np_key
  if explicit then
    local ok, err = Keys.validate_nvim_profile_key(opts.nvim_profile_key)
    if not ok then
      return nil, err
    end
    np_key = opts.nvim_profile_key
  else
    np_key = Keys.nvim_profile_key(hostname, version, hash8)
  end

  local workspace, werr = M.normalize_workspace(opts.workspace, home)
  if not workspace then
    return nil, werr
  end

  local ws_key
  local ws_name
  if opts.workspace_profile_name and opts.workspace_profile_name ~= '' then
    ws_name = opts.workspace_profile_name
    ws_key = Util.sanitize_segment(ws_name, 100)
  else
    ws_key = Keys.workspace_profile_key(hostname, workspace)
  end

  local root = Util.remote_root_abs({ remote_root = opts.remote_root }, home)
  local bin_root = Util.join_remote(root, 'nvim-bins')
  local bin_dir = Util.join_remote(bin_root, version)
  local np_root = Util.join_remote(root, 'nvim-profiles')
  local np = Util.join_remote(np_root, np_key)
  local wsp_root = Util.join_remote(root, 'workspace-profiles')
  local wsp = Util.join_remote(wsp_root, ws_key)

  local token = opts.token
  if type(token) ~= 'string' or token == '' then
    token = M.staging_token()
  end
  token = token:gsub('[^%w]', ''):sub(1, 24)
  if token == '' then
    token = M.staging_token()
  end

  local np_bin_link = Util.join_remote(np, 'nvim-bin')
  local ws_np_link = Util.join_remote(wsp, 'nvim-profile')

  return {
    home = home,
    hostname = hostname,
    root = root,
    nvim_version = version,
    config_hash = config_hash,
    config_hash8 = hash8,
    explicit_nvim_profile = explicit,

    -- nvim bins (shared by all profiles)
    bin_root = bin_root,
    bin_dir = bin_dir,

    -- nvim profile (config + plugin instances + bin link)
    nvim_profiles_root = np_root,
    nvim_profile_key = np_key,
    nvim_profile = np,
    nvim_bin_link = np_bin_link,
    nvim_bin_link_target = '../../nvim-bins/' .. version,
    nvim_config = Util.join_remote(np, 'nvim-config'),
    xdg_share = Util.join_remote(np, 'xdg', 'share'),
    xdg_state = Util.join_remote(np, 'xdg', 'state'),
    xdg_cache = Util.join_remote(np, 'xdg', 'cache'),
    nvim_version_file = Util.join_remote(np, 'nvim-version'),
    config_hash_file = Util.join_remote(np, 'config-hash'),
    client_host_file = Util.join_remote(np, 'client-host'),
    ready_file = Util.join_remote(np, '.ready'),
    staging_dir = Util.join_remote(np, '.staging-' .. token),
    lock_dir = Util.join_remote(np, '.bootstrap.lock'),

    -- workspace profile (session + server runtime + nvim profile link)
    workspace_profiles_root = wsp_root,
    workspace = workspace,
    workspace_profile_name = ws_name,
    workspace_profile_key = ws_key,
    workspace_profile = wsp,
    nvim_profile_link = ws_np_link,
    nvim_profile_link_target = '../../nvim-profiles/' .. np_key,
    workspace_file = Util.join_remote(wsp, 'workspace.txt'),
    nvim_profile_key_file = Util.join_remote(wsp, 'nvim-profile.txt'),
    ws_client_host_file = Util.join_remote(wsp, 'client-host'),
    helper_file = Util.join_remote(wsp, 'session.lua'),
    session_file = Util.join_remote(wsp, 'session.vim'),
    forward_file = Util.join_remote(wsp, 'forward.txt'),
    env_file = Util.join_remote(wsp, 'env.txt'),
    last_used_file = Util.join_remote(wsp, 'last_used'),
    server_pid = Util.join_remote(wsp, 'server.pid'),
    server_addr = Util.join_remote(wsp, 'server.addr'),
    server_log = Util.join_remote(wsp, 'server.log'),
  }
end

---Path of the versioned nvim executable, through the profile's bin link.
---@param layout table
---@return string
function M.bin_path(layout)
  return Util.join_remote(layout.nvim_bin_link, 'bin', 'nvim')
end

---The auto (content derived) nvim profile for a layout.
---@param layout table
---@return string key
function M.auto_nvim_profile_key(layout)
  return Keys.nvim_profile_key(layout.hostname, layout.nvim_version, layout.config_hash8)
end

return M
