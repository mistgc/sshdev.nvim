--- sshdev.nvim commands.
--- Command handlers lazy-load everything; nothing heavy happens at startup.

if vim.g.loaded_sshdev then
  return
end
vim.g.loaded_sshdev = true

local Util --- @type table|nil  (loaded on first error)

local function report(err)
  Util = Util or require('sshdev.util')
  Util.report_error(err)
end

---Parse the shared "[dest] [remote-dir]" argument shape.
---Returns an opts table for the Lua API, or nil + error message.
local function parse_args(o)
  local opts = { force = o.bang }
  local fargs = o.fargs or {}
  if #fargs > 2 then
    return nil, 'expected at most two arguments: [destination] [remote-dir]'
  end
  if #fargs >= 1 then
    opts.dest = fargs[1]
  end
  if #fargs == 2 then
    opts.path = fargs[2]
  end
  return opts
end

---Completion: configured remotes keys + the default host.
local function complete_dest(arglead)
  local cfg = require('sshdev.config').get()
  local cands = {}
  for name in pairs(cfg.remotes or {}) do
    cands[#cands + 1] = name
  end
  table.sort(cands)
  if cfg.host then
    cands[#cands + 1] = cfg.host
  end
  local out = {}
  for _, c in ipairs(cands) do
    if c:sub(1, #arglead) == arglead then
      out[#out + 1] = c
    end
  end
  return out
end

local function sshdev_cmd(name, desc, fn, opts)
  opts = opts or {}
  local handler = function(o)
    local parsed, err = parse_args(o)
    if not parsed then
      return report(err)
    end
    -- pcall guards the synchronous part (arg validation, flow launch);
    -- the async flow reports its own errors.
    local ok, e = pcall(fn, parsed)
    if not ok then
      report(e)
    end
  end
  opts.desc = desc
  opts.nargs = opts.nargs or '*'
  opts.bang = opts.bang or false
  opts.complete = opts.complete or complete_dest
  vim.api.nvim_create_user_command(name, handler, opts)
end

local function session_fn(name)
  return function(parsed)
    require('sshdev.session')[name](parsed)
  end
end

sshdev_cmd(
  'SSHdevConnect',
  'sshdev: sync config to the remote and attach the UI (! resyncs and restarts)',
  session_fn('connect'),
  { bang = true }
)

sshdev_cmd(
  'SSHdevAttach',
  'sshdev: attach to an already-running remote server',
  function(parsed)
    parsed.reuse_only = true
    require('sshdev.session').connect(parsed)
  end
)

sshdev_cmd('SSHdevInstall', 'sshdev: bootstrap config + nvim + plugins on the remote', session_fn('install'))
sshdev_cmd('SSHdevSync', 'sshdev: re-upload config + shim to the remote', session_fn('sync'))
sshdev_cmd('SSHdevStop', 'sshdev: stop the remote server and the local tunnel', session_fn('stop'))
sshdev_cmd('SSHdevStatus', 'sshdev: show session and remote server state', session_fn('status'))

vim.api.nvim_create_user_command('SSHdevLog', function()
  require('sshdev.util').open_log()
end, { desc = 'sshdev: open the log' })

-- Kill the local tunnel when this nvim exits without attaching; the
-- remote server always keeps running (that is the point).
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('sshdev', { clear = true }),
  callback = function()
    require('sshdev.session').teardown_local()
  end,
})
