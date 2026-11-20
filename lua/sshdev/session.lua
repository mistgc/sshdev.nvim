--- Session orchestration for sshdev.nvim.
---
--- Two-level profile model:
---
---   nvim profile       reusable (config content + nvim version + client host):
---                      <root>/nvim-profiles/--<host>-<version>-<hash8>--/
---   workspace profile  per (client host, workspace): session + server state:
---                      <root>/workspace-profiles/--<host>--<ws-path>--/
---
--- Connect pipeline (async, driven by Proc.launch):
---
---   probe remote ─► resolve version + local config content hash ─► layout
---        │
---        ├─ ensure: nvim bin (shared by version) + profile/server state
---        │        (one ssh round trip, read-only for profiles)
---        │
---        ├─ server already running ─────────────────────────────► attach
---        │
---        └─ prepare profiles ─► upload session helper
---                 ├─ nvim profile .ready == config hash ─► start server
---                 └─ otherwise: scp config to staging ─► headless install
---                      ─► mark .ready ─► start server ─► tunnel ─► attach
---
--- There is no quit hijacking: the remote server simply quits on :q and
--- saves session.vim on the way out, so the next connection restores it.

local Auth = require('sshdev.auth')
local Bootstrap = require('sshdev.bootstrap')
local Config = require('sshdev.config')
local Forward = require('sshdev.forward')
local History = require('sshdev.history')
local Layout = require('sshdev.layout')
local Proc = require('sshdev.proc')
local Ssh = require('sshdev.ssh')
local Util = require('sshdev.util')

local M = {}

local state = {
  info = nil, -- { dest, port, workspace, workspace_profile, workspace_profile_key, nvim_profile, nvim_profile_key, remote_root, lport, rport }
  tunnel = nil, -- ssh tunnel handle (only when WE started it)
  attached = false, -- a :connect was issued from this session
}

---Throw a user-facing error without Lua's "file:line:" prefix.
local function fail(msg)
  error(msg, 0)
end

---@return boolean ok
---@return string? err
local function guard_local()
  if vim.env.SSHDEV_REMOTE == '1' then
    return false, 'this nvim IS a sshdev remote server; refusing to nest sshdev sessions'
  end
  -- Verified against real binaries: :detach exists since 0.11, but :connect
  -- (and --remote-ui) only since 0.12. Both ends are version-matched, so the
  -- local version is the requirement.
  if not Util.nvim_at_least(0, 12) then
    return false, ('sshdev.nvim needs Neovim >= 0.12 locally (found %s): '
      .. ':connect -- the command this plugin attaches with -- does not exist in 0.11'
    ):format(tostring(vim.version()))
  end
  return true, nil
end

---The attach step needs the :connect command (>= 0.12).
local function guard_connect()
  if vim.fn.exists(':connect') ~= 2 then
    return false, ('this Neovim has no :connect command (found %s); '
      .. 'sshdev.nvim needs 0.12 or newer'):format(tostring(vim.version()))
  end
  return true, nil
end

---Resolve a destination argument: a `remotes` key or a raw
---"[user@]host[:port]" spec.
---@param cfg table
---@param arg string|nil
---@return table? parsed
---@return string? err
local function resolve_dest(cfg, arg)
  if arg and cfg.remotes[arg] then
    local parsed, err = Util.parse_dest(cfg.remotes[arg])
    if not parsed then
      return nil, ('setup: remotes["%s"]: %s'):format(arg, err)
    end
    return parsed, nil
  end
  local spec = arg or cfg.host
  if not spec or spec == '' then
    return nil, 'no destination given'
  end
  local parsed, err = Util.parse_dest(spec)
  if not parsed then
    return nil, err
  end
  return parsed, nil
end

-----------------------------------------------------------------------
-- Attach
-----------------------------------------------------------------------

---Classify the UI we run in: the builtin TUI is the UI on channel 1,
---external GUIs attach over an RPC channel (> 1).
---@return 'headless'|'tui'|'external'
local function ui_kind()
  local uis = vim.api.nvim_list_uis()
  if #uis == 0 then
    return 'headless'
  end
  if #uis == 1 and uis[1].chan == 1 then
    return 'tui'
  end
  return 'external'
end

M.ui_kind = ui_kind

