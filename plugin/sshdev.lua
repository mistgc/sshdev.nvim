--- sshdev.nvim commands.
--- Handlers lazy-load everything; nothing heavy happens at startup.

if vim.g.loaded_sshdev then
  return
end
vim.g.loaded_sshdev = true

local function report(err)
  require('sshdev.util').report_error(err)
end

---Parse the shared "[dest] [workspace]" argument shape.
---@param o table user command args
---@return table|nil opts
---@return string|nil err
local function parse_args(o)
  local opts = { force = o.bang }
  local fargs = o.fargs or {}
  if #fargs > 2 then
    return nil, 'expected at most two arguments: [destination] [workspace]'
  end
  if #fargs >= 1 then
    opts.dest = fargs[1]
  end
  if #fargs == 2 then
    opts.workspace = fargs[2]
  end
  return opts
end

---Completion: remembered connections + configured destinations.
local function complete_dest(arglead)
  local cfg = require('sshdev.config').get()
  local cands = {}
  for _, name in pairs(vim.tbl_keys(cfg.remotes or {})) do
    cands[#cands + 1] = name
  end
  if cfg.host then
    cands[#cands + 1] = cfg.host
  end
  for _, e in ipairs(require('sshdev.history').list()) do
    cands[#cands + 1] = e.dest
  end
  local seen, out = {}, {}
  for _, c in ipairs(cands) do
    if not seen[c] and c:sub(1, #arglead) == arglead then
      seen[c] = true
      out[#out + 1] = c
    end
  end
  table.sort(out)
  return out
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
    complete = opts.complete ~= false and complete_dest or nil,
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
sshdev_cmd('SSHdevSync', 'sshdev: re-upload config + session helper', session_fn('sync'))
sshdev_cmd('SSHdevStop', 'sshdev: stop the remote server (saves the session)', session_fn('stop'))
sshdev_cmd('SSHdevStatus', 'sshdev: show session, tunnel and remote server state', session_fn('status'))

---`:SSHdevHistory` — picker only (never bootstraps on its own).
vim.api.nvim_create_user_command('SSHdevHistory', function()
  require('sshdev.session').pick({})
end, { desc = 'sshdev: pick a remembered connection', nargs = 0 })

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
