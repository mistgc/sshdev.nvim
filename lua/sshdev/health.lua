--- :checkhealth sshdev — verifies the local environment and (optionally,
--- when a destination is configured) that the remote side is usable.

local M = {}

function M.check()
  local Util = require('sshdev.util')
  local Config = require('sshdev.config')

  vim.health.start('sshdev.nvim')

  -- 1. local nvim capabilities.
  --    Verified against real binaries: :detach exists since 0.11, while
  --    :connect (and --remote-ui) only exist since 0.12.
  local has_connect = vim.fn.exists(':connect') == 2
  local has_detach = vim.fn.exists(':detach') == 2
  if Util.nvim_at_least(0, 12) then
    vim.health.ok(('Neovim %s (>= 0.12: :connect and :detach available)'):format(tostring(vim.version())))
  else
    vim.health.error(('Neovim %s is too old: sshdev.nvim needs 0.12+ '
      .. '(:connect was added in 0.12; 0.11 only has :detach)'):format(tostring(vim.version())))
  end
  vim.health.info((':connect: %s   :detach: %s'):format(
    has_connect and 'yes' or 'no',
    has_detach and 'yes' or 'no'
  ))
  local Session = require('sshdev.session')
  vim.health.info(('current UI: %s -> attach strategy: %s'):format(
    Session.ui_kind(),
    Session.attach_strategy(Config.get().attach, Session.ui_kind())
  ))

  -- 2. local tools
  local cfg = Config.get()
  for _, bin in ipairs({ cfg.ssh_bin, cfg.scp_bin }) do
    if vim.fn.executable(bin) == 1 then
      vim.health.ok(('%s is executable'):format(bin))
    else
      vim.health.error(('%s is not executable / not in PATH'):format(bin))
    end
  end

  if vim.fn.has('win32') == 1 then
    vim.health.info('Windows local host: using Win32-OpenSSH (ssh.exe/scp.exe); OpenSSH >= 7.6 required')
  end

  -- 3. configuration sanity
  local remotes = vim.tbl_keys(cfg.remotes or {})
  if cfg.host or #remotes > 0 then
    vim.health.ok(
      ('destinations configured: %s'):format(
        table.concat(vim.tbl_extend('keep', remotes, cfg.host and { cfg.host } or {}), ', ')
      )
    )
  else
    vim.health.info('no destination configured yet: :SSHdevConnect opens the picker, or set setup({ host = "user@host" })')
  end
  if cfg.proxy then
    vim.health.ok(('download proxy: %s (applies to nvim downloads ON THE REMOTE)'):format(cfg.proxy))
  end
  if cfg.nvim_version ~= 'auto' then
    vim.health.info(('nvim_version pinned to %q'):format(cfg.nvim_version))
  end
  vim.health.info(('local hostname namespace: %s'):format(Util.os_hostname()))
  local auto_key = require('sshdev.session').auto_nvim_profile_key(cfg)
  if auto_key then
    vim.health.info(('auto nvim profile (reused by new workspaces): %s'):format(auto_key))
  else
    vim.health.warn('cannot derive the auto nvim profile key for the current config')
  end
  if cfg.nvim_profile and cfg.nvim_profile ~= 'auto' then
    vim.health.info(('nvim_profile pinned to %s'):format(cfg.nvim_profile))
  end
  vim.health.ok(('session persistence: %s'):format(cfg.session and 'on (per-workspace session.vim)' or 'off'))
  vim.health.info(('attach strategy: %s'):format(cfg.attach))
  vim.health.info(('bootstrap lock timeout: %ss'):format(cfg.timeouts.lock))

  -- password-auth mode (askpass): capability + helper checks
  if cfg.auth == 'password' then
    local Auth = require('sshdev.auth')
    vim.health.info('auth: password (askpass helper + in-memory cache; never written to disk)')
    local vres = vim.system({ cfg.ssh_bin, '-V' }, { timeout = 5000, text = true }):wait()
    local vline = (vres.stderr or '') .. (vres.stdout or '')
    local maj, minr = vline:match('OpenSSH[_%w]*v?(%d+)%.(%d+)')
    if maj then
      if tonumber(maj) > 8 or (tonumber(maj) == 8 and tonumber(minr) >= 4) then
        vim.health.ok(('ssh client %s.%s supports SSH_ASKPASS_REQUIRE=force'):format(maj, minr))
      else
        vim.health.warn(('ssh client %s.%s predates SSH_ASKPASS_REQUIRE (>= 8.4); '
          .. 'password auth may not work'):format(maj, minr))
      end
    else
      vim.health.warn('cannot determine the ssh client version (password auth needs >= 8.4)')
    end
    local helper, herr = Auth.helper_path()
    if helper then
      vim.health.ok(('askpass helper: %s'):format(helper))
    else
      vim.health.error(('cannot create the askpass helper: %s'):format(tostring(herr)))
    end
  else
    vim.health.info('auth: auto (key / ssh-agent; no password prompts)')
  end

  local hist = require('sshdev.history').list()
  if #hist > 0 then
    vim.health.ok(('%d remembered workspace(s)'):format(#hist))
  end

  -- 4. remote reachability (bounded, synchronous)
  local dest = cfg.host or (next(cfg.remotes) and cfg.remotes[next(cfg.remotes)] or nil)
  if dest then
    local parsed, err = Util.parse_dest(dest)
    if parsed then
      if cfg.auth == 'password' then
        -- BatchMode disables password auth entirely; use the cached
        -- password (if any) through the askpass environment instead.
        local Auth = require('sshdev.auth')
        local env = Auth.env(cfg, parsed, { no_prompt = true })
        if not env then
          vim.health.info(('password auth: no cached password for %s yet -- the live ssh test '
            .. 'is skipped (run :SSHdevConnect once to enter it)'):format(parsed.dest))
        else
          local sysres = vim
            .system(
              { cfg.ssh_bin, '-o', 'ConnectTimeout=10', '--', parsed.dest, 'true' },
              { timeout = 15000, text = true, env = env }
            )
            :wait()
          if sysres.code == 0 then
            vim.health.ok(('ssh %s works (password auth, cached)'):format(parsed.dest))
          else
            vim.health.error(('ssh %s failed (exit %s): %s'):format(
              parsed.dest,
              sysres.code,
              Util.tail(sysres.stderr, 3)
            ))
          end
        end
      else
        local args = { cfg.ssh_bin, '-o', 'ConnectTimeout=10', '-o', 'BatchMode=yes', '--', parsed.dest, 'true' }
        local sysres = vim.system(args, { timeout = 15000, text = true }):wait()
        if sysres.code == 0 then
          vim.health.ok(('ssh %s works'):format(parsed.dest))
        else
          vim.health.error(('ssh %s failed (exit %s): %s'):format(
            parsed.dest,
            sysres.code,
            Util.tail(sysres.stderr, 3)
          ))
        end
      end
    else
      vim.health.error(('bad destination %q: %s'):format(tostring(dest), tostring(err)))
    end
  end
end

return M
