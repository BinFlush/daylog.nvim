local entry = require("worklog.entry")
local render = require("worklog.render")
local summary = require("worklog.summary")
local support = require("worklog.usecases.support")
local syntax = require("worklog.syntax")

local M = {}

-- Build the edit script for marking the main summary row under the cursor as
-- externally logged, then replacing the existing rendered summary group with a
-- freshly computed one so the buffer is immediately consistent.
--
-- The rendered summary row acts as a selector only: the active worklog is
-- analyzed from source, the matching summary is recomputed, and the source
-- entries behind the selected row receive a trailing !L.
--
-- Ownership is enforced in two layers:
--
--   1. `classify_cursor_section` accepts only generic blocks whose header is
--      exactly `--- summary exact ---` or `--- summary quantized ---` and
--      that start at or after the active worklog's header row. Because the
--      active worklog is by definition the last worklog block in the buffer,
--      this restricts the cursor's containing block to the active worklog's
--      trailing derived output.
--   2. `M.run` then recomputes the active worklog's summary in the matching
--      kind, builds the structured layout via `render.summary_layout`, and
--      requires the cursor line to match exactly one `summary_item` row.
--      This is the final staleness guard: a user-typed summary section that
--      drifted from the current source state will not match and is refused.
--
-- After a successful match the function:
--   a. Builds source-entry edits (add !L to contributing entries).
--   b. Detects the full summary group range by scanning forward through
--      consecutive recognized subsection blocks of the same kind.
--   c. Applies the source-entry mutations in memory, re-analyzes, recomputes,
--      and renders a replacement for the whole group.
--   d. Returns the refresh edit first (higher rows), source edits after
--      (lower rows), so the buffer application loop can apply them in order
--      without index drift.

local STALE_OR_NOT_SUMMARY =
  "worklog: summary row does not match the active worklog; regenerate the summary"
local AMBIGUOUS = "worklog: summary row matches multiple rows; regenerate the summary"
local REFUSE_OOO = "worklog: refusing to mark out-of-office time as logged"
local INCONSISTENT_SOURCE = "worklog: logged marking is inconsistent; regenerate the summary"

local SECTION_KINDS = {
  [syntax.section_header("summary", "exact")] = "exact",
  [syntax.section_header("summary", "quantized")] = "quantized",
}

-- Recognized generated section headers that belong to a single summary group.
-- Used to determine how far forward to extend the replacement range when the
-- active summary is refreshed after logging.
local SUMMARY_SUBSECTIONS = {
  exact = {
    [syntax.section_header("summary", "exact")] = true,
    [syntax.section_header("tags", "exact")] = true,
    [syntax.section_header("locations", "exact")] = true,
    [syntax.section_header("logged", "exact")] = true,
    [syntax.section_header("totals", "exact")] = true,
  },
  quantized = {
    [syntax.section_header("summary", "quantized")] = true,
    [syntax.section_header("tags", "quantized")] = true,
    [syntax.section_header("locations", "quantized")] = true,
    [syntax.section_header("logged", "quantized")] = true,
    [syntax.section_header("totals", "quantized")] = true,
  },
}

local function block_at_row(analysis, row)
  for _, block in ipairs(analysis.blocks) do
    if row >= block.start_row and row < block.end_row then
      return block
    end
  end

  return nil
end

-- Identify the summary kind the cursor sits in, *and* assert that the
-- containing section belongs to the active worklog's trailing derived output.
-- Returns the kind string and the cursor's containing block, or nil for both.
-- See the module header for the ownership reasoning.
local function classify_cursor_section(analysis, active_block, lines, cursor_row)
  local block = block_at_row(analysis, cursor_row)

  -- The cursor must sit inside a generic (non-worklog) block. The worklog
  -- body itself never contains summary rows.
  if not block or block.kind == "worklog_block" then
    return nil
  end

  -- Reject summary sections that belong to an earlier worklog. The active
  -- worklog is the last worklog block in the buffer, so any generic block
  -- whose header sits before the active worklog header lives under a
  -- different worklog and is not eligible.
  if block.start_row < active_block.start_row then
    return nil
  end

  -- The header line itself is never a summary_item.
  if cursor_row == block.start_row then
    return nil
  end

  -- Only the bare summary headers are recognized. Tag, location, logged, and
  -- total subsections render as their own generic blocks with different
  -- headers, and weekly/range report headers carry extra labels such as
  -- dates or week numbers; both fail this exact-match lookup.
  return SECTION_KINDS[lines[block.start_row]], block
