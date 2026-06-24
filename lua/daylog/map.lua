local buffer = require("daylog.buffer")
local config = require("daylog.config")
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

-- Set the alias: a direct `value`, a `source_name` picker (map onto a work item), the
-- sole configured source's picker, or a plain prompt. An empty/cancelled prompt is a
-- no-op -- clearing is the explicit `:DaylogMap!`.
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

  local source, src_name
  if source_name then
    source = sources_registry.get(source_name)
    if not source then
      warn("daylog: unknown source '" .. source_name .. "'")
      return
    end
    src_name = source_name
  else
    local names = sources_registry.names()
    if #names == 1 then
      src_name = names[1]
      source = sources_registry.get(src_name)
    end
  end

  local function prompt()
    apply_map(vim.fn.input({
      prompt = "daylog: map to: ",
      default = current.alias or "",
    }))
  end

  if not source then
    prompt()
    return
  end

  -- The shared picker shell uses Telescope when installed and vim.ui.select
  -- otherwise: pick a source work-item (map onto its entry text) or type a label.
  local function open_picker(items)
    pick.rename({
      candidates = {},
      source = source,
      source_name = src_name,
      initial_items = items,
      prompt = "Daylog: map to source  (<CR> pick, <C-e> type a label)",
      prompt_fallback = "Daylog: map to source",
      type_new_label = "✎ Type a label…",
      on_pick = apply_map,
      on_create = apply_map,
      on_pick_item = function(item)
        apply_map(source.to_entry_text(item))
      end,
      on_type_new = prompt,
    })
  end

  local ttl = ((config.get().sources or {})[src_name] or {}).ttl or 1800
  sources_sync.ensure_fresh(src_name, ttl, function(items)
    open_picker(items)
  end)
end

return M
