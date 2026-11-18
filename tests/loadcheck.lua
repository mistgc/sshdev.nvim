--- Load-check: every shipped lua module must load without errors.
--- Run:  nvim --headless -l tests/loadcheck.lua

local this = vim.fs.abspath(arg[0])
local root = vim.fs.dirname(vim.fs.dirname(this))

package.path = table.concat({
  root .. '/lua/?.lua',
  root .. '/lua/?/init.lua',
  root .. '/?.lua',
  package.path,
}, ';')

local modules = {
  'sshdev.util',
  'sshdev.config',
  'sshdev.proc',
  'sshdev.ssh',
  'sshdev.bootstrap',
  'sshdev.session',
  'sshdev.health',
  'sshdev',
}

local failures = 0
for _, m in ipairs(modules) do
  local ok, err = pcall(require, m)
  if ok then
    print(('OK:   %s'):format(m))
  else
    failures = failures + 1
    print(('FAIL: %s: %s'):format(m, tostring(err)))
  end
end

-- the shim must be a no-op outside a sshdev remote and compile cleanly
local ok, err = loadfile(root .. '/scripts/remote_shim.lua')
if ok then
  print('OK:   scripts/remote_shim.lua (compiles)')
else
  failures = failures + 1
  print(('FAIL: scripts/remote_shim.lua: %s'):format(tostring(err)))
end

if failures > 0 then
  os.exit(1)
end
print('all modules load')