---Tell the user what actually happened after the UI client exits: both a
---detach and a real quit exit with code 0, so re-check the server.
local function report_after_ui_exit(cfg, code)
  local info = state.info
  if not info then
    if code ~= 0 then
      Util.notify(('the remote UI exited with code %d (:SshDevAttach to retry)'):format(code), vim.log.levels.WARN)
    end
    return
  end
  local parsed = Util.parse_dest(info.dest)
  if parsed then
    parsed.port = info.port
  end
  Proc.launch(function()
    local st = Bootstrap.server_status(cfg, parsed, {
      workspace_profile = info.workspace_profile,
      nvim_profile = info.nvim_profile,
    })
    if st and st.running then
      Util.notify('detached — the remote server keeps running (:SshDevAttach)')
      return
    end
    state.info = nil
    Util.notify(
      ('remote server for "%s" stopped%s'):format(
        info.workspace,
        st and st.has_session and ' (session saved; :SshDevConnect restores it)' or ''
      )
    )
  end)
end

---Run a `nvim --server <addr> --remote-ui` UI client in a terminal tab.
local function attach_via_terminal(cfg, addr)
  local prog = vim.v.progpath
  if not prog or prog == '' then
    fail('cannot determine the nvim binary path for the remote UI client')
  end

  vim.cmd('tabnew')
  local buf = vim.api.nvim_get_current_buf()

  local job = vim.fn.termopen({ prog, '--server', addr, '--remote-ui' }, {
    on_exit = function(_, code)
      vim.schedule(function()
        pcall(function()
          for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(w) == buf then
              vim.api.nvim_win_close(w, true)
              break
            end
          end
        end)
        if vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        report_after_ui_exit(cfg, code)
      end)
    end,
  })
  if job <= 0 then
    fail('failed to start the remote UI client (nvim --server ... --remote-ui)')
  end
  vim.cmd('startinsert')
end

