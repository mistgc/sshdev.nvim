--- Connection history for sshdev.nvim.
---
--- Stored in stdpath("data")/sshdev/history.json, newest first:
---   { dest, workspace, profile_key, last_used, count, label? }
---
--- It powers the :SSHdevConnect picker (telescope when available) so that
--- reconnecting to a previous workspace does not require retyping anything.

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

local function entry_key(e)
  return tostring(e.dest) .. '|' .. tostring(e.workspace)
end

---Destination without its port ("user@host:2222" -> "user@host").
---Used to recognize the same remote when only the port changed.
---@param dest string|nil
---@return string
local function dest_base(dest)
  return (tostring(dest or ''):gsub(':%d+$', ''))
end

---Read the history file (never throws).
---@return table[]
function M.list()
  local path = M.path()
  local fd = uv.fs_open(path, 'r', 438)
  if not fd then
    return {}
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  if not data or data == '' then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok or type(decoded) ~= 'table' then
    return {}
  end
  local out = {}
  for _, e in ipairs(decoded) do
    if type(e) == 'table' and e.dest and e.workspace then
      out[#out + 1] = e
    end
  end
  return out
end

---@param entries table[]
local function write(entries)
  local ok, encoded = pcall(vim.json.encode, entries)
  if not ok then
    return false
  end
  local path = M.path()
  Util.mkdir_p(vim.fs.dirname(path))
  local fd = uv.fs_open(path, 'w', 420)
  if not fd then
    return false
  end
  uv.fs_write(fd, encoded, 0)
  uv.fs_close(fd)
  return true
end

---Record a successful connection (upsert, newest first, capped).
---@param cfg table
---@param entry table { dest, workspace, profile_key }
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
      and dest_base(e.dest) == dest_base(entry.dest)
    if same_key then
      found = true
      merged[#merged + 1] = {
        dest = entry.dest, -- always keep the current (full) destination
        workspace = e.workspace,
        profile_key = entry.profile_key or e.profile_key,
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
      profile_key = entry.profile_key,
      last_used = now,
      count = 1,
      label = entry.label,
    })
  else
    -- keep the most recently used entry first
    table.sort(merged, function(a, b)
      return (a.last_used or 0) > (b.last_used or 0)
    end)
  end
  while #merged > limit do
    table.remove(merged)
  end
  write(merged)
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
  write(kept)
end

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
  if #meta > 0 then
    return ('%s  (%s)'):format(table.concat(parts, '  '), table.concat(meta, ', '))
  end
  return table.concat(parts, '  ')
end

return M
