--- Connection picker for sshdev.nvim.
---
--- Uses telescope when it is installed (`:SSHdevConnect` with no arguments,
--- `:SSHdevConnect <TAB>`-style workflows), and falls back to
--- |vim.ui.select()| so the plugin still works with a bare config.
---
--- Selecting an entry reconnects to that (destination, workspace). A
--- trailing "new connection" entry asks for a destination and a remote
--- workspace path.

local History = require('sshdev.history')
local Util = require('sshdev.util')

local M = {}

---Is telescope available and loadable?
---@return boolean
function M.has_telescope()
  local ok = pcall(require, 'telescope')
  return ok
end

---Prompt for a destination and a workspace, then call on_done.
---@param cfg table
---@param on_done fun(dest: string, workspace: string|nil)
function M.prompt_new(cfg, on_done)
  local default_dest = cfg.host or ''
  vim.ui.input({ prompt = 'ssh destination ([user@]host[:port]): ', default = default_dest }, function(dest)
    if not dest or dest == '' then
      return
    end
    vim.ui.input({ prompt = 'remote workspace dir (~ for remote $HOME): ', default = cfg.workspace or '~' }, function(ws)
      if ws == nil then
        return
      end
      on_done(dest, ws ~= '' and ws or nil)
    end)
  end)
end

---@param cfg table
---@param on_choice fun(entry: table|nil)  entry = { dest, workspace }
local function pick_with_telescope(cfg, on_choice)
  local ok, err = pcall(function()
    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')

    local entries = History.list()
    local results = {}
    for _, e in ipairs(entries) do
      results[#results + 1] = { entry = e, display = History.display(e), kind = 'history' }
    end
    results[#results + 1] = {
      kind = 'new',
      display = '＋ new connection …',
      entry = nil,
    }

    pickers
      .new({}, {
        prompt_title = 'sshdev connections',
        finder = finders.new_table({
          results = results,
          entry_maker = function(item)
            return {
              value = item,
              display = item.display,
              ordinal = item.display,
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local sel = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if not sel then
              return on_choice(nil)
            end
            local item = sel.value
            if item.kind == 'new' then
              return M.prompt_new(cfg, function(dest, ws)
                on_choice({ dest = dest, workspace = ws })
              end)
            end
            on_choice({ dest = item.entry.dest, workspace = item.entry.workspace })
          end)
          -- <C-D> forgets the highlighted connection
          vim.keymap.set('i', '<C-d>', function()
            local sel = action_state.get_selected_entry()
            if sel and sel.value and sel.value.kind == 'history' then
              History.remove(sel.value.entry)
              actions.close(prompt_bufnr)
              vim.notify('[sshdev] removed ' .. History.format(sel.value.entry))
            end
          end, { buffer = prompt_bufnr })
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

---@param cfg table
---@param on_choice fun(entry: table|nil)
local function pick_with_ui_select(cfg, on_choice)
  local entries = History.list()
  local items = {}
  for _, e in ipairs(entries) do
    items[#items + 1] = { kind = 'history', entry = e, display = History.display(e) }
  end
  items[#items + 1] = { kind = 'new', display = '＋ new connection …' }

  vim.ui.select(items, {
    prompt = 'sshdev connections',
    format_item = function(item)
      return item.display
    end,
  }, function(item)
    if not item then
      return on_choice(nil)
    end
    if item.kind == 'new' then
      return M.prompt_new(cfg, function(dest, ws)
        on_choice({ dest = dest, workspace = ws })
      end)
    end
    on_choice({ dest = item.entry.dest, workspace = item.entry.workspace })
  end)
end

---Open the connection picker.
---@param cfg table
---@param on_choice fun(entry: table|nil) entry = { dest = string, workspace = string|nil }
function M.select(cfg, on_choice)
  if M.has_telescope() then
    return pick_with_telescope(cfg, on_choice)
  end
  return pick_with_ui_select(cfg, on_choice)
end

---Direct history picker (same list, no "new" prompt fallback needed).
---@param cfg table
---@param on_choice fun(entry: table|nil)
function M.select_history(cfg, on_choice)
  return M.select(cfg, on_choice)
end

return M