---Pick the attach strategy.
---
---Facts (verified against real binaries, not assumed):
---  * |:connect| is only parsed for a bare "host:port" address; a "tcp://"
---    scheme is NOT a valid nvim server address -- the UI detaches, fails to
---    attach and the process ends (this is what made it look like ":connect
---    does not work in a TUI" earlier).
---  * since Nvim 0.12, `nvim` starts a builtin UI client process plus an
---    embedded server, and the UI client implements the "connect" UI event,
---    so |:connect| re-attaches the terminal UI in place. (0.11 has no
---    |:connect| command at all; it only gained |:detach|.)
---  * external GUIs implement "connect" explicitly; headless has no UI.
---@param setting string  cfg.attach
---@param kind 'headless'|'tui'|'external'
---@return 'terminal'|'connect'|'command'
local function attach_strategy(setting, kind)
  if setting and setting ~= 'auto' then
    return setting
  end
  if kind == 'headless' then
    return 'command'
  end
  if vim.fn.exists(':connect') == 2 then
    return 'connect'
  end
  -- no :connect available: only the separate UI-client path can attach
  return 'terminal'
end

M.attach_strategy = attach_strategy

---Attach this UI to the remote server according to cfg.attach.
---@param cfg table
---@param addr string "host:port" through the local tunnel
local function attach_ui(cfg, addr)
  local kind = ui_kind()
  local strategy = attach_strategy(cfg.attach or 'auto', kind)
  Util.log('attach strategy: %s (ui: %s)', strategy, kind)

  if strategy == 'connect' then
    local ok, aerr = guard_connect()
    if not ok then
      fail(aerr)
    end
    state.attached = true
    local cok, cerr = pcall(vim.cmd, ('connect %s'):format(addr))
    if not cok then
      state.attached = false
      fail(':connect failed: ' .. tostring(cerr))
    end
    Util.log('UI attached via :connect %s', addr)
    return
  end

  if strategy == 'terminal' then
    attach_via_terminal(cfg, addr)
    Util.log('remote UI client started: nvim --server %s --remote-ui', addr)
    return
  end

  local cmd = ('nvim --server %s --remote-ui'):format(addr)
  Util.notify(('remote server is ready. Attach from a terminal with:\n\n  %s'):format(cmd))
  Util.log('attach command: %s', cmd)
end

---Open the tunnel (or reuse an existing one) and attach.
---Must run inside a flow coroutine.
local function run_attach(cfg, parsed, layout, rport)
  if state.tunnel then
    state.tunnel.kill()
    state.tunnel = nil
  end

  local lbase = Util.local_port(parsed.dest, layout.workspace_profile_key)
  local lport
  if Proc.await_tcp_probe('127.0.0.1', lbase, 400, 2000) then
    lport = lbase
    Util.log('reusing the existing tunnel at 127.0.0.1:%d', lbase)
  else
    lport = select(1, Ssh.pick_local_port(lbase))
    if not lport then
      fail(('no free local port near %d (something holds the range)'):format(lbase))
    end
    if lport ~= lbase then
      Util.log('port %d is busy; the new tunnel uses %d', lbase, lport)
    end
    state.tunnel = Ssh.start_tunnel(cfg, parsed, lport, rport)
  end

  state.info = {
    dest = Util.format_dest(parsed),
    port = parsed.port,
    workspace = layout.workspace,
    workspace_profile = layout.workspace_profile,
    workspace_profile_key = layout.workspace_profile_key,
    nvim_profile = layout.nvim_profile,
    nvim_profile_key = layout.nvim_profile_key,
    remote_root = layout.root,
    lport = lport,
    rport = rport,
  }

  -- The ssh client needs a moment to authenticate and install the forward.
  local uv = vim.uv or vim.loop
  local deadline = uv.now() + cfg.timeouts.attach * 1000
  local reached = false
  local attempt = 0
  while uv.now() < deadline do
    attempt = attempt + 1
    if state.tunnel and not state.tunnel.alive then
      fail(('the ssh tunnel died (exit %s):\n%s'):format(
        tostring(state.tunnel.exit_code or '?'),
        state.tunnel.stderr_tail()
      ))
    end
    if Proc.await_tcp_probe('127.0.0.1', lport, 300, 1500) then
      reached = true
      break
    end
    Util.log('tunnel not answering yet (attempt %d)', attempt)
    Proc.sleep(300)
  end
  if not reached then
    local tail = state.tunnel and state.tunnel.stderr_tail() or '(reused tunnel)'
    if state.tunnel then
      state.tunnel.kill()
      state.tunnel = nil
    end
    fail(('the remote nvim server did not answer through the tunnel at 127.0.0.1:%d '
      .. 'after %ds.\n%s/server.log on the remote and :SshDevLog may help.\n%s'):format(
      lport,
      cfg.timeouts.attach,
      layout.workspace_profile,
      tail
    ))
  end

  Util.log('tunnel up: 127.0.0.1:%d -> %s:127.0.0.1:%d', lport, parsed.dest, rport)
  Util.status('attaching to the remote server ...')
  attach_ui(cfg, ('127.0.0.1:%d'):format(lport))
  History.record(cfg, {
    dest = Util.format_dest(parsed),
    workspace = layout.workspace,
    workspace_profile_key = layout.workspace_profile_key,
    nvim_profile_key = layout.nvim_profile_key,
  })
end

-----------------------------------------------------------------------
-- Shared front half
-----------------------------------------------------------------------

---Guards + destination resolution + remote probe.
---@param opts table
---@return table? cfg
---@return table? parsed
---@return table? probe
local function prepare_probe(opts)
  local cfg = Config.get()
  if opts.cfg then
    cfg = vim.tbl_deep_extend('force', cfg, opts.cfg)
  end

  local ok, err = guard_local()
  if not ok then
    Util.report_error(err)
    return nil
  end

  local parsed, derr = resolve_dest(cfg, opts.dest)
  if not parsed then
    Util.report_error(derr)
    return nil
  end

  -- explicit password mode: ask BEFORE the first ssh round trip, so the
  -- prompt is the first thing the user sees ("auto" does not prompt here;
  -- its fallback lives in Bootstrap.probe, Ssh.* prompts lazily).
  if Auth.mode(cfg) == 'password' then
    local pw, aerr = Auth.ensure(cfg, parsed)
    if not pw then
      Util.report_error(aerr)
      return nil
    end
  end

  local probe, perr = Bootstrap.probe(cfg, parsed)
  if not probe then
    Util.report_error(perr)
    return nil
  end
  return cfg, parsed, probe
end

---Build the full remote layout for a connect-ish flow.
---@param opts table
---@return table? cfg
---@return table? parsed
---@return table? layout
---@return table? probe
local function prepare(opts)
  local cfg, parsed, probe = prepare_probe(opts)
  if not cfg then
    return nil
  end

  -- a path embedded in the destination ("host:~/proj") is also accepted
  local workspace = opts.workspace or parsed.path or cfg.workspace
  if opts.workspace and parsed.path then
    Util.report_error('destination already contains a workspace path; drop the second argument')
    return nil
  end

  local version, dev, warn = Bootstrap.resolve_version(cfg)
  if warn then
    Util.status(warn)
    Util.log('%s', warn)
  end
  if dev then
    Util.log('installing the nightly build remotely (local nvim is a dev build)')
  end

  local layout, lerr = Layout.build({
    home = probe.home,
    remote_root = cfg.remote_root,
    hostname = Util.os_hostname(),
    nvim_version = version,
    config_hash = Util.config_content_hash(cfg),
    workspace = workspace,
    workspace_profile_name = cfg.workspace_profile,
    nvim_profile_key = opts.nvim_profile or cfg.nvim_profile,
  })
  if not layout then
    Util.report_error(lerr)
    return nil
  end

  Util.log('nvim profile "%s" -> %s', layout.nvim_profile_key, layout.nvim_profile)
  Util.log(
    'workspace profile "%s" -> %s (workspace %s)',
    layout.workspace_profile_key,
    layout.workspace_profile,
    layout.workspace
  )
  return cfg, parsed, layout, probe
end

---Should this connection (re)install the config + plugins?
---
---The nvim profile key already is the config content hash, so `.ready`
---matching the hash means "this exact config + version is installed" and the
---expensive step can be skipped -- that is what makes a NEW workspace reuse
---the plugins of an existing profile.
---@param info table|nil Bootstrap.ensure() result
---@param layout table
---@param opts table|nil { force = boolean }
---@return boolean
function M.needs_bootstrap(info, layout, opts)
  opts = opts or {}
  if opts.force then
    return true
  end
  if not info then
    return true
  end
  return (info.np_ready or '') ~= layout.config_hash
end

---A user-supplied nvim profile key may not exist on the remote. Fall back to
---the content-derived profile with a warning instead of silently installing
---into a directory whose name does not describe its content.
---@param layout table
---@return table? auto_layout
local function fallback_layout(layout)
  return Layout.build({
    home = layout.home,
    remote_root = layout.root,
    hostname = layout.hostname,
    nvim_version = layout.nvim_version,
    config_hash = layout.config_hash,
    workspace = layout.workspace,
    workspace_profile_name = layout.workspace_profile_name,
    nvim_profile_key = 'auto',
  })
end

---Pure decision behind |apply_reuse()| (exported for tests):
---  'own'      bootstrap/refresh this client's own profile (auto key)
---  'reuse'    use an explicitly requested existing profile as-is
---  'fallback' the explicit profile is missing/incomplete -> use the auto key
---@param layout table
---@param info table Bootstrap.ensure() result
---@return 'own'|'reuse'|'fallback'
function M.reuse_action(layout, info)
  if not layout.explicit_nvim_profile then
    return 'own'
  end
  if layout.nvim_profile_key == Layout.auto_nvim_profile_key(layout) then
    return 'own'
  end
  if info and info.np_exists and (info.np_ready or '') ~= '' then
    return 'reuse'
  end
  return 'fallback'
end

---Decide whether an explicitly requested nvim profile can really be reused.
---
---Auto-derived keys are owned by this client: they are bootstrapped from the
---current config content, so the normal readiness rule applies.
---
---An explicit --nvim-profile key is a REUSED, immutable profile: its config is
---whatever was installed when it was created. The current local config must
---NOT be uploaded into it (that would break the "key == content hash"
---invariant). If the requested profile is missing or never finished
---installing, fall back to the auto profile with a warning.
---@param parsed table
---@param layout table
---@param info table Bootstrap.ensure() result (AUTO_* fields are used on fallback)
---@return table layout effective layout
---@return table info effective info
---@return boolean reuse_only true = use the profile as-is, no install
local function apply_reuse(parsed, layout, info)
  local action = M.reuse_action(layout, info)
  if action == 'own' then
    return layout, info, false
  end
  if action == 'reuse' then
    Util.log('reusing nvim profile %s as-is (explicit --nvim-profile)', layout.nvim_profile_key)
    return layout, info, true
  end
  local auto = fallback_layout(layout)
  if not auto then
    return layout, info, false
  end
  Util.notify(
    ('nvim profile %s %s on %s; using the auto profile %s instead'):format(
      layout.nvim_profile_key,
      info.np_exists and 'is incomplete (it never finished installing)' or 'does not exist',
      parsed.dest,
      auto.nvim_profile_key
    ),
    vim.log.levels.WARN
  )
  Util.log('explicit nvim profile unusable; fell back to %s', auto.nvim_profile_key)
  info.np_exists = info.auto_exists
  info.np_ready = info.auto_ready
  return auto, info, false
end

-----------------------------------------------------------------------
-- Public flows
-----------------------------------------------------------------------

---`:SshDevConnect[!] [dest] [workspace]` — full pipeline or fast re-attach.
---@param opts table { dest?, workspace?, force?, reuse_only?, nvim_profile?, cfg? }
function M.connect(opts)
  opts = opts or {}
  Proc.launch(function()
    local cfg, parsed, layout, probe = prepare(opts)
    if not cfg then
      return
    end

    Util.status(('preparing nvim %s on the remote ...'):format(layout.nvim_version))
    local info, ierr = Bootstrap.ensure(cfg, parsed, layout, probe)
    if not info then
      fail(ierr)
    end
    Util.log('remote nvim: %s (%s)', info.bin, info.version_line)

    -- Explicit reuse: an existing profile is used AS-IS (no config upload, no
    -- plugin install). Missing/incomplete explicit profiles fall back to the
    -- auto profile with a warning.
    local reuse_only_profile
    layout, info, reuse_only_profile = apply_reuse(parsed, layout, info)

    -- Fast path: a server is already running for this workspace profile.
    if info.server == 'running' then
      if opts.force then
        Util.status('restarting the remote server ...')
        local kok, kerr = Bootstrap.stop_server(cfg, parsed, layout)
        if not kok then
          Util.notify(kerr, vim.log.levels.WARN)
        end
      else
        if not opts.reuse_only then
          Util.status('server already running — attaching')
        end
        local rport = tonumber((info.addr or ''):match(':(%d+)$'))
        if not rport then
          fail('the remote server is running but its listen address is unknown; run :SshDevConnect! to restart it')
        end
        return run_attach(cfg, parsed, layout, rport)
      end
    elseif opts.reuse_only then
      fail('no remote server is running for this workspace; use :SshDevConnect')
    end

    local bootstrap_needed = (not reuse_only_profile) and M.needs_bootstrap(info, layout, opts)
    if reuse_only_profile and opts.force then
      Util.notify(
        'explicit nvim profile reuse: config sync/install skipped (only the server is restarted)',
        vim.log.levels.WARN
      )
    end

    -- Create/refresh both profiles and their relative links, then the helper.
    local prep, perr = Bootstrap.prepare(cfg, parsed, layout, {
      own = not reuse_only_profile,
      staging = bootstrap_needed,
    })
    if not prep then
      fail(perr)
    end
    local helper, herr = Bootstrap.upload_helper(cfg, parsed, layout)
    if not helper then
      fail(herr)
    end

    -- Cold path: install into the nvim profile only when the content is not
    -- already there. A new workspace with the same config skips this.
    if bootstrap_needed then
      Util.status('uploading config (scp) ...')
      local up, uerr = Bootstrap.upload_config(cfg, parsed, layout)
      if not up then
        fail(uerr)
      end
      Util.status('installing plugins in the nvim profile ...')
      local commit, cerr = Bootstrap.commit_profile(cfg, parsed, layout, { force = opts.force })
      if not commit then
        fail(cerr)
      end
      Util.log(
        'nvim profile %s %s',
        layout.nvim_profile_key,
        commit.installed and 'installed' or 'already ready'
      )
    elseif reuse_only_profile then
      -- apply_reuse() already logged the as-is reuse; nothing else to do
    else
      Util.log(
        'reusing nvim profile %s (config content unchanged, plugins already installed)',
        layout.nvim_profile_key
      )
    end

    -- Start the server.
    local rbase = Util.remote_port(parsed.dest, layout.workspace_profile_key)
    local server, serr
    for attempt = 0, 2 do
      local rport = rbase + attempt
      Util.status(('starting remote server on 127.0.0.1:%d ...'):format(rport))
      server, serr = Bootstrap.start_server(cfg, parsed, layout, rport, opts.restore_session)
      if server then
        break
      end
      Util.log('start attempt failed: %s', tostring(serr))
    end
    if not server then
      fail(serr)
    end

    local rport = tonumber((server.addr or ''):match(':(%d+)$')) or rbase
    run_attach(cfg, parsed, layout, rport)
  end)
end

---`:SshDevInstall [dest] [workspace]` — bootstrap only, no server/attach.
function M.install(opts)
  opts = opts or {}
  Proc.launch(function()
    local cfg, parsed, layout, probe = prepare(opts)
    if not cfg then
      return
    end
    Util.status(('preparing nvim %s on the remote ...'):format(layout.nvim_version))
    local info, ierr = Bootstrap.ensure(cfg, parsed, layout, probe)
    if not info then
      fail(ierr)
    end
    local reuse_only_profile
    layout, info, reuse_only_profile = apply_reuse(parsed, layout, info)
    local bootstrap_needed = (not reuse_only_profile) and M.needs_bootstrap(info, layout, opts)

    local prep, perr = Bootstrap.prepare(cfg, parsed, layout, {
      own = not reuse_only_profile,
      staging = bootstrap_needed,
    })
    if not prep then
      fail(perr)
    end
    local helper, herr = Bootstrap.upload_helper(cfg, parsed, layout)
    if not helper then
      fail(herr)
    end

    if bootstrap_needed then
      Util.status('uploading config (scp) ...')
      local up, uerr = Bootstrap.upload_config(cfg, parsed, layout)
      if not up then
        fail(uerr)
      end
      Util.status('installing plugins in the nvim profile ...')
      local commit, cerr = Bootstrap.commit_profile(cfg, parsed, layout, { force = opts.force })
      if not commit then
        fail(cerr)
      end
    else
      Util.log('nvim profile %s is already installed (reuse only)', layout.nvim_profile_key)
    end

    Util.notify(
      ('nvim profile "%s" is ready — :SshDevConnect to start a server'):format(layout.nvim_profile_key)
    )
  end)
end

---`:SshDevSync [dest] [workspace]` — re-upload config + helper (and reinstall).
function M.sync(opts)
  opts = opts or {}
  Proc.launch(function()
    local cfg, parsed, layout, probe = prepare(opts)
    if not cfg then
      return
    end
    local info, ierr = Bootstrap.ensure(cfg, parsed, layout, probe)
    if not info then
      fail(ierr)
    end
    -- Sync always targets THIS config's own profile: an explicitly reused
    -- profile belongs to some other config content and must not be overwritten.
    if layout.explicit_nvim_profile and layout.nvim_profile_key ~= Layout.auto_nvim_profile_key(layout) then
      local auto_layout = fallback_layout(layout)
      if auto_layout then
        Util.notify(
          ('cannot sync the explicitly reused nvim profile %s; syncing the auto profile %s instead'):format(
            layout.nvim_profile_key,
            auto_layout.nvim_profile_key
          ),
          vim.log.levels.WARN
        )
        layout = auto_layout
        info.np_exists = info.auto_exists
        info.np_ready = info.auto_ready
      end
    end

    local prep, perr = Bootstrap.prepare(cfg, parsed, layout, { own = true, staging = true })
    if not prep then
      fail(perr)
    end
    local helper, herr = Bootstrap.upload_helper(cfg, parsed, layout)
    if not helper then
      fail(herr)
    end
    Util.status('uploading config (scp) ...')
    local up, uerr = Bootstrap.upload_config(cfg, parsed, layout)
    if not up then
      fail(uerr)
    end
    Util.status('installing plugins in the nvim profile ...')
    local commit, cerr = Bootstrap.commit_profile(cfg, parsed, layout, { force = true })
    if not commit then
      fail(cerr)
    end
    Util.notify(
      ('synced nvim profile "%s" (%s) — use :SshDevConnect! to restart the server'):format(
        layout.nvim_profile_key,
        layout.nvim_profile
      )
    )
  end)
end

---`:SshDevForward [dest] [workspace]` — edit this workspace's port
---forwards: the `forward.txt` of the workspace profile, fetched into a
---local buffer; saving that buffer re-uploads it and (re)starts the
---`ssh -N -L` forwards it describes (see |sshdev-forwards|).
---
---Without arguments the ACTIVE session's workspace profile is used (no
---extra round trip); with [dest] [workspace] it is resolved like the
---other commands. `--nvim-profile` is accepted but irrelevant: the
---forward file lives in the workspace profile, which does not depend on
---the nvim profile.
---@param opts table { dest?, workspace?, nvim_profile?, cfg? }
function M.forward(opts)
  opts = opts or {}
  Proc.launch(function()
    local ok, err = guard_local()
    if not ok then
      return Util.report_error(err)
    end

    -- fast path: the active session already knows the workspace profile
    local info = state.info
    if not opts.dest and not opts.workspace and info and info.remote_root then
      local cfg = Config.get()
      if opts.cfg then
        cfg = vim.tbl_deep_extend('force', cfg, opts.cfg)
      end
      local parsed = Util.parse_dest(info.dest)
      if not parsed then
        return Util.report_error(('the active session destination "%s" is invalid'):format(info.dest))
      end
      parsed.port = info.port
      Util.log('forward: active session profile "%s"', info.workspace_profile_key)
      return Forward.open({
        cfg = cfg,
        parsed = parsed,
        remote_root = info.remote_root,
        workspace = info.workspace,
        workspace_profile = info.workspace_profile,
        workspace_profile_key = info.workspace_profile_key,
      })
    end

    if not opts.dest and not Config.get().host then
      return Util.notify(
        'no active sshdev session and no destination given: connect first '
          .. '(:SshDevConnect) or pass [dest] [workspace] to :SshDevForward',
        vim.log.levels.ERROR
      )
    end

    -- resolve exactly like the other commands (probe + layout)
    local cfg, parsed, layout = prepare(opts)
    if not cfg then
      return
    end
    Util.log('forward: workspace profile "%s" for %s', layout.workspace_profile_key, layout.workspace)
    Forward.open({
      cfg = cfg,
      parsed = parsed,
      remote_root = layout.root,
      workspace = layout.workspace,
      workspace_profile = layout.workspace_profile,
      workspace_profile_key = layout.workspace_profile_key,
    })
  end)
