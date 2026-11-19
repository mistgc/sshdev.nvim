--- Connection history + nvim-profile cache for sshdev.nvim.
---
--- Stored in stdpath("data")/sshdev/history.json, newest first:
---   { dest, workspace, workspace_profile_key, nvim_profile_key,
---     last_used, count, label? }
---
--- v1 files only had `profile_key`; it is still read as the workspace profile
--- key so an upgrade keeps the remembered workspaces.
---
--- The history powers the pickers. The *remote* workspace-profile scan is
--- authoritative for "which workspaces exist for this client host"; the local
--- file adds recency/counts and keeps entries usable when the remote profile
--- directory was removed.
---
--- A tiny cache of nvim profile keys per destination feeds tab completion for
--- `--nvim-profile=...` without spawning ssh from a completion function.

local Util = require('sshdev.util')

local M = {}

local uv = vim.uv or vim.loop

local function data_dir()
  return Util.fs_join(vim.fs.normalize(vim.fn.stdpath('data')), 'sshdev')
end

---@return string
function M.path()
  return Util.fs_join(data_dir(), 'history.json')
end

---Override point for tests.
M._cache_path = nil

---@return string
function M.cache_path()
  return M._cache_path or Util.fs_join(data_dir(), 'profile-cache.json')
end

---Destination without its port ("user@host:2222" -> "user@host").
---Used to recognize the same remote when only the port changed.
---@param dest string|nil
---@return string
function M.dest_base(dest)
  return (tostring(dest or ''):gsub(':%d+$', ''))
end

local function read_json(path)
  local fd = uv.fs_open(path, 'r', 438)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  if not data or data == '' then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok then
    return nil
  end
  return decoded
end

local function write_json(path, value)
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    return false
  end
  Util.mkdir_p(vim.fs.dirname(path))
  local fd = uv.fs_open(path, 'w', 420)
  if not fd then
    return false
  end
  uv.fs_write(fd, encoded, 0)
  uv.fs_close(fd)
  return true
end

---Normalize one stored entry to the current schema (never throws).
---@param e any
---@return table?
local function normalize_entry(e)
  if type(e) ~= 'table' or type(e.dest) ~= 'string' or type(e.workspace) ~= 'string' then
    return nil
  end
  return {
    dest = e.dest,
    workspace = e.workspace,
    workspace_profile_key = e.workspace_profile_key or e.profile_key,
    nvim_profile_key = e.nvim_profile_key,
    last_used = tonumber(e.last_used),
    count = tonumber(e.count) or 1,
    label = e.label,
  }
end

