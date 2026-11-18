--- sshdev.nvim shared helpers.
---
--- Pure-ish utilities: shell quoting, remote path building, version parsing,
--- deterministic port selection, glob matching, config staging (tree copy),
--- logging, and template rendering for the remote bootstrap scripts.

local M = {}

---libuv handle (vim.uv in >= 0.10, vim.loop as legacy alias).
local uv = vim.uv or vim.loop

---Local path join: vim.fs.joinpath when available, '/' concat otherwise
---(works for the mixed-separator paths Windows produces).
function M.fs_join(...)
  if vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end
  local parts = {}
  for i = 1, select('#', ...) do
    parts[#parts + 1] = tostring((select(i, ...)))
  end
  return table.concat(parts, '/')
end

local LOG_BUFNAME = 'sshdev://log'
M._log_lines = {}

------------------------------------------------------------------------
-- Paths
------------------------------------------------------------------------

---Join POSIX path segments (remote side is always POSIX).
---Collapses duplicate slashes so "/a/" + "/b//" + "c" -> "/a/b/c".
---@param base string
---@param ... string
---@return string
function M.join_remote(base, ...)
  local b = tostring(base):gsub('/+$', '')
  if b == '' then
    b = '/'
  end
  local parts = { b }
  for i = 1, select('#', ...) do
    local seg = tostring((select(i, ...)))
    seg = seg:gsub('^/+', ''):gsub('/+$', '')
    if seg ~= '' then
      parts[#parts + 1] = seg
    end
  end
  return (table.concat(parts, '/'):gsub('//+', '/'))
end

---Resolve a possibly "~"-relative remote path against the remote $HOME.
---@param path string
---@param home string
---@return string
function M.expand_remote_home(path, home)
  if path == '~' then
    return home
  end
  if path:sub(1, 2) == '~/' then
    return M.join_remote(home, path:sub(3))
  end
  return path
end

------------------------------------------------------------------------
-- Shell quoting
-------------------------------------------------------------------

---POSIX single-quote wrapping (for tokens in scp/ssh arguments and scripts).
---@param s string|number
---@return string
function M.shquote(s)
  return "'" .. tostring(s):gsub("'", [['\'']]) .. "'"
end

---Assert a value can be embedded inside single quotes in a shell script
---(no single quotes / newlines). Throws a user-visible error otherwise.
---@param s any
---@param what string
---@return string
function M.shsafe(s, what)
  s = tostring(s or '')
  if s:find("['\r\n]") then
    error(("sshdev: %s contains characters that cannot be safely used remotely: %s"):format(what or 'value', s), 0)
  end
  return s
end

---Render a script template, replacing {{KEY}} placeholders.
---Uses a function replacement so values may contain '%' safely.
---NOTE: the key pattern must include '_' (placeholders like WS_DIR).
---@param tpl string
---@param vars table
---@return string
function M.render(tpl, vars)
  return (tpl:gsub('{{([%w_]+)}}', function(k)
    local v = vars[k]
    if v == nil then
      return '{{' .. k .. '}}'
    end
    return tostring(v)
  end))
end

---Last non-empty lines of a command output, for error reporting.
---@param s string|nil
---@param n integer|nil  number of lines (default 10)
---@return string
function M.tail(s, n)
  n = n or 10
  local lines = {}
  for line in tostring(s or ''):gmatch('[^\r\n]+') do
    lines[#lines + 1] = line
  end
  local from = math.max(1, #lines - n + 1)
  local out = {}
  for i = from, #lines do
    out[#out + 1] = lines[i]
  end
  if #out == 0 then
    return '(no output)'
  end
  return table.concat(out, '\n')
end

---Parse "SSHDEV:KEY=VALUE" marker lines produced by remote scripts.
---@param text string|nil
---@return table
function M.parse_keyvals(text)
  local t = {}
  if not text then
    return t
  end
  for line in text:gmatch('[^\r\n]+') do
    local k, v = line:match('^SSHDEV:([%w_]+)=(.*)$')
    if k then
      t[k] = v
    end
  end
  return t
end

------------------------------------------------------------------------
-- Destination parsing: [user@]host[:port][:path]
------------------------------------------------------------------------

---Parse an ssh destination, optionally carrying a port and/or remote path.
---
---Accepted forms:
---  host
---  user@host
---  host:22
---  user@host:22
---  host:~/proj          (path via colon, scp-like)
---  user@host:22:~/proj  (port, then path)
---
---IPv6 literals are not supported (documented limitation).
---@param arg string
---@return table? parsed  { user, host, port, path, dest }
---@return string? err
function M.parse_dest(arg)
  if type(arg) ~= 'string' or arg == '' then
    return nil, 'empty destination'
  end
  local user, rest = arg:match('^([^@]+)@(.+)$')
  if not user then
    rest = arg
  elseif rest:find('@') then
    return nil, ('invalid destination (more than one "@"): %s'):format(arg)
  end

  local host, port, path
  local colon = rest:find(':')
  if colon then
    host = rest:sub(1, colon - 1)
    local tail = rest:sub(colon + 1)
    local c2 = tail:find(':')
    local first = c2 and tail:sub(1, c2 - 1) or tail
    if first:match('^%d+$') then
      port = tonumber(first)
      path = c2 and tail:sub(c2 + 1) or nil
    else
      path = tail
    end
  else
    host = rest
  end

  if host == '' or host:find(':') then
    return nil, ('invalid host in destination (IPv6 literals are not supported): %s'):format(arg)
  end

  return {
    user = user,
    host = host,
    port = port,
    path = path,
    dest = (user and user .. '@' or '') .. host,
  }
end

------------------------------------------------------------------------
-- Workspace names / ports
------------------------------------------------------------------------

---Sanitize a workspace name: [A-Za-z0-9._-], max 48 chars, no "." / "..".
---@param name any
---@return string
function M.sanitize_ws(name)
  if type(name) ~= 'string' then
    return 'default'
  end
  local s = name:gsub('[^%w%.%-_]+', '-'):gsub('^[-%.]+', ''):gsub('[-%.]+$', '')
  if s == '' or s == '.' or s == '..' then
    return 'default'
  end
  if #s > 48 then
    s = s:sub(1, 48)
  end
  return s
end

local function djb2(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 2147483648
  end
  return h
end

---Deterministic local tunnel port in [20000, 39999].
function M.local_port(dest, ws)
  return 20000 + djb2('L:' .. dest .. '/' .. ws) % 20000
end

---Deterministic remote listen port in [20000, 39999].
function M.remote_port(dest, ws)
  return 20000 + djb2('R:' .. dest .. '/' .. ws) % 20000
end

------------------------------------------------------------------------
-- Glob matching for upload excludes
------------------------------------------------------------------------

---Translate a shell-like glob into a Lua pattern anchored at both ends.
---`*` -> ".*", `?` -> ".", everything else is escaped.
---@param g string
---@return string
function M.glob_to_pattern(g)
  local p = {}
  for c in g:gmatch('.') do
    if c == '*' then
      p[#p + 1] = '.*'
    elseif c == '?' then
      p[#p + 1] = '.'
    elseif c:find('[%^%$%(%)%.%%%+%-%*%?%[%]%|\\]') then
      p[#p + 1] = '%' .. c
    else
      p[#p + 1] = c
    end
  end
  return '^' .. table.concat(p) .. '$'
end

---True when `rel` (path relative to the config root) is excluded by any
---glob: a glob matches either a single path component or a path prefix
---(so "lua/private*" excludes the whole subtree).
---@param rel string
---@param globs string[]
---@return boolean
function M.excluded(rel, globs)
  local components = vim.split(rel, '/')
  for i = 1, #components do
    local prefix = table.concat(components, '/', 1, i)
    for _, g in ipairs(globs) do
      local pat = M.glob_to_pattern(g)
      if prefix:match(pat) then
        return true
      end
    end
  end
  return false
end

------------------------------------------------------------------------
-- Versions
-------------------------------------------------------------------

---Local nvim version object (vim.version()).
---@return table
function M.nvim_version()
  return vim.version()
end

---Release tag for the local nvim ("v0.11.3"), plus whether this is a
---dev/nightly build.
---@return string tag
---@return boolean is_dev
function M.nvim_version_tag()
  local v = vim.version()
  local tag = ('v%d.%d.%d'):format(v.major, v.minor, v.patch)
  local dev = (v.prerelease and v.prerelease ~= '' and true)
    or (v.build and v.build ~= '' and true)
    or false
  return tag, dev
end

---First line of `nvim -v` output ("NVIM v0.11.3 ...") -> {major, minor, patch}.
---@param line string?
---@return table?
function M.parse_nvim_version(line)
  if type(line) ~= 'string' then
    return nil
  end
  local maj, min, pat = line:match('^NVIM v(%d+)%.(%d+)%.(%d+)')
  if not maj then
    return nil
  end
  return { major = tonumber(maj), minor = tonumber(min), patch = tonumber(pat) }
end

---True when local nvim >= major.minor.
---@param major integer
---@param minor integer
---@return boolean
function M.nvim_at_least(major, minor)
  local v = vim.version()
  return v.major > major or (v.major == major and v.minor >= minor)
end

------------------------------------------------------------------------
-- Logging / notifications
-------------------------------------------------------------------

local function find_log_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == LOG_BUFNAME then
      return b
    end
  end
  return nil
end

local function log_buf()
  local b = find_log_buf()
  if b then
    return b
  end
  b = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, b, LOG_BUFNAME)
  pcall(vim.api.nvim_buf_set_option, b, 'buflisted', false)
  pcall(vim.api.nvim_buf_set_option, b, 'bufhidden', 'hide')
  pcall(vim.api.nvim_buf_set_option, b, 'modifiable', false)
  return b
end

---Append a line to the sshdev log buffer (and mirror into memory).
---Accepts format-string arguments.
function M.log(msg, ...)
  if select('#', ...) > 0 then
    msg = msg:format(...)
  end
  local line = ('[%s] %s'):format(os.date('%H:%M:%S'), msg)
  M._log_lines[#M._log_lines + 1] = line
  if #M._log_lines > 1000 then
    table.remove(M._log_lines, 1)
  end
  local b = find_log_buf()
  if b then
    pcall(vim.api.nvim_buf_set_option, b, 'modifiable', true)
    vim.api.nvim_buf_set_lines(b, -1, -1, false, { line })
    pcall(vim.api.nvim_buf_set_option, b, 'modifiable', false)
  end
  return line
end

---Open (or focus) the log window.
function M.open_log()
  local b = log_buf()
  pcall(vim.api.nvim_buf_set_option, b, 'modifiable', true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, M._log_lines)
  pcall(vim.api.nvim_buf_set_option, b, 'modifiable', false)
  vim.api.nvim_win_set_buf(0, b)
  vim.api.nvim_set_option_value('wrap', false, {})
  vim.cmd('normal! G')
end

---User-facing notification with the [sshdev] prefix.
function M.notify(msg, level)
  vim.notify('[sshdev] ' .. msg, level or vim.log.levels.INFO)
end

---Report an error from async context: log + notify.
function M.report_error(err)
  local msg = tostring(err)
  M.log('error: %s', msg)
  vim.schedule(function()
    vim.notify('[sshdev] ' .. msg, vim.log.levels.ERROR)
  end)
end

------------------------------------------------------------------------
-- Local filesystem helpers (libuv, synchronous)
-------------------------------------------------------------------

---Recursively create a directory (mkdir -p).
---@param path string
---@return boolean ok
---@return string? err
function M.mkdir_p(path)
  path = vim.fs.normalize(path)
  if uv.fs_stat(path) then
    return true
  end
  local parent = vim.fs.dirname(path)
  if parent and parent ~= path and not uv.fs_stat(parent) then
    M.mkdir_p(parent)
  end
  local ok, err = uv.fs_mkdir(path, 493)
  return ok == true, err
end

---Recursively delete a path (rm -rf).
---@param path string
---@return boolean
function M.rmrf(path)
  local st = uv.fs_lstat(path)
  if not st then
    return true
  end
  if st.type ~= 'directory' then
    return uv.fs_unlink(path) == true
  end
  local dir = uv.fs_scandir(path)
  if not dir then
    return false
  end
  while true do
    local name = uv.fs_scandir_next(dir)
    if not name then
      break
    end
    M.rmrf(M.fs_join(path, name))
  end
  return uv.fs_unlink(path) == true
end

local function copy_file(src, dst)
  local fd, err = uv.fs_open(src, 'r', 438)
  if not fd then
    return nil, err
  end
  local stat, serr = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, serr
  end
  local data, rerr = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data then
    return nil, rerr
  end
  local wfd, werr = uv.fs_open(dst, 'w', 420)
  if not wfd then
    return nil, werr
  end
  uv.fs_write(wfd, data, 0)
  uv.fs_close(wfd)
  return true
end

---Recursively copy a tree, following symlinks, skipping entries for which
---`matcher(rel_path)` returns true. `rel` is the relative path so far.
---@param src string
---@param dst string
---@param matcher function|nil
---@param rel string|nil
---@return boolean ok
---@return string? err
function M.copy_tree(src, dst, matcher, rel)
  M.mkdir_p(dst)
  local dir = uv.fs_scandir(src)
  if not dir then
    return nil, 'cannot open ' .. src
  end
  while true do
    local name, typ = uv.fs_scandir_next(dir)
    if not name then
      break
    end
    local child_rel = (rel and rel .. '/' or '') .. name
    if not matcher or not matcher(child_rel) then
      local s = M.fs_join(src, name)
      local t = M.fs_join(dst, name)
      local real_typ = typ
      if typ == 'link' then
        local st = uv.fs_stat(s)
        real_typ = st and st.type or nil
      end
      if real_typ == 'directory' then
        local ok, err = M.copy_tree(s, t, matcher, child_rel)
        if not ok then
          return nil, err
        end
      elseif real_typ == 'file' then
        local ok, err = copy_file(s, t)
        if not ok then
          return nil, err
        end
      end
    end
  end
  return true
end

---Locate the plugin root (the directory containing lua/, scripts/, doc/).
function M.plugin_root()
  local files = vim.api.nvim_get_runtime_file('lua/sshdev/util.lua', false)
  local p = (files and files[1]) and files[1]
  if not p then
    local src = debug.getinfo(1, 'S').source
    if src:sub(1, 1) == '@' then
      p = src:sub(2)
    end
  end
  if not p then
    return nil
  end
  p = vim.fs.normalize(p)
  local root = p:gsub('[\\/]+lua[\\/]sshdev[\\/]util%.lua$', '')
  if root == p or root == '' then
    return nil
  end
  return root
end

---Stage the local nvim config into
---stdpath("cache")/sshdev/stage-<ws>/nvim-config (wiping the previous stage).
---Returns parent dir and dir name so scp can run with a relative source
---(avoids the Windows "C:" drive-letter ambiguity in scp arguments).
---@param cfg table
---@param ws string
---@return string? parent
---@return string? dirname_or_err
function M.stage_config(cfg, ws)
  local src = vim.fs.normalize(vim.fn.stdpath('config'))
  local parent = M.fs_join(vim.fs.normalize(vim.fn.stdpath('cache')), 'sshdev', 'stage-' .. ws)
  local dst = M.fs_join(parent, 'nvim-config')
  M.rmrf(parent)
  local globs = cfg.excludes or {}
  local matcher = function(rel)
    return M.excluded(rel, globs)
  end
  local ok, err = M.copy_tree(src, dst, matcher, nil)
  if not ok then
    return nil, err
  end
  return parent, 'nvim-config'
end

---Absolute remote root path (~-expanded) for a configuration.
---@param cfg table
---@param home string
---@return string
function M.remote_root_abs(cfg, home)
  local r = cfg.remote_root or '~/.sshdev.nvim'
  return M.expand_remote_home(r, home)
end

return M
