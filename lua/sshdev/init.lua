--- sshdev.nvim — develop on remote hosts with your local Neovim config.
---
--- Terminology:
---   workspace  the remote PROJECT DIRECTORY the server runs in
---   profile    <remote_root>/<local-hostname>-<workspace-path>/ holding the
---              uploaded config, plugins, data, session.vim and logs
---
--- Pipeline:
---   1. your config is scp'd to <profile>/nvim-config/
---   2. a nvim binary matching your local version is installed under
---      ~/.sshdev.nvim/_bin/ (download through a proxy/mirror if configured)
---      and a headless run installs the plugins declared in your config
---   3. the remote server starts in the workspace, forwarding through an
---      ssh tunnel; the local UI attaches (--remote-ui for the TUI)
---   4. the server saves session.vim when it exits; the next connection
---      restores it. There is no quit hijacking.
---
--- Requires Neovim >= 0.11 on both ends.

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
  -- register the telescope extension lazily (telescope stays optional)
  if pcall(require, 'telescope') then
    pcall(function()
      require('telescope').load_extension('sshdev')
    end)
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
---opts: { dest = "[user@]host[:port]", workspace = "remote project dir", force = bool }
function M.connect(opts)
  session().connect(opts)
end

---Attach to an already-running remote server.
function M.attach(opts)
  opts = vim.tbl_deep_extend('force', opts or {}, { reuse_only = true })
  session().connect(opts)
end

---Open the connection picker (telescope / vim.ui.select).
function M.pick(opts)
  session().pick(opts)
end

---Bootstrap the remote (binary + config + plugins) without attaching.
function M.install(opts)
  session().install(opts)
end

---Re-upload config + session helper without restarting anything.
function M.sync(opts)
  session().sync(opts)
end

---Stop the remote server (saves session.vim) and the local tunnel.
function M.stop()
  session().stop()
end

---Show the session status.
function M.status()
  session().status()
end

---Remembered connections (see |sshdev-history|).
function M.history()
  return require('sshdev.history').list()
end

---Open the sshdev log.
function M.log()
  require('sshdev.util').open_log()
end

return M