end

---`:SshDevStop` — stop the remote server (saves session.vim) + tunnel.
function M.stop()
  Proc.launch(function()
    local cfg = Config.get()
    if state.tunnel then
      state.tunnel.kill()
      state.tunnel = nil
    end
    Forward.kill()
    local info = state.info
    if not info then
      return Util.notify('no active sshdev session to stop (local state only)')
    end
    local parsed = Util.parse_dest(info.dest)
    if parsed then
      parsed.port = info.port
    end
    local ok, err = Bootstrap.stop_server(cfg, parsed, { workspace_profile = info.workspace_profile })
    if not ok then
      fail(err)
    end
    state.info = nil
    Util.notify(('remote server for "%s" stopped (session saved)'):format(info.workspace))
  end)
end

---Auto nvim profile key for the current local config (for :SshDevStatus/health).
---@param cfg table
---@return string? key
---@return string? err
function M.auto_nvim_profile_key(cfg)
  local Keys = require('sshdev.keys')
  local version, _, _ = Bootstrap.resolve_version(cfg)
  local hash = Util.config_content_hash(cfg)
  local hash8 = Keys.config_hash8(hash)
  if not hash8 then
    return nil, 'cannot hash the local config'
  end
  return Keys.nvim_profile_key(Util.os_hostname(), version, hash8)
