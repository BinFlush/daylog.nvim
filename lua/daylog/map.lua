local buffer = require("daylog.buffer")
local pick = require("daylog.pick")
local map_summary = require("daylog.usecases.map_summary")
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

-- Set the alias: a direct `value`, or the unified picker (map onto a work item or recent
-- activity), or a plain prompt when there is nothing to pick. An empty/cancelled prompt is a
-- no-op -- clearing is the explicit `:DaylogMap!`. A source-name arg no longer scopes (the pool
-- is all sources), so it is accepted but unused.
function M.summary(value, _source_name)
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
