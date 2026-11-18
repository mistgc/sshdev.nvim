-- sshdev.nvim remote-server shim.
--
-- This file is copied to the remote host as
--   ~/.sshdev.nvim/<workspace>/shim.lua
-- and loaded by the remote server with
--   nvim --headless --listen 127.0.0.1:<port> -c 'luafile <shim>'
-- BEFORE any UI attaches (the server starts headless and waits).
--
-- It is fully self-contained: it must not require any plugin or runtime
-- module, because the uploaded user config may not include sshdev.nvim.
--
-- Everything below only activates when Neovim was started by sshdev
-- (SSHDEV_REMOTE=1), so sourcing this file in any other context is a no-op.

if vim.env.SSHDEV_REMOTE ~= '1' then
  return
end

local WS = vim.env.SSHDEV_WORKSPACE or '?'
local HIJACK = vim.env.SSHDEV_HIJACK ~= '0'

local function pcmd(cmd)
  pcall(vim.cmd, cmd)
end

-- quit word -> replacement command line.
-- Plain quits become :Detach; writes-then-quits write everything first.
-- NOTE: replacements must be single words: the :cnoreabbrev command line
-- splits at "|" (it is not bar-safe), so the writes-then-quit family is
-- redirected to the :DetachW user command defined below.
local HIJACK_MAP = {
  q = 'Detach',
  quit = 'Detach',
  qa = 'DetachW',
  qall = 'DetachW',
  quitall = 'DetachW',
  wq = 'DetachW',
  wqa = 'DetachW',
  wqall = 'DetachW',
  x = 'DetachW',
  xa = 'DetachW',
  xall = 'DetachW',
  xit = 'DetachW',
  exit = 'DetachW',
}

-- Rewrite ":q<CR>" etc. into ":detach" while this server is being driven
-- by a remote UI. The <expr> guard only fires when the typed command line
-- consists of exactly the quit word, so ":s/q/x/", ":echo q" etc. pass
-- through untouched.
local function apply_hijack()
  if not HIJACK then
    return
  end
  for lhs, rhs in pairs(HIJACK_MAP) do
    pcmd(('cnoreabbrev <expr> %s getcmdtype() ==# ":" && getcmdline() ==# "%s" ? "%s" : "%s"'):format(lhs, lhs, rhs, lhs))
  end
  pcmd('nnoremap <silent> ZQ :Detach<CR>')
  pcmd('nnoremap <silent> ZZ :DetachW<CR>')
end

pcall(function()
  ----------------------------------------------------------------------
  -- 1. Hijack the quit family and replace it with :detach.
  --
  --    While a UI is attached, typed ex commands are executed by THIS
  --    server, so the hijack must live here (not on the local client).
  --
  --    Escape hatches when you really want to quit the remote server:
  --    :SSHdevQuit / :SSHdevStop  (also :cq, which we do not map).
  ----------------------------------------------------------------------
  apply_hijack()

  ----------------------------------------------------------------------
  -- 2. User commands: a :Detach alias (accepts "!" from ":q!" expansion),
  --    :DetachW (write all, then detach), and a REAL quit escape hatch.
  ----------------------------------------------------------------------
  vim.api.nvim_create_user_command('Detach', function()
    pcmd('detach')
  end, { bang = true, bar = true, desc = 'sshdev: detach this UI; the remote server keeps running' })

  vim.api.nvim_create_user_command('DetachW', function()
    pcmd('silent! wall')
    pcmd('detach')
  end, { bang = true, bar = true, desc = 'sshdev: write all buffers, then detach' })

  vim.api.nvim_create_user_command('SSHdevDetach', function()
    pcmd('detach')
  end, { bang = true, bar = true, desc = 'sshdev: same as :Detach' })

  for _, name in ipairs({ 'SSHdevQuit', 'SSHdevStop' }) do
    vim.api.nvim_create_user_command(name, function(o)
      pcmd(o.bang and 'qall!' or 'qall')
    end, { bang = true, bar = true, desc = 'sshdev: really quit this remote server' })
  end

  ----------------------------------------------------------------------
  -- 3. Survive accidental disconnects.
  --
  --    ":detach!" marks the current UI detachable: if the SSH connection
  --    drops (network flap, laptop sleep), the server keeps running and
  --    can be re-attached later. nvim_chan_set() is used when available
  --    (more precise); the command is the portable fallback. See :h :detach!
  ----------------------------------------------------------------------
  vim.api.nvim_create_autocmd('UIEnter', {
    callback = function()
      pcmd('silent! detach!')
      local chan = vim.v.event and vim.v.event.chan
      if chan and vim.api.nvim_chan_set then
        pcall(vim.api.nvim_chan_set, chan, { detach = true })
      end
    end,
    desc = 'sshdev: mark attaching UIs as detachable (server survives SSH drops)',
  })

  ----------------------------------------------------------------------
  -- 4. A friendly reminder once the local UI attaches.
  ----------------------------------------------------------------------
  vim.schedule(function()
    vim.notify(
      ('sshdev: remote workspace "%s" — :q is hijacked to :detach. '
        .. 'Use :SSHdevQuit or :cq to really quit the server.'):format(WS),
      vim.log.levels.INFO
    )
  end)
end)

-- Re-apply the quit hijack after the user config is sourced (user configs
-- may define their own cnoreabbrevs; the last definition wins).
pcall(function()
  if HIJACK then
    vim.api.nvim_create_autocmd('VimEnter', {
      callback = apply_hijack,
      desc = 'sshdev: re-apply the quit hijack after user config',
    })
  end
end)