---Read the history file (never throws).
---@return table[]
function M.list()
  local decoded = read_json(M.path())
  if type(decoded) ~= 'table' then
    return {}
  end
  local out = {}
  for _, e in ipairs(decoded) do
    local entry = normalize_entry(e)
    if entry then
      out[#out + 1] = entry
    end
  end
  return out
end

local function entry_key(e)
  return tostring(e.dest) .. '|' .. tostring(e.workspace)
end

---Record a successful connection (upsert, newest first, capped).
---@param cfg table
---@param entry table { dest, workspace, workspace_profile_key?, nvim_profile_key? }
function M.record(cfg, entry)
  if cfg and cfg.history == false then
    return
  end
  local limit = (cfg and cfg.history_limit) or 50
  local entries = M.list()
  local key = entry_key(entry)
  -- os.time() has 1s resolution; bump past the newest entry so the entry we
  -- just used always sorts first (and ordering stays deterministic).
  local now = os.time()
  for _, e in ipairs(entries) do
    if (e.last_used or 0) >= now then
      now = (e.last_used or 0) + 1
    end
  end
  local merged = {}
  local found = false
  for _, e in ipairs(entries) do
    local same_key = entry_key(e) == key
    -- treat "host" and "host:2222" for the same workspace as the same
    -- remote: keeps a single entry when the user adds/changes the port
    local same_remote = (not same_key)
      and e.workspace == entry.workspace
      and M.dest_base(e.dest) == M.dest_base(entry.dest)
    if same_key then
      found = true
      merged[#merged + 1] = {
        dest = entry.dest, -- always keep the current (full) destination
        workspace = e.workspace,
        workspace_profile_key = entry.workspace_profile_key or e.workspace_profile_key,
        nvim_profile_key = entry.nvim_profile_key or e.nvim_profile_key,
        last_used = now,
        count = (e.count or 1) + 1,
        label = e.label or entry.label,
      }
    elseif not same_remote then
      merged[#merged + 1] = e
    end
  end
  if not found then
    table.insert(merged, 1, {
      dest = entry.dest,
      workspace = entry.workspace,
      workspace_profile_key = entry.workspace_profile_key,
      nvim_profile_key = entry.nvim_profile_key,
      last_used = now,
      count = 1,
      label = entry.label,
    })
  else
    table.sort(merged, function(a, b)
      return (a.last_used or 0) > (b.last_used or 0)
    end)
  end
  while #merged > limit do
    table.remove(merged)
  end
  write_json(M.path(), merged)
  if entry.nvim_profile_key then
    M.cache_nvim_profiles(entry.dest, { entry.nvim_profile_key })
  end
end

---Forget one entry.
---@param entry table
function M.remove(entry)
  local key = entry_key(entry)
  local kept = {}
  for _, e in ipairs(M.list()) do
    if entry_key(e) ~= key then
      kept[#kept + 1] = e
    end
  end
  write_json(M.path(), kept)
end

---Local history entries for one destination (port-insensitive).
---@param dest string|nil
---@return table[]
function M.list_for(dest)
  if not dest or dest == '' then
    return M.list()
  end
  local base = M.dest_base(dest)
  local out = {}
  for _, e in ipairs(M.list()) do
    if M.dest_base(e.dest) == base then
      out[#out + 1] = e
    end
  end
  return out
end

-----------------------------------------------------------------------
-- Merge of the remote workspace-profile scan into the local history
-----------------------------------------------------------------------

---Merge remote workspace-profile entries (authoritative) with local history.
---
--- * remote entries are the set of workspaces that exist for this client
---   host on the remote (already host-filtered by the remote script)
--- * local entries add count/label and keep a workspace visible if its remote
---   directory disappeared (`stale = true`)
--- * entries whose recorded workspace profile key clearly belongs to another
---   client host are ignored (defense in depth for user isolation)
---@param local_entries table[]
---@param remote_entries table[] entries from remote_scripts.parse_workspace_list
---@param dest string the destination being picked
---@param hostname string|nil local hostname
---@return table[] merged, newest first
function M.merge_workspaces(local_entries, remote_entries, dest, hostname)
  local prefix = hostname and ('--' .. hostname .. '--') or nil
  local out = {}
  local by_workspace = {}

  for _, r in ipairs(remote_entries or {}) do
    if type(r) == 'table' and type(r.workspace) == 'string' and r.workspace ~= '' then
      local e = {
        dest = dest,
        workspace = r.workspace,
        workspace_profile_key = r.workspace_profile_key or r.key,
        nvim_profile_key = r.nvim_profile_key,
        last_used = tonumber(r.last_used),
        has_session = r.has_session and true or false,
        source = 'remote',
      }
      out[#out + 1] = e
      by_workspace[e.workspace] = e
    end
  end

  for _, l in ipairs(local_entries or {}) do
    if type(l) == 'table' and type(l.workspace) == 'string' then
      local same_dest = M.dest_base(l.dest) == M.dest_base(dest)
      local wpk = l.workspace_profile_key or l.profile_key
      local same_host = (prefix == nil) or (wpk == nil) or wpk:sub(1, #prefix) == prefix
      if same_dest and same_host then
        local e = by_workspace[l.workspace]
        if e then
          e.count = l.count
          e.label = l.label
          if l.nvim_profile_key and not e.nvim_profile_key then
            e.nvim_profile_key = l.nvim_profile_key
          end
          if not e.last_used or (tonumber(l.last_used) or 0) > e.last_used then
            e.last_used = tonumber(l.last_used)
          end
          e.source = 'remote+history'
        else
          out[#out + 1] = {
            dest = l.dest or dest,
            workspace = l.workspace,
            workspace_profile_key = wpk,
            nvim_profile_key = l.nvim_profile_key,
            last_used = tonumber(l.last_used),
            count = l.count,
            label = l.label,
            stale = true,
            source = 'history',
          }
        end
      end
    end
  end

  table.sort(out, function(a, b)
    local la, lb = a.last_used or 0, b.last_used or 0
    if la ~= lb then
      return la > lb
    end
    return tostring(a.workspace) < tostring(b.workspace)
  end)
  return out
end

-----------------------------------------------------------------------
-- Nvim profile key cache (completion only)
-----------------------------------------------------------------------

---Cache nvim profile keys for a destination (used by `--nvim-profile=` completion).
---@param dest string|nil destination
---@param keys string[] profile keys
function M.cache_nvim_profiles(dest, keys)
  if not dest or dest == '' or type(keys) ~= 'table' then
    return
  end
  local cache = read_json(M.cache_path())
  if type(cache) ~= 'table' then
    cache = {}
  end
  local base = M.dest_base(dest)
  local entry = type(cache[base]) == 'table' and cache[base] or { keys = {} }
  local known = {}
  for _, k in ipairs(entry.keys or {}) do
    known[k] = true
  end
  for _, k in ipairs(keys) do
    if type(k) == 'string' and k ~= '' then
      known[k] = true
    end
  end
  local list = vim.tbl_keys(known)
  table.sort(list)
  while #list > 100 do
    table.remove(list)
  end
  cache[base] = { keys = list, updated = os.time() }
  write_json(M.cache_path(), cache)
end

---Cached nvim profile keys for a destination.
---@param dest string|nil
---@return string[]
function M.cached_nvim_profiles(dest)
  local cache = read_json(M.cache_path())
  if type(cache) ~= 'table' then
    return {}
  end
  local base = M.dest_base(dest)
  local entry = type(cache[base]) == 'table' and cache[base] or nil
  local out = {}
  for _, k in ipairs((entry and entry.keys) or {}) do
    if type(k) == 'string' and k ~= '' then
      out[#out + 1] = k
    end
  end
  return out
end

---All known nvim profile keys (history + cache), deduplicated for completion.
---@param dest string|nil
---@return string[]
function M.nvim_profile_keys(dest)
  local known = {}
  for _, e in ipairs(M.list()) do
    if e.nvim_profile_key and (not dest or M.dest_base(e.dest) == M.dest_base(dest)) then
      known[e.nvim_profile_key] = true
    end
  end
  for _, k in ipairs(M.cached_nvim_profiles(dest)) do
    known[k] = true
  end
  local out = vim.tbl_keys(known)
  table.sort(out)
  return out
end

-----------------------------------------------------------------------
-- Display
-----------------------------------------------------------------------

---Human-readable label, e.g. "me@host:2222  ~/src/app".
---@param e table
---@return string
function M.format(e)
  return ('%s  %s'):format(tostring(e.dest), tostring(e.workspace))
end

---Relative "last used" label.
---@param ts integer|nil
---@return string
function M.relative_time(ts)
  if not ts then
    return ''
  end
  local delta = os.time() - ts
  if delta < 60 then
    return 'just now'
  elseif delta < 3600 then
    return ('%dm ago'):format(math.floor(delta / 60))
  elseif delta < 86400 then
    return ('%dh ago'):format(math.floor(delta / 3600))
  end
  return ('%dd ago'):format(math.floor(delta / 86400))
end

---Display string for pickers.
---@param e table
---@return string
function M.display(e)
  local parts = { tostring(e.workspace), tostring(e.dest) }
  local meta = {}
  if e.count and e.count > 1 then
    meta[#meta + 1] = ('%dx'):format(e.count)
  end
  local rel = M.relative_time(e.last_used)
  if rel ~= '' then
    meta[#meta + 1] = rel
  end
  if e.has_session then
    meta[#meta + 1] = 'session'
  end
  if e.stale then
    meta[#meta + 1] = 'missing on remote'
  end
  if #meta > 0 then
    return ('%s  (%s)'):format(table.concat(parts, '  '), table.concat(meta, ', '))
  end
  return table.concat(parts, '  ')
end

return M
