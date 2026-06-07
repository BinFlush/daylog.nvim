local entry = require("worklog.entry")
local render = require("worklog.render")
local summary = require("worklog.summary")
local summary_block = require("worklog.summary_block")
local support = require("worklog.usecases.support")

local M = {}

-- Toggle the logged state of the main summary row under the cursor.
--
-- A worklog has a single summary. The rendered row is only
-- a selector: the active worklog is analyzed from source, the matching summary
-- item is recomputed, the contributing source entries gain or lose a trailing
-- !L, and the one summary is rebuilt from the updated source. The summary is a
-- pure projection, so the rebuild needs no note preservation.
--
-- Guards: the cursor must sit in the active worklog's summary section, the
-- cursor line must match exactly one recomputed summary_item row (this is the
-- staleness check), out-of-office rows cannot be marked, and the contributing
-- entries must agree on their current logged state.

local STALE_OR_NOT_SUMMARY =
  "worklog: summary row does not match the active worklog; regenerate the summary"
local AMBIGUOUS = "worklog: summary row matches multiple rows; regenerate the summary"
local REFUSE_OOO = "worklog: refusing to mark out-of-office time as logged"
local INCONSISTENT_SOURCE = "worklog: logged marking is inconsistent; regenerate the summary"

local function block_at_row(analysis, row)
  for _, block in ipairs(analysis.blocks) do
    if row >= block.start_row and row < block.end_row then
      return block
    end
  end

  return nil
end

local function compute_summary(block)
  return summary.summarize_block(block)
end

-- Recompute the summary with `logged` toggled on the target source rows, by
-- copying the block's semantic entries and flipping them in memory. This avoids
-- re-parsing the buffer and yields the post-mark summary directly.
local function rebuilt_summary(block, target_rows, target_logged)
  local entries = {}

  for _, semantic_entry in ipairs(block.entries) do
    local copy = {}
    for key, value in pairs(semantic_entry) do
      copy[key] = value
    end

    if target_rows[copy.row] then
      copy.logged = target_logged
    end

    table.insert(entries, copy)
  end

  return summary.summarize_entries(entries, block.quantize_minutes)
end

local function find_summary_item_matches(layout, cursor_line)
  local matches = {}

  for _, row in ipairs(layout) do
    if row.kind == render.LAYOUT_KIND.SUMMARY_ITEM and row.line == cursor_line then
      table.insert(matches, row)
    end
  end

  return matches
end

local function build_log_edits(block, target_rows, target_logged)
  local edits = {}
  local current_tag = block.header_tag
  local current_location = block.header_location

  for _, item in ipairs(block.entry_items) do
    if target_rows[item.start_row] then
      local line = entry.format({
        minutes = item.minutes,
        text = item.text,
        tag = item.tag,
        location = item.location,
        workday_excluded = item.workday_excluded,
        logged = target_logged,
      }, current_tag, current_location)

      table.insert(edits, {
        start_index = item.start_row - 1,
        end_index = item.start_row,
        lines = { line },
      })
    end

    current_tag = item.tag
    current_location = item.location
  end

  return edits
end

function M.run(lines, cursor_row)
  if type(cursor_row) ~= "number" or cursor_row < 1 or cursor_row > #lines then
    return nil, STALE_OR_NOT_SUMMARY
  end

  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  local region = summary_block.find(ctx.analysis, ctx.block)
  if not region then
    return nil, STALE_OR_NOT_SUMMARY
  end

  -- The cursor must sit inside the active worklog's summary subsection (the
  -- `--- summary ---` block), and not on its header line. Tag, location,
  -- logged, and total subsections are their own blocks and are not eligible.
  local cursor_block = block_at_row(ctx.analysis, cursor_row)
  if
    not cursor_block
    or cursor_block.start_row ~= region.start_row
    or cursor_row == region.start_row
  then
    return nil, STALE_OR_NOT_SUMMARY
  end

  local cursor_line = lines[cursor_row]

  -- Staleness guard: the cursor line must match exactly one summary_item row in
  -- the summary the plugin would currently produce for the active worklog.
  local recomputed = compute_summary(ctx.block)
  local layout = render.summary_layout(
    recomputed,
    ctx.block.duration_format,
    { quantize_minutes = ctx.block.quantize_minutes }
  )
  local matches = find_summary_item_matches(layout, cursor_line)

  if #matches == 0 then
    return nil, STALE_OR_NOT_SUMMARY
  end

  if #matches > 1 then
    return nil, AMBIGUOUS
  end

  local item = matches[1].item
  local target_logged = not item.logged

  if target_logged and item.workday_excluded then
    return nil, REFUSE_OOO
  end

  local source_rows = item.source_entry_rows or {}
  if #source_rows == 0 then
    return nil, STALE_OR_NOT_SUMMARY
  end

  local target_rows = {}
  for _, source_row in ipairs(source_rows) do
    target_rows[source_row] = true
  end

  for _, entry_item in ipairs(ctx.block.entry_items) do
    if
      target_rows[entry_item.start_row] and (entry_item.logged == true) ~= (item.logged == true)
    then
      return nil, INCONSISTENT_SOURCE
    end
  end

  local source_edits = build_log_edits(ctx.block, target_rows, target_logged)

  local rebuilt = rebuilt_summary(ctx.block, target_rows, target_logged)
  local rendered = render.summary_lines(rebuilt, ctx.block.duration_format, {
    leading_blank = false,
    quantize_minutes = ctx.block.quantize_minutes,
  })

  -- The summary rebuild targets higher rows than the source-entry edits, so it
  -- is applied first to avoid index drift when the rendered summary changes size.
  local all_edits = {
    {
      start_index = region.start_row - 1,
      end_index = region.end_row - 1,
      lines = rendered,
    },
  }
  for _, edit in ipairs(source_edits) do
    table.insert(all_edits, edit)
  end

  return { edits = all_edits }
end

return M
