--- sshdev.nvim commands.
--- Handlers lazy-load everything; nothing heavy happens at startup.

if vim.g.loaded_sshdev then
  return
end
vim.g.loaded_sshdev = true

local function report(err)
  require('sshdev.util').report_error(err)
end

---Parse the shared "[dest] [workspace] [--nvim-profile=<key>]" argument shape.
---
---Flags may appear anywhere; at most two positional arguments remain:
---  :SSHdevConnect me@host ~/src/app --nvim-profile=--me-v0.12.6-1a2b3c4d--
---  :SSHdevConnect --nvim-profile --me-v0.12.6-1a2b3c4d-- me@host ~/src/app
---@param o table user command args
---@return table|nil opts
---@return string|nil err
local function parse_args(o)
  local opts = { force = o.bang }
  local positional = {}
  local fargs = o.fargs or {}
  local i = 1
  while i <= #fargs do
    local a = fargs[i]
    local inline = a:match('^%-%-nvim%-profile=(.*)$')
    if inline then
      if inline == '' then
        return nil, '--nvim-profile needs a value like --<host>-<version>-<hash8>--'
      end
      opts.nvim_profile = inline
      i = i + 1
    elseif a == '--nvim-profile' or a == '-p' then
      local n = fargs[i + 1]
      if not n or n == '' then
        return nil, '--nvim-profile needs a value like --<host>-<version>-<hash8>--'
      end
      opts.nvim_profile = n
      i = i + 2
    elseif a:sub(1, 2) == '--' then
      return nil, ('unknown option: %s'):format(a)
    else
      positional[#positional + 1] = a
      i = i + 1
    end
  end
  if #positional > 2 then
    return nil, 'expected at most two positional arguments: [destination] [workspace]'
  end
  opts.dest = positional[1]
  opts.workspace = positional[2]
  return opts
end

---Base destinations usable as the first argument.
---@param cfg table
---@return string[]
local function destination_candidates(cfg)
  local cands, seen = {}, {}
  local function add(value)
    if type(value) ~= 'string' or value == '' then
      return
    end
    local base = value:gsub(':%d+$', '')
    if seen[base] then
      return
    end
    seen[base] = true
    cands[#cands + 1] = value
  end
  for _, name in ipairs(vim.tbl_keys(cfg.remotes or {})) do
    -- a `remotes` key is a valid destination argument as well
    cands[#cands + 1] = name
    add(cfg.remotes[name])
  end
  add(cfg.host)
  for _, e in ipairs(require('sshdev.history').list()) do
    add(e.dest)
  end
  return cands
end

---Workspace candidates for a destination argument.
---@param cfg table
---@param dest_arg string|nil
---@return string[]
local function workspace_candidates(cfg, dest_arg)
  local out, seen = {}, {}
  local function add(value)
    if type(value) ~= 'string' or value == '' or seen[value] then
      return
    end
    seen[value] = true
    out[#out + 1] = value
  end
  add(cfg.workspace)
  if dest_arg then
    local dest = dest_arg
    if cfg.remotes and cfg.remotes[dest_arg] then
      dest = cfg.remotes[dest_arg]
    end
    local base = dest:gsub(':%d+$', '')
    for _, e in ipairs(require('sshdev.history').list()) do
      if (e.dest or ''):gsub(':%d+$', '') == base then
        add(e.workspace)
      end
    end
  end
  return out
end

---Completion for `[dest] [workspace] [--nvim-profile=<key>]`.
local function complete_args(arglead, cmdline, cursorpos)
  -- split what is already typed, ignoring a partially typed current word
  local before = cmdline:sub(1, cursorpos)
  local words = vim.split(before, '%s+', { trimempty = true })
  if not before:match('%s$') then
    table.remove(words) -- the current (incomplete) word
  end
  table.remove(words, 1) -- the command itself

  local positional = {}
  local flags = {}
  local i = 1
  while i <= #words do
    local w = words[i]
    if w:match('^%-%-nvim%-profile=') then
      flags.nvim_profile = w:match('^%-%-nvim%-profile=(.*)$')
      i = i + 1
    elseif w == '--nvim-profile' or w == '-p' then
      flags.nvim_profile = words[i + 1]
      i = i + 2
    elseif w:sub(1, 2) == '--' then
      i = i + 1
    else
      positional[#positional + 1] = w
      i = i + 1
    end
  end

  local cfg = require('sshdev.config').get()

  -- --nvim-profile=<key>: complete remembered/known profile keys
  local key_prefix = arglead:match('^%-%-nvim%-profile=(.*)$')
  if key_prefix then
    local out = {}
    for _, key in ipairs(require('sshdev.history').nvim_profile_keys(positional[1])) do
      if key:sub(1, #key_prefix) == key_prefix then
        out[#out + 1] = '--nvim-profile=' .. key
      end
    end
    return out
  end
  if arglead:sub(1, 1) == '-' then
    local flag = '--nvim-profile='
    if flag:sub(1, #arglead) == arglead then
      return { flag }
    end
    return {}
  end

  if #positional == 0 then
    local out = destination_candidates(cfg)
    table.sort(out)
    return vim.tbl_filter(function(c)
      return c:sub(1, #arglead) == arglead
    end, out)
  end
  if #positional == 1 then
    local out = workspace_candidates(cfg, positional[1])
    table.sort(out)
    return vim.tbl_filter(function(c)
      return c:sub(1, #arglead) == arglead
    end, out)
  end
  return {}
end

local function sshdev_cmd(name, desc, fn, opts)
  opts = opts or {}
  vim.api.nvim_create_user_command(name, function(o)
    local parsed, err = parse_args(o)
    if not parsed then
      return report(err)
    end
    local ok, e = pcall(fn, parsed)
    if not ok then
      report(e)
    end
  end, {
    desc = desc,
    nargs = opts.nargs or '*',
    bang = opts.bang or false,
    complete = opts.complete ~= false and complete_args or nil,
  })
end

local function session_fn(name)
  return function(parsed)
    require('sshdev.session')[name](parsed)
  end
end

---`:SSHdevConnect` with no arguments opens the connection picker.
sshdev_cmd('SSHdevConnect', 'sshdev: connect to a remote workspace (! resyncs and restarts)', function(parsed)
  local Session = require('sshdev.session')
  if parsed.dest == nil then
    return Session.pick({ force = parsed.force })
  end
  Session.connect(parsed)
end, { bang = true })

sshdev_cmd('SSHdevAttach', 'sshdev: attach to an already-running remote server', function(parsed)
  parsed.reuse_only = true
  require('sshdev.session').connect(parsed)
end)

sshdev_cmd('SSHdevInstall', 'sshdev: bootstrap nvim + config + plugins on the remote', session_fn('install'))
sshdev_cmd('SSHdevSync', 'sshdev: re-upload config + reinstall plugins into the nvim profile', session_fn('sync'))
sshdev_cmd('SSHdevStop', 'sshdev: stop the remote server (saves the session)', session_fn('stop'))
sshdev_cmd('SSHdevStatus', 'sshdev: show session, profiles, tunnel and remote server state', session_fn('status'))

---`:SSHdevHistory [dest]` — picker only (never bootstraps on its own).
sshdev_cmd('SSHdevHistory', 'sshdev: pick a remembered remote workspace', function(parsed)
  if parsed.workspace then
    return report('expected at most one argument: [destination]')
  end
  require('sshdev.session').pick_history({ dest = parsed.dest })
end)

---`:SSHdevProfiles [dest]` — list reusable nvim profiles on the remote.
sshdev_cmd('SSHdevProfiles', 'sshdev: list reusable nvim profiles on the remote', function(parsed)
  if parsed.workspace then
    return report('expected at most one argument: [destination]')
  end
  require('sshdev.session').profiles({ dest = parsed.dest })
end)

vim.api.nvim_create_user_command('SSHdevLog', function()
  require('sshdev.util').open_log()
end, { desc = 'sshdev: open the log' })

-- Kill the local tunnel when this nvim exits without a pending attach; the
-- remote server always keeps running (that is the point).
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('sshdev', { clear = true }),
  callback = function()
    require('sshdev.session').teardown_local()
  end,
})
