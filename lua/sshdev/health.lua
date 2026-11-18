--- :checkhealth sshdev — verifies the local environment and (optionally,
--- when a destination is configured) that the remote side is usable.

local M = {}

function M.check()
  local Util = require('sshdev.util')
  local Config = require('sshdev.config')

  vim.health.start('sshdev.nvim')

  -- 1. local nvim version: :connect / :detach landed in 0.11
  if Util.nvim_at_least(0, 11) then
    vim.health.ok(('Neovim %s (>= 0.11: :connect/:detach available)'):format(tostring(vim.version())))
  else
    vim.health.error(('Neovim %s is too old: sshdev.nvim needs 0.11+ (found :connect/:detach missing)'):format(tostring(vim.version())))
  end
  if vim.fn.exists(':connect') == 2 and vim.fn.exists(':detach') == 2 then
    vim.health.ok(':connect and :detach commands are available')
  else
    vim.health.error(':connect/:detach are missing from this Neovim build')
  end

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
    vim.health.ok(('destinations configured: %s'):format(table.concat(vim.tbl_extend('keep', remotes, cfg.host and { cfg.host } or {}), ', ')))
  else
    vim.health.info('no destination configured yet: pass one to :SSHdevConnect or set setup({ host = "user@host" })')
  end
  if cfg.proxy then
    vim.health.ok(('download proxy: %s (applies to nvim downloads ON THE REMOTE)'):format(cfg.proxy))
  end
  if cfg.nvim_version ~= 'auto' then
    vim.health.info(('nvim_version pinned to %q'):format(cfg.nvim_version))
  end

  -- 4. remote reachability (bounded, synchronous)
  local dest = cfg.host or (next(cfg.remotes) and cfg.remotes[next(cfg.remotes)] or nil)
  if dest then
    local parsed, err = Util.parse_dest(dest)
    if parsed then
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
    else
      vim.health.error(('bad destination %q: %s'):format(tostring(dest), tostring(err)))
    end
  end
end

return M
