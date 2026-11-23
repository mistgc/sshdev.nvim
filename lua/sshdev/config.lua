--- Configuration for sshdev.nvim (`require("sshdev").setup(opts)`).
---
--- Terminology:
---   * workspace          -- the remote PROJECT DIRECTORY (e.g. ~/src/app)
---   * nvim profile       -- an immutable, reusable bundle of (uploaded
---                           config + plugin instances + a link to the nvim
---                           binary of one version):
---                             <remote_root>/nvim-profiles/<nvim-profile-key>/
---                           The key is derived from the LOCAL hostname, the
---                           nvim version and the config CONTENT hash, so
---                           several client machines sharing one remote
---                           account never share a profile by accident, and
---                           a second workspace with the same config reuses
---                           the plugins that are already installed.
---   * workspace profile  -- the per-(local host, workspace) runtime state:
---                           session, server pid/addr/log and a link to the
---                           nvim profile:
---                             <remote_root>/workspace-profiles/<workspace-key>/

local Keys = require('sshdev.keys')
local Util = require('sshdev.util')

---List type check: vim.islist (0.11+) with the older tbl_islist fallback.
local islist = vim.islist or vim.tbl_islist

local M = {}

M.defaults = {
  ---Default destination "[user@]host[:port]" used by :SshDevConnect without
  ---arguments (and as a suggestion in the connection picker).
  host = nil,

  ---Named destinations: name -> "[user@]host[:port]".
  remotes = {},

  ---Default remote workspace (the remote PROJECT DIRECTORY the server runs
  ---in). Absolute or "~/...". Defaults to the remote $HOME.
  workspace = nil,

  ---Force the workspace profile directory name (default:
  ---"--<local-hostname>--<workspace-path>--"). Deprecated alias: `profile`.
  workspace_profile = nil,

  ---Which nvim profile to use:
  ---  "auto"              derive the key from (local hostname, nvim version,
  ---                      config content hash) -- the default, and what makes
  ---                      a new workspace reuse an already installed profile
  ---  "--<host>--<version>--<hash8>--"  reuse that exact existing profile
  nvim_profile = 'auto',

  ---Save the remote nvim session to
  ---<workspace profile>/session.vim when the server exits, and restore it on
  ---the next start.
  session = true,

  ---Restore session.vim when (re)starting the server. Set false to start
  ---clean while still saving (e.g. :SshDevConnect with a fresh session).
  restore_session = true,

  ---Re-apply the workspace's persisted forward.txt automatically after
  ---:SshDevConnect / :SshDevAttach (one extra read-only ssh round trip;
  ---silently does nothing without a forward.txt). Forwards whose ports
  ---already listen (leftovers from a previous session) are left alone.
  forward_on_connect = true,

  ---Read the workspace's persisted env.txt on connect/attach and inject
  ---its variables (startup exports + one runtime push after attach).
  ---false = only an explicit :SshDevEnv save injects, for this nvim session.
  env_on_connect = true,

  ---ssh/scp binaries.
  ssh_bin = 'ssh',
  scp_bin = 'scp',

  ---Extra arguments for every ssh/scp invocation,
  ---e.g. { "-i", "~/.ssh/id_ed25519", "-o", "Compression=yes" }.
  ssh_args = {},

  ---How ssh authentication proceeds:
  ---  "auto"      default: keys / ssh-agent first, non-interactive; when
  ---              the server rejects that, ask for a password once
  ---              (|inputsecret()|, in-memory only) and retry. The
  ---              password is then cached for the rest of the nvim session
  ---  "password"  ask before the first ssh call (known password-only
  ---              host; skips the failed non-interactive round trip)
  ---  "key"       strictly non-interactive: never prompt or use askpass
  ---The password fallback needs an OpenSSH client >= 8.4
  ---(SSH_ASKPASS_REQUIRE; the Windows inbox client has it since 8.6).
  auth = 'auto',

  ---Remote root for all sshdev state:
  ---  <root>/nvim-bins/<version>/             nvim releases (shared)
  ---  <root>/nvim-profiles/<key>/             reusable config + plugins
  ---  <root>/workspace-profiles/<key>/        session + server state
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

  ---Keep the local UI alive when the ssh link drops. With this enabled
  ---(the default), the `connect` attach strategy goes through a small
  ---local RPC relay that owns the ssh tunnel. The relay keeps the UI's
  ---channel open, rebuilds the tunnel when the network drops and replays
  ---the UI attach on the new link, so the local nvim process survives and
  ---the remote nvim session continues untouched. `false` restores the
  ---direct `:connect` behaviour, where losing the tunnel terminates the
  ---local nvim (that is what made a network flap look like a crash).
  ---Only the `connect` strategy is proxied; the `terminal` strategy keeps
  ---its explicit UI-client terminal and is not auto-reconnected.
  reconnect = true,

  ---Record every connection and offer a picker when :SshDevConnect is called
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
    lock = 120, -- waiting for another client bootstrapping the same profile
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
  -- deprecated alias: profile -> workspace_profile
  if opts.profile ~= nil then
    if opts.workspace_profile == nil then
      opts.workspace_profile = opts.profile
    end
    opts.profile = nil
  end
  -- removed option: quit hijacking (session save/restore replaced it).
  -- Drop it silently so old configs keep working instead of carrying a
  -- meaningless key around.
  opts.hijack_quit = nil
  -- dropped option: the content hash decides when to resync now.
  opts.force_sync = nil
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
    if w:find("['\r\n\t]") then
      return 'setup: "workspace" must not contain quotes, tabs or newlines'
    end
  end
  if cfg.workspace_profile ~= nil then
    if type(cfg.workspace_profile) ~= 'string' or cfg.workspace_profile == '' then
      return 'setup: "workspace_profile" must be a non-empty directory name'
    end
    if cfg.workspace_profile:find("[/\\'\"\r\n\t]") then
      return 'setup: "workspace_profile" must be a single path segment'
    end
  end
  if cfg.nvim_profile ~= nil and cfg.nvim_profile ~= 'auto' then
    local ok, err = Keys.validate_nvim_profile_key(cfg.nvim_profile)
    if not ok then
      return 'setup: "nvim_profile": ' .. tostring(err)
    end
  end
  if type(cfg.session) ~= 'boolean' then
    return 'setup: "session" must be a boolean'
  end
  if type(cfg.restore_session) ~= 'boolean' then
    return 'setup: "restore_session" must be a boolean'
  end
  if type(cfg.forward_on_connect) ~= 'boolean' then
    return 'setup: "forward_on_connect" must be a boolean'
  end
  if type(cfg.env_on_connect) ~= 'boolean' then
    return 'setup: "env_on_connect" must be a boolean'
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
  if not vim.tbl_contains({ 'auto', 'password', 'key' }, cfg.auth) then
    return 'setup: "auth" must be one of "auto", "password", "key"'
  end
  if type(cfg.remote_root) ~= 'string' or cfg.remote_root == '' then
    return 'setup: "remote_root" must be a non-empty path'
  end
  if cfg.remote_root:find("['\r\n\t]") then
    return 'setup: "remote_root" must not contain quotes, tabs or newlines'
  end
  if cfg.remote_root:sub(1, 1) ~= '~' and cfg.remote_root:sub(1, 1) ~= '/' then
    return 'setup: "remote_root" must be absolute or "~"-relative'
  end
  if type(cfg.nvim_version) ~= 'string' or cfg.nvim_version == '' then
    return 'setup: "nvim_version" must be "auto", a "vX.Y.Z" tag, "nightly" or "stable"'
  end
  if cfg.nvim_version ~= 'auto' and not Keys.is_valid_version(cfg.nvim_version) then
    return 'setup: "nvim_version" must be a safe release tag (letters, digits, ".", "_", "-")'
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
  if type(cfg.reconnect) ~= 'boolean' then
    return 'setup: "reconnect" must be a boolean'
  end
  if type(cfg.timeouts) ~= 'table' then
    return 'setup: "timeouts" must be a table of seconds'
  end
  for _, k in ipairs({ 'ssh', 'download', 'install', 'attach', 'lock' }) do
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
