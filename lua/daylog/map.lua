local buffer = require("daylog.buffer")
local pick = require("daylog.pick")
local report = require("daylog.report")
local map_summary = require("daylog.usecases.map_summary")
local sources_registry = require("daylog.sources.registry")
local sources_sync = require("daylog.sources.sync")

local M = {}

-- Map operation (shell).
--
-- Sets or clears an entry's mapping alias -- the label it resolves to in the summary --
-- with the cursor on a main summary row (every contributing entry), on a single entry, or
-- over a visual range (every selected entry line, and every selected summary row's entries).
-- The pure math is in usecases/map_summary; this is the prompt / source-picker / apply shell
-- around it, mirroring the rename shell.

local warn = buffer.warn
local buffer_lines = buffer.buffer_lines
local cursor_row = buffer.cursor_row
local run_pinned_usecase = buffer.run_pinned_usecase

local function in_report()
  return report.spec_for() ~= nil
end

-- A usecase call bound to the cursor entry/row, or to a `{ r1, r2 }` line range -- the
-- difference between a plain :Daylog map and a ranged (visual) one. do_run(lines, label)
-- returns the usecase result.
local function runner(range, row)
  if range then
    return function(lines, label)
      return map_summary.run_range(lines, range[1], range[2], label)
    end
  end
  return function(lines, label)
    return map_summary.run(lines, row, label)
  end
end

-- Peek the current alias for a prompt default, cursor or range alike.
local function peek(range, row)
  if range then
    return map_summary.peek_range(buffer_lines(), range[1], range[2])
  end
  return map_summary.peek(buffer_lines(), row)
end

local function apply(target_buf, label, do_run)
  run_pinned_usecase(target_buf, "map", do_run, label)
end

-- Clear the alias on the cursor's target, or across a visual range -- entries and the entries
-- behind selected summary rows alike (`:Daylog! map`).
function M.clear(range)
  if in_report() then
    warn("daylog: :Daylog map is not available in a report; map in the day file")
    return
  end

  apply(vim.api.nvim_get_current_buf(), "", runner(range, cursor_row()))
end

-- Set the alias: a direct `value`, a named source's scoped picker (live-searchable, mapping onto
-- a work item -- like :Daylog insert <source>), or the unified pool (recent activities + every
-- source's items) with no argument; a plain prompt when there is nothing to pick. An
-- empty/cancelled prompt is a no-op -- clearing is the explicit `:Daylog! map`.
function M.summary(value, source_name, range)
  if in_report() then
    warn("daylog: :Daylog map is not available in a report; map in the day file")
    return
  end

  local row = cursor_row()
  local current, err = peek(range, row)
  if not current then
    warn(err)
    return
  end

  local target_buf = vim.api.nvim_get_current_buf()
  local do_run = runner(range, row)
  local function apply_map(label)
    -- nil/cancelled and empty are no-ops (clearing is the explicit `:Daylog! map`). Mapping onto the
    -- current alias is a no-op only for a SINGLE target: over a range `current.alias` is just the FIRST
    -- selected entry's, and the others may still change, so let the usecase decide there (it emits no
    -- edit for an entry already at the label).
    if label == nil or label == "" then
      return
    end
    if not range and label == current.alias then
      return
    end
    apply(target_buf, label, do_run)
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
  -- onto the chosen work item's entry text -- exactly like :Daylog insert <source>.
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

  -- Map onto the same unified pool as :Daylog! insert -- recent activities across days plus every
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
