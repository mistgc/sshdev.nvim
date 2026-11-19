-- sshdev.nvim remote server helper: session persistence.
--
-- Copied to the remote host as
--   ~/.sshdev.nvim/workspace-profiles/--<host>--<ws-path>--/session.lua
-- and loaded by the remote server with
--   nvim --headless --listen 127.0.0.1:<port> -c 'luafile <ws profile>/session.lua'
--
-- Environment set by the start script:
--   SSHDEV_REMOTE=1
--   SSHDEV_WORKSPACE_PROFILE=<absolute workspace profile dir>
--   SSHDEV_NVIM_PROFILE=<absolute nvim profile dir>
--   SSHDEV_SESSION=<absolute session.vim path, or empty>
--   SSHDEV_RESTORE=1|0
--
-- Responsibilities (deliberately minimal -- there is NO quit hijacking):
--   1. restore session.vim when the server (re)starts, if configured
--   2. save session.vim when the server exits, so the next :SSHdevConnect
--      brings the user back to the same buffers/windows/layout
--
-- Self-contained: it must not require any plugin (the uploaded config may
-- not include sshdev.nvim).

if vim.env.SSHDEV_REMOTE ~= '1' then
  return
end

local session_path = vim.env.SSHDEV_SESSION or ''
local restore = vim.env.SSHDEV_RESTORE ~= '0'
-- SSHDEV_PROFILE is the pre-refactor name; keep reading it for one upgrade.
local workspace_profile = vim.env.SSHDEV_WORKSPACE_PROFILE or vim.env.SSHDEV_PROFILE or ''
local nvim_profile = vim.env.SSHDEV_NVIM_PROFILE or ''

local function esc(p)
  return vim.fn.fnameescape(p)
end

local restored = false

---Restore the saved session once the user config finished loading.
local function restore_session()
  if restored or not restore or session_path == '' then
    return
  end
  restored = true
  if vim.fn.filereadable(session_path) == 1 then
    local ok = pcall(vim.cmd, 'silent! source ' .. esc(session_path))
    if ok then
      pcall(vim.api.nvim_echo, {
        { ('sshdev: session restored from %s'):format(session_path), 'None' },
      }, false, {})
    else
      pcall(vim.notify, 'sshdev: could not restore ' .. session_path, vim.log.levels.WARN)
    end
  end
end

vim.api.nvim_create_autocmd('VimEnter', {
  callback = restore_session,
  desc = 'sshdev: restore the saved remote session',
})

---Persist the session so the next connection starts where this one ended.
local function save_session()
  if session_path == '' then
    return
  end
  local dir = vim.fs.dirname(session_path)
  if dir and vim.fn.isdirectory(dir) == 0 then
    pcall(vim.fn.mkdir, dir, 'p')
  end
  -- mksession! writes the file even if it already exists
  pcall(vim.cmd, 'silent! mksession! ' .. esc(session_path))
end

-- VimLeavePre covers :q, :wq, :cquit (partially) and SIGTERM (our stop
-- script). SIGKILL cannot be handled; nothing survives that.
vim.api.nvim_create_autocmd('VimLeavePre', {
  callback = save_session,
  desc = 'sshdev: save the session for the next connection',
})

-- Snapshot on focus loss too, so a crash or reboot loses little.
vim.api.nvim_create_autocmd({ 'FocusLost', 'VimSuspend' }, {
  callback = function()
    vim.schedule(save_session)
  end,
  desc = 'sshdev: snapshot the session',
})

if workspace_profile ~= '' then
  local label = ('sshdev: workspace profile %s'):format(workspace_profile)
  if nvim_profile ~= '' then
    label = label .. (' (nvim profile %s)'):format(nvim_profile)
  end
  pcall(vim.api.nvim_echo, { { label, 'None' } }, false, {})
end
