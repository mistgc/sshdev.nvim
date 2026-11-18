--- Test entry point:  nvim --headless -l tests/run.lua

local this = vim.fs.abspath(arg[0])
local root = vim.fs.dirname(vim.fs.dirname(this)) -- repo root

package.path = table.concat({
  root .. '/lua/?.lua',
  root .. '/lua/?/init.lua',
  root .. '/?.lua',
  package.path,
}, ';')

local T = require('tests.sshdev_spec') -- runs the assertions, returns harness

os.exit(T.done())