end

local function compute_summary(block, kind)
  if kind == "exact" then
    return summary.summarize_block(block)
  end

  return summary.quantized_summarize_block(block)
end

local function find_summary_item_matches(layout, cursor_line)
  local matches = {}

  for _, row in ipairs(layout) do
    if row.kind == "summary_item" and row.line == cursor_line then
      table.insert(matches, row)
    end
  end

  return matches
end

-- Scan forward from the cursor's block through consecutive blocks whose
-- headers are all recognized subsections of the same summary kind.  The first
-- unrecognized block (another worklog, a different summary group, a notes
-- block, or end-of-file) stops the scan.  Returns the end_row (exclusive,
-- 1-indexed) of the last recognized block.
local function find_summary_group_end_row(analysis, cursor_block, kind, lines)
  local subsections = SUMMARY_SUBSECTIONS[kind]
  local last_end_row = cursor_block.end_row
  local past_cursor = false

  for _, block in ipairs(analysis.blocks) do
    if block.start_row == cursor_block.start_row then
      past_cursor = true
      last_end_row = block.end_row
    elseif past_cursor then
      if subsections[lines[block.start_row]] then
        last_end_row = block.end_row
      else
        break
      end
    end
  end

  return last_end_row
end

-- Apply source-entry edits to an in-memory copy of lines so the updated
-- source state can be re-analyzed without touching the real buffer.
local function apply_source_edits_to_lines(lines, edits)
  local result = {}
  for i, line in ipairs(lines) do
    result[i] = line
  end

  for _, edit in ipairs(edits) do
    for j, line in ipairs(edit.lines) do
      result[edit.start_index + j] = line
    end
  end

  return result
end

-- Re-analyze the in-memory copy of lines after source edits, recompute the
-- summary, and build a replacement edit for the detected summary group range.
local function build_summary_refresh_edit(
  lines,
  source_edits,
  kind,
  duration_format,
  group_start_row,
  group_end_row
)
  local modified = apply_source_edits_to_lines(lines, source_edits)

  local ctx, err = support.get_validated_active(modified)
  if not ctx then
    return nil, err
  end

  local new_summary = compute_summary(ctx.block, kind)
  local replacement =
    render.summary_lines(new_summary, kind, duration_format, { leading_blank = false })

  return {
    start_index = group_start_row - 1,
    end_index = group_end_row - 1,
    lines = replacement,
  }
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

  local kind, cursor_block = classify_cursor_section(ctx.analysis, ctx.block, lines, cursor_row)
  if not kind then
    return nil, STALE_OR_NOT_SUMMARY
  end

  local cursor_line = lines[cursor_row]
  if cursor_line == nil then
    return nil, STALE_OR_NOT_SUMMARY
  end

  -- Final ownership and staleness guard: the cursor line must match exactly
  -- one summary_item row in the layout that the plugin would currently
  -- produce for the active worklog. A user-typed summary section whose text
  -- drifted from the current source state will not match and is refused.
  local recomputed = compute_summary(ctx.block, kind)
  local layout = render.summary_layout(recomputed, kind, ctx.block.duration_format)
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
  local group_end_row = find_summary_group_end_row(ctx.analysis, cursor_block, kind, lines)

  local refresh_edit, refresh_err = build_summary_refresh_edit(
    lines,
    source_edits,
    kind,
    ctx.block.duration_format,
    cursor_block.start_row,
    group_end_row
  )
  if not refresh_edit then
    return nil, refresh_err
  end

  -- The refresh edit targets the summary group (higher row indices) and must
  -- be applied before the source-entry edits (lower row indices) to avoid
  -- index drift when the rendered group changes size.
  local all_edits = { refresh_edit }
  for _, edit in ipairs(source_edits) do
    table.insert(all_edits, edit)
  end

  return { edits = all_edits }
end

return M