end

---`:SshDevStatus` — session, tunnel, profiles, remote server, history.
function M.status()
  Proc.launch(function()
    local cfg = Config.get()
    local lines = {}
    local tag, dev = Util.nvim_version_tag()
    lines[#lines + 1] = ('local nvim: %s%s'):format(tag, dev and ' (dev build)' or '')
    lines[#lines + 1] = ('client host: %s'):format(Util.os_hostname())
    local auto_key = M.auto_nvim_profile_key(cfg)
    if auto_key then
      lines[#lines + 1] = ('auto nvim profile: %s'):format(auto_key)
    end

    if state.info then
      local info = state.info
      local up = (state.tunnel and state.tunnel.alive) or state.attached
      lines[#lines + 1] = ('session: %s'):format(info.dest)
      lines[#lines + 1] = ('workspace: %s'):format(info.workspace)
      lines[#lines + 1] = ('workspace profile: %s'):format(info.workspace_profile)
      lines[#lines + 1] = ('nvim profile: %s'):format(info.nvim_profile)
      lines[#lines + 1] = ('tunnel: %s (127.0.0.1:%d -> 127.0.0.1:%d)'):format(
        up and 'up' or 'down',
        info.lport or -1,
        info.rport or -1
      )
      local parsed = Util.parse_dest(info.dest)
      if parsed then
        parsed.port = info.port
      end
      local st = Bootstrap.server_status(cfg, parsed, {
        workspace_profile = info.workspace_profile,
        nvim_profile = info.nvim_profile,
      })
      if st and st.running then
        lines[#lines + 1] = ('remote server: running (pid %s, %s)'):format(st.pid or '?', st.addr or '?')
        lines[#lines + 1] = ('saved session: %s'):format(st.has_session and 'yes' or 'no')
      else
        lines[#lines + 1] = 'remote server: not running'
      end
    else
      lines[#lines + 1] = 'no active local session (remote servers may still be running)'
    end

    local fwd = Forward.status_line()
    if fwd then
      lines[#lines + 1] = fwd
    end

    local entries = History.list()
    if #entries > 0 then
      lines[#lines + 1] = ('remembered workspaces: %d (:SshDevHistory to pick one)'):format(#entries)
    end

    for _, l in ipairs(lines) do
      Util.log('%s', l)
    end
    Util.notify(table.concat(lines, '\n'))
  end)
end

---List the nvim profiles that exist on the remote for this client host.
---@param opts table|nil { dest = string }
function M.profiles(opts)
  opts = opts or {}
  Proc.launch(function()
    local cfg, parsed, probe = prepare_probe(opts)
    if not cfg then
      return
    end
    local root = Util.remote_root_abs(cfg, probe.home)
    local list, err = Bootstrap.list_nvim_profiles(cfg, parsed, root)
    if not list then
      fail(err)
    end
    History.cache_nvim_profiles(
      parsed.dest,
      vim.tbl_map(function(p)
        return p.key
      end, list)
    )

    local lines = {
      ('nvim profiles on %s (client host %s):'):format(Util.format_dest(parsed), Util.os_hostname()),
    }
    if #list == 0 then
      lines[#lines + 1] = '  (none yet — :SshDevConnect installs one)'
    end
    for _, p in ipairs(list) do
      local used = ''
      if (p.workspace_count or 0) > 0 then
        used = ('  (%d workspace(s))'):format(p.workspace_count)
      end
      lines[#lines + 1] = ('  %s  %s  %s%s'):format(
        p.key,
        tostring(p.version or '?'),
        p.ready_hash and 'ready' or 'incomplete',
        used
      )
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'reuse one with: :SshDevConnect <dest> <workspace> --nvim-profile=<key>'
    for _, l in ipairs(lines) do
      Util.log('%s', l)
    end
    Util.notify(table.concat(lines, '\n'))
  end)
end

---Open the connection picker (`:SshDevConnect` with no arguments).
---@param opts table|nil
function M.pick(opts)
  opts = opts or {}
  local cfg = Config.get()
  if opts.cfg then
    cfg = vim.tbl_deep_extend('force', cfg, opts.cfg)
  end
  local Picker = require('sshdev.picker')
  Picker.select(cfg, function(entry)
    if not entry then
      return
    end
    M.connect({
      dest = entry.dest,
      workspace = entry.workspace,
      nvim_profile = entry.nvim_profile_key,
      force = opts.force,
      cfg = opts.cfg,
    })
  end)
end

---Open the workspace history picker (`:SshDevHistory`): scans the remote
---workspace profiles of this client host (user isolation) and reuses their
---nvim profile key.
---@param opts table|nil { dest = string }
function M.pick_history(opts)
  opts = opts or {}
  local cfg = Config.get()
  if opts.cfg then
    cfg = vim.tbl_deep_extend('force', cfg, opts.cfg)
  end
  local Picker = require('sshdev.picker')
  Proc.launch(function()
    Picker.select_history(cfg, function(entry)
      if not entry then
        return
      end
      M.connect({
        dest = entry.dest,
        workspace = entry.workspace,
        nvim_profile = entry.nvim_profile_key,
        cfg = opts.cfg,
      })
    end, { dest = opts.dest })
  end)
end

---Kill the local tunnel handle (VimLeavePre), except right after a
---successful :connect where the local server may stop itself. The user
---forwards share the tunnel's lifecycle.
function M.teardown_local()
  if state.attached then
    return
  end
  if state.tunnel then
    state.tunnel.kill()
    state.tunnel = nil
  end
  Forward.kill()
end

---Introspection for tests.
function M.state()
  return {
    info = state.info and vim.deepcopy(state.info) or nil,
    tunnel_alive = state.tunnel and state.tunnel.alive or false,
    forward = Forward.applied(),
  }
end

return M
