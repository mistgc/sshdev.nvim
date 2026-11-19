--- Pickers for sshdev.nvim.
---
--- Two different flows:
---
---   * `select()`          : connection picker (`:SSHdevConnect` with no
---                           arguments). Local history + "new connection";
---                           for a new connection it lists the nvim profiles
---                           on the remote so an existing profile can be
---                           reused for the new workspace.
---   * `select_history()`  : workspace picker (`:SSHdevHistory`). Scans ALL
---                           workspace profiles on the remote that belong to
---                           THIS client hostname (user isolation), merges the
---                           local history for recency/counts and lets the
---                           user reconnect, reusing the workspace's nvim
---                           profile key.
---
--- Telescope is optional; |vim.ui.select()| is the fallback.

local Bootstrap = require('sshdev.bootstrap')
local History = require('sshdev.history')
local Proc = require('sshdev.proc')
local Util = require('sshdev.util')

local M = {}

---Is telescope available and loadable?
---@return boolean
function M.has_telescope()
  return pcall(require, 'telescope')
end

-----------------------------------------------------------------------
-- Rendering
-----------------------------------------------------------------------

---Telescope picker over pre-built items: { display, kind, entry? }.
---@param title string
---@param items table[]
---@param on_choice fun(item: table|nil)
---@param opts table|nil { forget = fun(item) }
local function pick_with_telescope(title, items, on_choice, opts)
  local ok, err = pcall(function()
    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')

    pickers
      .new({}, {
        prompt_title = title,
        finder = finders.new_table({
          results = items,
          entry_maker = function(item)
            return { value = item, display = item.display, ordinal = item.display }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local sel = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            on_choice(sel and sel.value or nil)
          end)
          if opts and opts.forget then
            vim.keymap.set('i', '<C-d>', function()
              local sel = action_state.get_selected_entry()
              if sel and sel.value then
                actions.close(prompt_bufnr)
                opts.forget(sel.value)
              end
            end, { buffer = prompt_bufnr })
          end
          return true
        end,
      })
      :find()
  end)
  if not ok then
    Util.log('telescope picker failed: %s', tostring(err))
    on_choice(nil)
  end
end

---Pick one item: telescope when installed, |vim.ui.select()| otherwise.
---@param title string
---@param items table[] items carry a `display` string
---@param on_choice fun(item: table|nil)
---@param opts table|nil { forget = fun(item) }
function M.choose(title, items, on_choice, opts)
  if M.has_telescope() then
    return pick_with_telescope(title, items, on_choice, opts)
  end
  vim.ui.select(items, {
    prompt = title,
    format_item = function(item)
      return item.display
    end,
  }, function(item)
    on_choice(item)
  end)
end

-----------------------------------------------------------------------
-- Destinations
-----------------------------------------------------------------------

---Resolve the destination for the history picker without user input.
---@param cfg table
---@param dest string|nil explicit argument
---@return string? dest
function M.resolve_history_dest(cfg, dest)
  if dest and dest ~= '' then
    return dest
  end
  if cfg.host and cfg.host ~= '' then
    return cfg.host
  end
  local names = vim.tbl_keys(cfg.remotes or {})
  if #names == 1 then
    return cfg.remotes[names[1]]
  end
  return nil
end

---Pick (or type) a destination.
---@param cfg table
---@param on_done fun(dest: string|nil)
function M.prompt_dest(cfg, on_done)
  local items = {}
  local seen = {}
  local function add(dest, label)
    if type(dest) ~= 'string' or dest == '' then
      return
    end
    local base = History.dest_base(dest)
    if seen[base] then
      return
    end
    seen[base] = true
    items[#items + 1] = {
      kind = 'dest',
      dest = dest,
      display = label and ('%s  (%s)'):format(dest, label) or dest,
    }
  end
  add(cfg.host, 'default')
  for _, name in ipairs(vim.tbl_keys(cfg.remotes or {})) do
    add(cfg.remotes[name], name)
  end
  for _, e in ipairs(History.list()) do
    add(e.dest, nil)
  end
  items[#items + 1] = { kind = 'input', display = '＋ enter destination …' }

  if #items == 1 then
    -- nothing remembered: just ask for the destination
    vim.ui.input({ prompt = 'ssh destination ([user@]host[:port]): ', default = cfg.host or '' }, function(dest)
      on_done(dest ~= '' and dest or nil)
    end)
    return
  end

  vim.ui.select(items, {
    prompt = 'sshdev destination',
    format_item = function(item)
      return item.display
    end,
  }, function(item)
    if not item then
      return on_done(nil)
    end
    if item.kind == 'dest' then
      return on_done(item.dest)
    end
    vim.ui.input({ prompt = 'ssh destination ([user@]host[:port]): ', default = cfg.host or '' }, function(dest)
      on_done(dest ~= '' and dest or nil)
    end)
  end)
end

-----------------------------------------------------------------------
-- Connection picker (:SSHdevConnect with no arguments)
-----------------------------------------------------------------------

---Connection list: local history entries + a "new connection" row.
---@param entries table[] History.list() result
---@return table[]
function M.connection_items(entries)
  local items = {}
  for _, e in ipairs(entries or {}) do
    items[#items + 1] = { kind = 'history', entry = e, display = History.display(e) }
  end
  items[#items + 1] = { kind = 'new', display = '＋ new connection …' }
  return items
end

---Ask for destination + workspace of a new connection.
---@param cfg table
---@param on_done fun(dest: string|nil, workspace: string|nil)
function M.prompt_new(cfg, on_done)
  vim.ui.input({ prompt = 'ssh destination ([user@]host[:port]): ', default = cfg.host or '' }, function(dest)
    if not dest or dest == '' then
      return on_done(nil)
    end
    local parsed, derr = Util.parse_dest(dest)
    if not parsed then
      return Util.report_error(derr)
    end
    -- "user@host:~/proj" already carries the workspace
    if parsed.path and parsed.path ~= '' then
      return on_done(dest, nil)
    end
    vim.ui.input({ prompt = 'remote workspace dir (~ for remote $HOME): ', default = cfg.workspace or '~' }, function(ws)
      if ws == nil then
        return on_done(nil)
      end
      on_done(dest, ws ~= '' and ws or nil)
    end)
  end)
end

---Ask which nvim profile to use for a new workspace: the auto profile
---(derived from the current config content) or an existing remote profile.
---@param profiles table[] Bootstrap.list_nvim_profiles() result
---@param on_done fun(key: string|nil) nil = auto
function M.prompt_nvim_profile(profiles, on_done)
  if not profiles or #profiles == 0 then
    return on_done(nil)
  end
  local items = {
    {
      kind = 'auto',
      display = 'auto — use the current config (upload it only if needed)',
    },
  }
  for _, p in ipairs(profiles) do
    local state = p.ready_hash and 'ready' or 'not installed yet'
    local extra = ''
    if (p.workspace_count or 0) > 0 then
      extra = (' — %d workspace(s)'):format(p.workspace_count)
    end
    items[#items + 1] = {
      kind = 'reuse',
      key = p.key,
      profile = p,
      display = ('%s  (%s, %s)%s'):format(p.key, tostring(p.version or '?'), state, extra),
    }
  end
  M.choose('sshdev nvim profile', items, function(item)
    if not item or item.kind == 'auto' then
      return on_done(nil)
    end
    on_done(item.key)
  end)
end

---Finish a "new connection" by offering the remote nvim profiles for reuse.
---Runs its own flow: it needs one ssh round trip to list the profiles.
---@param cfg table
---@param dest string
---@param workspace string|nil
---@param on_choice fun(entry: table|nil)
local function new_connection_choice(cfg, dest, workspace, on_choice)
  Proc.launch(function()
    local profiles = {}
    local parsed, derr = Util.parse_dest(dest)
    if not parsed then
      Util.notify('cannot parse destination: ' .. tostring(derr), vim.log.levels.WARN)
    else
      local probe, perr = Bootstrap.probe(cfg, parsed)
      if not probe then
        Util.notify('could not list nvim profiles: ' .. tostring(perr), vim.log.levels.WARN)
      else
        local root = Util.remote_root_abs(cfg, probe.home)
        local list, lerr = Bootstrap.list_nvim_profiles(cfg, parsed, root)
        if list then
          profiles = list
          History.cache_nvim_profiles(dest, vim.tbl_map(function(p)
            return p.key
          end, list))
        else
          Util.notify('could not list nvim profiles: ' .. tostring(lerr), vim.log.levels.WARN)
        end
      end
    end
    M.prompt_nvim_profile(profiles, function(key)
      on_choice({ dest = dest, workspace = workspace, nvim_profile_key = key })
    end)
  end)
end

---Open the connection picker.
---@param cfg table
---@param on_choice fun(entry: table|nil) entry = { dest, workspace?, nvim_profile_key? }
function M.select(cfg, on_choice)
  local items = M.connection_items(History.list())
  M.choose('sshdev connections', items, function(item)
    if not item then
      return on_choice(nil)
    end
    if item.kind == 'history' then
      local e = item.entry
      return on_choice({
        dest = e.dest,
        workspace = e.workspace,
        nvim_profile_key = e.nvim_profile_key,
      })
    end
    M.prompt_new(cfg, function(dest, workspace)
      if not dest then
        return on_choice(nil)
      end
      new_connection_choice(cfg, dest, workspace, on_choice)
    end)
  end, {
    forget = function(picked)
      if picked.kind == 'history' and picked.entry then
        History.remove(picked.entry)
        Util.notify('[sshdev] removed ' .. History.format(picked.entry))
      end
    end,
  })
end

-----------------------------------------------------------------------
-- Workspace history picker (:SSHdevHistory)
-----------------------------------------------------------------------

---Items for the history picker: merged remote + local workspaces + "new".
---Pure with respect to the network (the caller supplies the remote scan), so
---it is unit-testable.
---@param cfg table
---@param dest string
---@param remote_entries table[] parse_workspace_list() result
---@return table[]
function M.history_items(cfg, dest, remote_entries)
  local merged = History.merge_workspaces(
    History.list_for(dest),
    remote_entries or {},
    dest,
    Util.os_hostname()
  )
  local items = {}
  for _, e in ipairs(merged) do
    items[#items + 1] = { kind = 'workspace', entry = e, display = History.display(e) }
  end
  if #items == 0 then
    return items
  end
  items[#items + 1] = { kind = 'new', display = '＋ new workspace …' }
  return items
end

---Open the workspace history picker. Scans the remote for workspace profiles
---belonging to THIS client hostname, so several client machines sharing one
---remote account never see each other's workspaces.
---
---Must run inside a flow (it performs ssh round trips). When no destination is
---known it asks for one and continues in a fresh flow.
---@param cfg table
---@param on_choice fun(entry: table|nil)
---@param opts table|nil { dest = string }
function M.select_history(cfg, on_choice, opts)
  opts = opts or {}
  local dest = opts.dest
  if not dest or dest == '' then
    local resolved = M.resolve_history_dest(cfg, nil)
    if not resolved then
      return M.prompt_dest(cfg, function(chosen)
        if not chosen then
          return on_choice(nil)
        end
        Proc.launch(function()
          M.select_history(cfg, on_choice, { dest = chosen })
        end)
      end)
    end
    dest = resolved
  end

  local parsed, derr = Util.parse_dest(dest)
  if not parsed then
    return Util.report_error(derr)
  end

  local probe, perr = Bootstrap.probe(cfg, parsed)
  if not probe then
    return Util.report_error(perr)
  end
  local root = Util.remote_root_abs(cfg, probe.home)
  local remote, lerr = Bootstrap.list_workspace_profiles(cfg, parsed, root)
  if not remote then
    return Util.report_error(lerr)
  end

  local items = M.history_items(cfg, dest, remote)
  if #items == 0 then
    Util.notify(('no workspaces found for %s on this client host'):format(dest))
    return on_choice(nil)
  end

  M.choose('sshdev workspaces', items, function(item)
    if not item then
      return on_choice(nil)
    end
    if item.kind == 'new' then
      return M.prompt_new(cfg, function(new_dest, workspace)
        if not new_dest then
          return on_choice(nil)
        end
        new_connection_choice(cfg, new_dest, workspace, on_choice)
      end)
    end
    local e = item.entry
    on_choice({
      dest = dest,
      workspace = e.workspace,
      nvim_profile_key = e.nvim_profile_key,
    })
  end, {
    forget = function(picked)
      if picked.kind == 'workspace' and picked.entry then
        History.remove(picked.entry)
        Util.notify('[sshdev] forgot ' .. History.format(picked.entry))
      end
    end,
  })
end

---Backwards-compatible name for the workspace picker.
M.select_workspaces = M.select_history

return M
