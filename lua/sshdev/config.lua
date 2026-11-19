--- Configuration for sshdev.nvim (`require("sshdev").setup(opts)`).
---
--- Terminology:
---   * workspace       -- the remote PROJECT DIRECTORY (e.g. ~/src/app)
---   * profile         -- remote state dir for (local host, workspace):
---                        <remote_root>/<local-hostname>-<workspace-path>/
---                        It holds the uploaded config, plugins, data,
---                        session.vim and logs, isolating different client
---                        machines that share one remote account.

local Util = require('sshdev.util')

---List type check: vim.islist (0.11+) with the older tbl_islist fallback.
local islist = vim.islist or vim.tbl_islist

local M = {}

M.defaults = {
  ---Default destination "[user@]host[:port]" used by :SSHdevConnect without
  ---arguments (and as a suggestion in the connection picker).
  host = nil,

  ---Named destinations: name -> "[user@]host[:port]".
  remotes = {},

  ---Default remote workspace (the remote PROJECT DIRECTORY the server runs
  ---in). Absolute or "~/...". Defaults to the remote $HOME.
  workspace = nil,

  ---Force the profile directory name (default:
  ---"<local-hostname>-<workspace-path>").
  profile = nil,

  ---Save the remote nvim session to <profile>/session.vim when the server
  ---exits, and restore it on the next start.
  session = true,

  ---Restore session.vim when (re)starting the server. Set false to start
  ---clean while still saving (e.g. :SSHdevConnect with a fresh session).
  restore_session = true,

  ---ssh/scp binaries.
  ssh_bin = 'ssh',
  scp_bin = 'scp',

  ---Extra arguments for every ssh/scp invocation,
  ---e.g. { "-i", "~/.ssh/id_ed25519", "-o", "Compression=yes" }.
  ssh_args = {},

  ---Remote root for all sshdev state: "<root>/<profile>/" and "<root>/_bin/".
  remote_root = '~/.sshdev.nvim',

  ---Which nvim release to install on the remote:
  ---  "auto"    match the local nvim's exact version (default)
  ---  "vX.Y.Z"  pin an exact release
  ---  "nightly" / "stable"
  nvim_version = 'auto',

  ---Proxy URL used ON THE REMOTE when downloading nvim
  ---(http://... or socks5://...). Set when the remote cannot reach GitHub.
  proxy = nil,

  ---Base URL for nvim release downloads (change to a mirror if needed).
  download_mirror = 'https://github.com/neovim/neovim/releases/download',

  ---Extra headless ex-commands to run when bootstrapping plugins on the
  ---remote, e.g. { "Lazy! restore" } (lazy.nvim) or { "PackerSync" }.
  install_commands = {},

  ---Globs of files to exclude from the config upload.
  excludes = { '.git', '.github' },

  ---How the local UI attaches to the remote server (needs Nvim >= 0.12,
  ---the release that added :connect):
  ---  "auto"      use |:connect| with the tunnel address (the builtin TUI
  ---              is a UI client since 0.12 and re-attaches in place);
  ---              headless falls back to "command"
  ---  "connect"   always |:connect| ("host:port", no scheme)
  ---  "terminal"  open a terminal tab with a separate
  ---              `nvim --server host:port --remote-ui` UI client
  ---  "command"   do not attach; just print the command to run
  attach = 'auto',

  ---Record every connection and offer a picker when :SSHdevConnect is called
  ---without arguments (telescope when available, vim.ui.select otherwise).
  history = true,

  ---Maximum number of remembered connections.
  history_limit = 50,

  ---Timeouts in seconds.
  timeouts = {
    ssh = 60, -- per ssh command (probe, server control, ...)
    download = 600, -- remote nvim download
    install = 900, -- remote headless plugin install
    attach = 30, -- waiting for the tunnel + server to accept RPC
  },
}

local function merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == 'table' and type(dst[k]) == 'table' then
      merge(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

M._cfg = nil

---Apply defaults + user opts and validate. Stores the result as the active
---configuration. Returns (cfg, err).
---@param opts table|nil
---@return table cfg
---@return string? err
function M.setup(opts)
  local cfg, err = M.build(opts)
  if err then
    return cfg, err
  end
  M._cfg = cfg
  return cfg, nil
end

---Build + validate a configuration without installing it.
---@param opts table|nil
---@return table cfg
---@return string? err
function M.build(opts)
  opts = vim.deepcopy(opts or {})
  -- deprecated alias: remote_dir -> workspace
  if opts.remote_dir ~= nil then
    if opts.workspace == nil then
      opts.workspace = opts.remote_dir
    end
    opts.remote_dir = nil
  end
  -- removed option: quit hijacking (session save/restore replaced it).
  -- Drop it silently so old configs keep working instead of carrying a
  -- meaningless key around.
  opts.hijack_quit = nil
  local cfg = merge(vim.deepcopy(M.defaults), opts)
  local err = M.validate(cfg)
  return cfg, err
end

local function is_list_of_strings(t)
  if type(t) ~= 'table' or islist(t) ~= true then
    return false
  end
  for _, v in ipairs(t) do
    if type(v) ~= 'string' then
      return false
    end
  end
  return true
end

---Validate; returns a user-facing error message or nil.
---@param cfg table
---@return string? err
function M.validate(cfg)
  if cfg.host ~= nil and type(cfg.host) ~= 'string' then
    return 'setup: "host" must be a string like "user@host" or "user@host:2222"'
  end
  if cfg.host then
    local _, err = Util.parse_dest(cfg.host)
    if err then
      return 'setup: "host": ' .. err
    end
  end
  if type(cfg.remotes) ~= 'table' then
    return 'setup: "remotes" must be a table: name -> destination'
  end
  for name, dest in pairs(cfg.remotes) do
    if type(name) ~= 'string' or name == '' then
      return 'setup: "remotes" keys must be non-empty names'
    end
    if type(dest) ~= 'string' then
      return ('setup: remotes["%s"] must be a destination string'):format(name)
    end
    local _, err = Util.parse_dest(dest)
    if err then
      return ('setup: remotes["%s"]: %s'):format(name, err)
    end
  end
  if cfg.workspace ~= nil then
    if type(cfg.workspace) ~= 'string' or cfg.workspace == '' then
      return 'setup: "workspace" must be a remote project directory path'
    end
    local w = cfg.workspace
    if w:sub(1, 1) ~= '~' and w:sub(1, 1) ~= '/' then
      return 'setup: "workspace" must be absolute or "~"-relative'
    end
    if w:find("['\r\n]") then
      return 'setup: "workspace" must not contain quotes or newlines'
    end
  end
  if cfg.profile ~= nil and (type(cfg.profile) ~= 'string' or cfg.profile == '') then
    return 'setup: "profile" must be a non-empty directory name'
  end
  if type(cfg.session) ~= 'boolean' then
    return 'setup: "session" must be a boolean'
  end
  if type(cfg.restore_session) ~= 'boolean' then
    return 'setup: "restore_session" must be a boolean'
  end
  if type(cfg.history) ~= 'boolean' then
    return 'setup: "history" must be a boolean'
  end
  if type(cfg.history_limit) ~= 'number' or cfg.history_limit < 1 then
    return 'setup: "history_limit" must be a positive number'
  end
  if type(cfg.ssh_bin) ~= 'string' or type(cfg.scp_bin) ~= 'string' then
    return 'setup: "ssh_bin" and "scp_bin" must be strings'
  end
  if not is_list_of_strings(cfg.ssh_args) then
    return 'setup: "ssh_args" must be a list of strings'
  end
  if type(cfg.remote_root) ~= 'string' or cfg.remote_root == '' then
    return 'setup: "remote_root" must be a non-empty path'
  end
  if cfg.remote_root:find("['\r\n]") then
    return 'setup: "remote_root" must not contain quotes or newlines'
  end
  if cfg.remote_root:sub(1, 1) ~= '~' and cfg.remote_root:sub(1, 1) ~= '/' then
    return 'setup: "remote_root" must be absolute or "~"-relative'
  end
  if type(cfg.nvim_version) ~= 'string' or cfg.nvim_version == '' then
    return 'setup: "nvim_version" must be "auto", a "vX.Y.Z" tag, "nightly" or "stable"'
  end
  if cfg.proxy ~= nil then
    if type(cfg.proxy) ~= 'string' or cfg.proxy == '' then
      return 'setup: "proxy" must be a URL string like "http://host:port"'
    end
    if not cfg.proxy:match('^[%w%+%.%-]+://[%w%.%-_:]+:%d+$') then
      return 'setup: "proxy" must look like "http://host:port" or "socks5://host:port"'
    end
  end
  if type(cfg.download_mirror) ~= 'string' or cfg.download_mirror == '' then
    return 'setup: "download_mirror" must be a URL string'
  end
  if not is_list_of_strings(cfg.install_commands) then
    return 'setup: "install_commands" must be a list of ex-command strings'
  end
  for _, c in ipairs(cfg.install_commands) do
    if c:find('[\r\n]') then
      return 'setup: "install_commands" entries must not contain newlines'
    end
  end
  if not is_list_of_strings(cfg.excludes) then
    return 'setup: "excludes" must be a list of glob strings'
  end
  if not vim.tbl_contains({ 'auto', 'terminal', 'connect', 'command' }, cfg.attach) then
    return 'setup: "attach" must be one of "auto", "terminal", "connect", "command"'
  end
  if type(cfg.timeouts) ~= 'table' then
    return 'setup: "timeouts" must be a table of seconds'
  end
  for _, k in ipairs({ 'ssh', 'download', 'install', 'attach' }) do
    local v = cfg.timeouts[k]
    if type(v) ~= 'number' or v <= 0 then
      return ('setup: timeouts.%s must be a positive number of seconds'):format(k)
    end
  end
  return nil
end

---Current configuration (defaults if setup() was never called).
function M.get()
  if not M._cfg then
    M._cfg = vim.deepcopy(M.defaults)
  end
  return M._cfg
end

return M
