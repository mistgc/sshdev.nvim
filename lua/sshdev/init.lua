--- sshdev.nvim — develop on remote hosts with your local Neovim config.
---
--- Architecture:
---
---   local nvim ⇄ ssh -N -L (forward) ⇄ remote `nvim --headless --listen`
---
---   1. your config is scp'd to ~/.sshdev.nvim/<workspace>/nvim-config/
---   2. a nvim binary matching your local version is installed on the
---      remote (download through a proxy/mirror when configured), and a
---      headless run installs the plugins declared in the config
---   3. the remote server is started in the remote folder you designate
---      as the workspace, and the local UI attaches with :connect
---   4. :q is hijacked into :detach on the remote so quitting your local
---      nvim never kills the remote server
---
--- Requires Neovim >= 0.11 on both ends (the release that introduced
--- :connect and :detach).

local M = {}

--- Configure sshdev.nvim (see |sshdev-setup| for all options).
--- Reports validation errors via :messages instead of throwing.
---@param opts table|nil
---@return table cfg the active configuration
function M.setup(opts)
  local Config = require('sshdev.config')
  local cfg, err = Config.setup(opts)
  if err then
    require('sshdev.util').report_error(err)
  end
  return cfg
end

---------------------------------------------------------------------
-- Lua API (the :SSHdev* commands are defined in plugin/sshdev.lua)
---------------------------------------------------------------------

local function session()
  return require('sshdev.session')
end

---Connect to a remote workspace (like |:SSHdevConnect|).
---opts: { dest = "[user@]host[:port]", path = "remote dir", force = bool }
function M.connect(opts)
  session().connect(opts)
end

---Attach to an already-running remote server (like |:SSHdevAttach|).
function M.attach(opts)
  opts = vim.tbl_deep_extend('force', opts or {}, { reuse_only = true })
  session().connect(opts)
end

---Bootstrap the remote (config + nvim + plugins) without attaching.
function M.install(opts)
  session().install(opts)
end

---Re-upload config + shim without restarting anything.
function M.sync(opts)
  session().sync(opts)
end

---Stop the remote server and the local tunnel.
function M.stop()
  session().stop()
end

---Show the session status.
function M.status()
  session().status()
end

---Open the sshdev log.
function M.log()
  require('sshdev.util').open_log()
end

return M
