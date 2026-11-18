--- Configuration for sshdev.nvim (`require("sshdev").setup(opts)`).
---
--- Options are validated eagerly so mistakes surface at setup time instead
--- of in the middle of a connect run.

local Util = require('sshdev.util')

---List type check: vim.islist (0.11+) with the older tbl_islist fallback.
local islist = vim.islist or vim.tbl_islist

local M = {}

M.defaults = {
  ---Default destination "[user@]host[:port]" (used when :SSHdevConnect
  ---is called without arguments).
  host = nil,

  ---Named destinations: workspace name -> "[user@]host[:port]".
  ---` :SSHdevConnect <name> ` connects to it.
  remotes = {},

  ---Remote folder to use as the workspace (the remote nvim server's cwd).
  ---"~/..." or absolute. Default: remote $HOME.
  remote_dir = nil,

  ---Force the workspace name (default: basename of the remote dir,
  ---or "default" when it is the remote $HOME).
  workspace = nil,

  ---ssh/scp binaries.
  ssh_bin = 'ssh',
  scp_bin = 'scp',

  ---Extra arguments for every ssh/scp invocation,
  ---e.g. { "-i", "~/.ssh/id_ed25519", "-o", "Compression=yes" }.
  ssh_args = {},

  ---Remote root for sshdev state: "<root>/<workspace>/".
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
  ---Your config's bootstrap snippet handles cloning the plugin manager;
  ---these commands run AFTER your init has been sourced.
  install_commands = {},

  ---Globs of files to exclude from the config upload.
  excludes = { '.git', '.github' },

  ---Hijack :q/:wq/... into :detach on the remote server (the whole point
  ---of sshdev.nvim). Set to false to keep normal quit semantics; the
  ---shim still marks UIs detachable so SSH drops do not kill the server.
  hijack_quit = true,

  ---How the local UI attaches to the remote server:
  ---  "auto"      builtin TUI -> a `nvim --server ... --remote-ui` client in
  ---              a terminal tab; external GUI -> |:connect|; headless ->
  ---              print the command to run
  ---  "terminal"  always open a terminal tab with the --remote-ui client
  ---  "connect"   always use |:connect| (only re-attaches when the UI
  ---              implements the "connect" UI event; the builtin TUI does
  ---              not, where :connect is equivalent to |:detach|)
  ---  "command"   never attach automatically; just show the command
  attach = 'auto',

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
  local cfg = merge(vim.deepcopy(M.defaults), opts or {})
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
    return 'setup: "remotes" must be a table: workspace name -> destination'
  end
  for name, dest in pairs(cfg.remotes) do
    if type(name) ~= 'string' or name == '' then
      return 'setup: "remotes" keys must be non-empty workspace names'
    end
    if type(dest) ~= 'string' then
      return ('setup: remotes["%s"] must be a destination string'):format(name)
    end
    local _, err = Util.parse_dest(dest)
    if err then
      return ('setup: remotes["%s"]: %s'):format(name, err)
    end
  end
  if cfg.remote_dir ~= nil and type(cfg.remote_dir) ~= 'string' then
    return 'setup: "remote_dir" must be a string path'
  end
  if cfg.remote_dir and cfg.remote_dir:sub(1, 1) ~= '~' and cfg.remote_dir:sub(1, 1) ~= '/' then
    return 'setup: "remote_dir" must be absolute or "~"-relative'
  end
  if cfg.workspace ~= nil and type(cfg.workspace) ~= 'string' then
    return 'setup: "workspace" must be a string'
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
  if type(cfg.timeouts) ~= 'table' then
    return 'setup: "timeouts" must be a table of seconds'
  end
  if not vim.tbl_contains({ 'auto', 'terminal', 'connect', 'command' }, cfg.attach) then
    return 'setup: "attach" must be one of "auto", "terminal", "connect", "command"'
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
