--- sshdev.nvim — develop on remote hosts with your local Neovim config.
---
--- Terminology:
---   nvim profile       reusable bundle of uploaded config + plugin instances
---                      + a link to one nvim version's binary:
---                        <remote_root>/nvim-profiles/--<host>--<version>--<hash8>--/
---   workspace profile  per (local host, workspace) session/server state:
---                        <remote_root>/workspace-profiles/--<host>--<ws-path>--/
---
--- Pipeline:
---   1. a nvim binary matching your local version is installed under
---      <remote_root>/nvim-bins/<version>/ (proxy/mirror supported)
---   2. your config is uploaded into a REUSABLE nvim profile and a headless
---      run installs the plugins once; every other workspace with the same
---      config content reuses that profile and skips the install
---   3. the remote server starts in the workspace (session kept per workspace),
---      forwarding through an ssh tunnel; the local UI attaches
---   4. the server saves session.vim when it exits; the next connection
---      restores it. There is no quit hijacking.
---
--- Requires Neovim >= 0.12 on both ends.

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
-- Lua API (the :SshDev* commands are defined in plugin/sshdev.lua)
---------------------------------------------------------------------

local function session()
  return require('sshdev.session')
end

---Connect to a remote workspace (like |:SshDevConnect|).
---opts: { dest = "[user@]host[:port]", workspace = "remote project dir",
---        nvim_profile = "--<host>--<version>--<hash8>--" (reuse an existing
---        nvim profile), force = bool }
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

---Open the workspace picker for one destination (remote scan filtered to this
---client hostname). `opts.dest` selects the destination; otherwise `host` or
---the single configured remote is used.
function M.pick_history(opts)
  session().pick_history(opts)
end

---List the nvim profiles that exist on the remote for this client host.
function M.profiles(opts)
  session().profiles(opts)
end

---Bootstrap the remote (binary + config + plugins) without attaching.
function M.install(opts)
  session().install(opts)
end

---Re-upload config + session helper without restarting anything.
function M.sync(opts)
  session().sync(opts)
end

---Open the workspace's port-forward editor (like |:SshDevForward|):
---the forward.txt of the workspace profile, fetched into a local buffer.
---Saving that buffer re-uploads it and (re)starts the forwards.
---opts: { dest = "[user@]host[:port]", workspace = "remote project dir" }
function M.forward(opts)
  session().forward(opts)
end

---Open the workspace's environment-variable editor (like |:SshDevEnv|):
---the env.txt of the workspace profile, fetched into a local buffer.
---Saving that buffer re-uploads it and injects the variables into the
---remote nvim server and every ssh-run script.
---opts: { dest = "[user@]host[:port]", workspace = "remote project dir" }
function M.env(opts)
  session().env(opts)
end

---Stop the remote server (saves session.vim) and the local tunnel.
---Typed inside the ATTACHED remote session, the command is forwarded to
---the client and runs there (the remote has no local session to stop).
function M.stop()
  session().stop()
end

---Show the session status. Also forwarded to the client when typed in
---the attached remote session (the state it reports lives on the client).
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
