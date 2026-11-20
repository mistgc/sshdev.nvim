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
  'sshdev.keys',
  'sshdev.layout',
  'sshdev.config',
  'sshdev.proc',
  'sshdev.auth',
  'sshdev.ssh',
  'sshdev.remote_scripts',
  'sshdev.bootstrap',
  'sshdev.forward',
  'sshdev.history',
  'sshdev.picker',
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

-- the remote helper must be a no-op outside a sshdev remote and compile
local ok, err = loadfile(root .. '/scripts/remote_session.lua')
if ok then
  print('OK:   scripts/remote_session.lua (compiles)')
else
  failures = failures + 1
  print(('FAIL: scripts/remote_session.lua: %s'):format(tostring(err)))
end

-- the telescope extension is only loadable when telescope is installed;
-- without it, require must fail with a plain "module not found"
local tok, terr = pcall(require, 'telescope._extensions.sshdev')
local missing_optional = not tok and tostring(terr):find("'telescope' not found", 1, true) ~= nil
if tok or missing_optional then
  print('OK:   lua/telescope/_extensions/sshdev.lua (guarded)')
else
  failures = failures + 1
  print(('FAIL: telescope extension: %s'):format(tostring(terr)))
end

if failures > 0 then
  os.exit(1)
end
print('all modules load')
