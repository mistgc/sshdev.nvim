--- Profile keys for sshdev.nvim.
---
--- Two different, deliberately OPAQUE keys:
---
---   nvim profile       --<local-hostname>--<nvim-version>--<hash8-config-content>--
---   workspace profile  --<local-hostname>--<workspace-path>--
---
--- Keys are directory names below <remote_root>/nvim-profiles and
--- <remote_root>/workspace-profiles. They are identities, not data: the
--- remote side always reads the metadata files inside a profile
--- (nvim-version, client-host, workspace.txt, nvim-profile.txt) instead of
--- trying to parse a key, because hostnames and versions may contain "-".
---
--- Pure functions only (no I/O), so they are trivially testable.

local Util = require('sshdev.util')

local M = {}

---A path-safe nvim version / release tag:
---  v0.12.6, v0.11.3, nightly, stable
---Rejects the usual path traversal traps plus quotes/newlines.
---@param version any
---@return boolean
function M.is_valid_version(version)
  if type(version) ~= 'string' or version == '' or #version > 64 then
    return false
  end
  if version == '.' or version == '..' or version:find('%.%.') then
    return false
  end
  if version:find('[/\\\'"\r\n\t]') then
    return false
  end
  return version:match('^[%w_][%w._%-]*$') ~= nil
end

---First 8 hex characters of a config content hash (lowercase).
---@param hash string|nil
---@return string? hash8
function M.hash8(hash)
  return Util.hash8(hash)
end

---`<hash8-config-content>` part of an nvim profile key.
---@param config_hash string full content hash
---@return string? hash8
function M.config_hash8(config_hash)
  if type(config_hash) ~= 'string' or config_hash == '' then
    return nil
  end
  return Util.hash8(config_hash)
end

---Nvim profile key: "--<local-hostname>--<nvim-version>--<hash8-config-content>--".
---@param local_hostname string
---@param nvim_version string e.g. "v0.12.6"
---@param hash8 string at least 8 hex chars (only the first 8 are used)
---@return string key
function M.nvim_profile_key(local_hostname, nvim_version, hash8)
  local host = Util.sanitize_segment(local_hostname or 'localhost', 32)
  local version = Util.sanitize_segment(nvim_version or 'unknown', 40)
  local short = Util.hash8(hash8)
  if not short then
    error('sshdev: nvim profile key needs at least 8 hex characters of config hash', 0)
  end
  return '--' .. host .. '--' .. version .. '--' .. short .. '--'
end

---Workspace profile key: "--<local-hostname>--<workspace-path>--".
---@param local_hostname string
---@param workspace_abs string absolute remote workspace path
---@return string key
function M.workspace_profile_key(local_hostname, workspace_abs)
  return Util.workspace_profile_key(local_hostname, workspace_abs)
end

---Validate a USER-SUPPLIED nvim profile key (e.g. --nvim-profile=...).
---Only shape and path safety: existence is decided on the remote side.
---@param key any
---@return boolean ok
---@return string? err
function M.validate_nvim_profile_key(key)
  if type(key) ~= 'string' or key == '' then
    return false, 'an nvim profile key must be a non-empty string like "--<host>--<version>--<hash8>--"'
  end
  if #key > 200 then
    return false, 'the nvim profile key is too long'
  end
  if key:find('[/\\\'"\r\n\t]') then
    return false, 'the nvim profile key must not contain slashes, quotes, tabs or newlines'
  end
  if key:sub(1, 2) ~= '--' or key:sub(-2) ~= '--' or #key <= 4 then
    return false, ('the nvim profile key must be wrapped in "--...--": %s'):format(key)
  end
  local inner = key:sub(3, -3)
  if inner:find('^%.') or inner:find('%.%.') then
    return false, 'the nvim profile key must not contain "." or ".." path segments'
  end
  if inner:match('^[%w._%-]+$') == nil then
    return false, ('the nvim profile key may only use letters, digits, ".", "_" and "-": %s'):format(key)
  end
  return true, nil
end

---Is this a valid user-supplied key or the "auto" sentinel?
---@param value any
---@return boolean
function M.is_auto(value)
  return value == nil or value == '' or value == 'auto'
end

return M
