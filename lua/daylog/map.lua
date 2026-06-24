local buffer = require("daylog.buffer")
local pick = require("daylog.pick")
local map_summary = require("daylog.usecases.map_summary")
local sources_registry = require("daylog.sources.registry")
local sources_sync = require("daylog.sources.sync")

local M = {}

-- Map operation (shell).
--
-- Sets or clears an entry's mapping alias -- the label it resolves to in the summary --
-- with the cursor on a main summary row (every contributing entry) or on a single entry.
-- The pure math is in usecases/map_summary; this is the prompt / source-picker / apply
-- shell around it, mirroring the rename shell.

local warn = buffer.warn
local buffer_lines = buffer.buffer_lines
local cursor_row = buffer.cursor_row
local apply_result = buffer.apply_result
local buffer_changed = buffer.buffer_changed

local function in_report()
  local ok, spec = pcall(vim.api.nvim_buf_get_var, 0, "log_report")
  return ok and type(spec) == "table"
end

local function apply(row, target_buf, label)
  if buffer_changed(target_buf, "map") then
    return
  end

  local result, err = map_summary.run(buffer_lines(), row, label)
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

-- Clear the alias on the cursor's target (`:DaylogMap!`).
function M.clear()
  if in_report() then
    warn("daylog: :DaylogMap is not available in a report; map in the day file")
    return
  end

  apply(cursor_row(), vim.api.nvim_get_current_buf(), "")
end

-- Set the alias: a direct `value`, a named source's scoped picker (live-searchable, mapping onto
-- a work item -- like :DaylogInsert <source>), or the unified pool (recent activities + every
-- source's items) with no argument; a plain prompt when there is nothing to pick. An
-- empty/cancelled prompt is a no-op -- clearing is the explicit `:DaylogMap!`.
function M.summary(value, source_name)
  if in_report() then
    warn("daylog: :DaylogMap is not available in a report; map in the day file")
    return
  end

  local row = cursor_row()
  local current, err = map_summary.peek(buffer_lines(), row)
  if not current then
    warn(err)
    return
  end

  local target_buf = vim.api.nvim_get_current_buf()
  local function apply_map(label)
    if label == nil or label == "" or label == current.alias then
      return
    end
    apply(row, target_buf, label)
  end

  if value ~= nil then
    apply_map(value)
    return
  end

  local function prompt()
    apply_map(vim.fn.input({
      prompt = "daylog: map to: ",
      default = current.alias or "",
    }))
  end

  -- A named source scopes to that one tracker (live-searchable when `search = true`), mapping
  -- onto the chosen work item's entry text -- exactly like :DaylogInsert <source>.
  if source_name then
    local source = sources_registry.get(source_name)
    if not source then
      warn("daylog: unknown source '" .. source_name .. "'")
      return
    end
    pick.source(source, source_name, {
      prompt = "Daylog: map -> " .. source_name,
      prompt_fallback = "Daylog: pick " .. source_name .. " item",
      on_pick = function(item)
        apply_map(source.to_entry_text(item))
      end,
      on_cancel = nil,
    })
    return
  end

  -- Map onto the same unified pool as :DaylogInsert! -- recent activities across days plus every
  -- source's items, ranked and deduped. type-a-label and the empty-pool fallback go through the
  -- plain input prompt.
  pick.unified(sources_sync.read_specs(), {
    on_choose = apply_map,
    on_create = apply_map,
    on_type_new = prompt,
    on_empty = prompt,
    prompt = "Daylog: map to  (<CR> pick, <C-e> type a label)",
    prompt_fallback = "Daylog: map to",
    type_new_label = "✎ Type a label…",
  })
end

return M
