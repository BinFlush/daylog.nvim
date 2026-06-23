local entry = require("daylog.entry")
local render = require("daylog.render")
local split = require("daylog.split")
local summary = require("daylog.summary")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")

local M = {}

-- Split the activity under the cursor into N weighted sub-activities (PURE).
--
-- Each of the activity's time intervals is cut into consecutive sub-intervals named
-- `foo (1)`, `foo (2)`, ... by whole minutes, distributed by the (unnormalized) weight
-- vector. The original total time is preserved exactly -- the interval endpoints never
-- move -- so the day still foots; only the breakdown changes. The 2-D apportionment
-- (each interval sums to its own length while each sub-activity's total tracks its
-- weighted share) lives in split.lua; this use case turns that into entry edits and a
-- rebuilt summary, sharing the cursor-resolution and summary-rebuild patterns with
-- :DaylogLog. A logged activity is frozen against an external system and cannot be split.

M.REFUSE_LOGGED = "daylog: refusing to split a logged activity"
M.NEED_TWO = "daylog: split needs at least two parts"
M.BAD_WEIGHT = "daylog: split weights must be positive numbers"
M.NOTHING = "daylog: nothing to split on this row"

-- The sub-activity name for part `index` of an activity. A blank activity (a bare
-- `#tag` entry) becomes just the `(index)` suffix. `(index)` is plain text -- never a
-- control token -- so it round-trips without sanitizing.
local function part_name(text, index)
  local suffix = "(" .. index .. ")"
  if text == "" then
    return suffix
  end
  return text .. " " .. suffix
end

local function validate_weights(weights)
  if not weights or #weights == 0 then
    return { 1, 1 }
  end

  if #weights < 2 then
    return nil, M.NEED_TWO
  end

  for _, w in ipairs(weights) do
    if type(w) ~= "number" or w <= 0 then
      return nil, M.BAD_WEIGHT
    end
  end

  return weights
end

-- The activity's intervals in chronological order: each source entry starts an
-- interval whose raw span ends at the next entry. Returns the ordered spans and a map
-- from source entry row to its index in that list (so the allocation row can be found).
local function target_intervals(block, source_set)
  local spans = {}
  local index_by_row = {}

  for k = 1, #block.entries - 1 do
    local current = block.entries[k]
    if source_set[current.row] then
      spans[#spans + 1] = block.entries[k + 1].minutes - current.minutes
      index_by_row[current.row] = #spans
    end
  end

  return spans, index_by_row
end

function M.run(lines, cursor_row, weights)
  local resolved, err = validate_weights(weights)
  if not resolved then
    return nil, err
  end
  weights = resolved

  local result, resolve_err = summary_cursor.resolve(lines, cursor_row)
  if not result then
    if resolve_err then
      return nil, resolve_err
    end
    local _, validate_err = support.get_validated_active(lines)
    return nil, validate_err or summary_cursor.STALE
  end

  if result.layout_row.kind ~= render.LAYOUT_KIND.SUMMARY_ITEM then
    return nil, summary_cursor.STALE
  end

  local block = result.ctx.block
  local item = result.layout_row.item

  if item.logged then
    return nil, M.REFUSE_LOGGED
  end

  local source_set = {}
  for _, row in ipairs(item.source_entry_rows or {}) do
    source_set[row] = true
  end

  local spans, index_by_row = target_intervals(block, source_set)
  if #spans == 0 then
    return nil, M.NOTHING
  end

  local matrix = split.allocate(spans, weights)

  -- The present sub-activity parts for each split entry, keyed by its row.
  local parts_by_row = {}
  for row, span_index in pairs(index_by_row) do
    parts_by_row[row] = split.parts(matrix[span_index])
  end

  -- Source edits: rewrite each split entry line into its present parts. Walk the
  -- entries tracking the sticky tag/location/offset (as support.rewrite_entry_lines
  -- does) so the first part -- the renamed original -- reproduces the original's tokens,
  -- and the inserted parts inherit them (bare). The last part keeps the original's
  -- sticky, so the entry after the activity needs no compensating token.
  local source_edits = {}
  local current_tag = block.header_tag
  local current_location = block.header_location
  local current_offset = block.header_offset

  for _, entry_item in ipairs(block.entry_items) do
    local parts = parts_by_row[entry_item.start_row]
    if parts then
      local out_lines = {}
      for i, part in ipairs(parts) do
        local fields = {
          minutes = entry_item.minutes + part.offset,
          text = part_name(entry_item.text, part.index),
          tag = entry_item.tag,
          location = entry_item.location,
          offset = entry_item.offset,
          workday_excluded = entry_item.workday_excluded,
          logged = false,
        }
        if i == 1 then
          out_lines[i] = entry.format(fields, current_tag, current_location, current_offset)
        else
          out_lines[i] =
            entry.format(fields, entry_item.tag, entry_item.location, entry_item.offset)
        end
      end

      source_edits[#source_edits + 1] = {
        start_index = entry_item.start_row - 1,
        end_index = entry_item.start_row,
        lines = out_lines,
      }
    end

    current_tag = entry_item.tag
    current_location = entry_item.location
    current_offset = entry_item.offset
  end

  -- Rebuild the summary from the post-split entries (the split entries replaced by
  -- their present sub-entries). The original interval's offset rides on each sub-entry,
  -- so durations and footing are preserved.
  local modified = {}
  for _, semantic_entry in ipairs(block.entries) do
    local parts = parts_by_row[semantic_entry.row]
    if parts then
      for _, part in ipairs(parts) do
        modified[#modified + 1] = {
          minutes = semantic_entry.minutes + part.offset,
          text = part_name(semantic_entry.text, part.index),
          tag = semantic_entry.tag,
          location = semantic_entry.location,
          offset = semantic_entry.offset,
          workday_excluded = semantic_entry.workday_excluded,
          logged = false,
          logged_minutes = nil,
          nudge = nil,
          row = semantic_entry.row,
        }
      end
    else
      modified[#modified + 1] = semantic_entry
    end
  end

  local rebuilt = summary.summarize_entries(modified, block.quantize_minutes)
  local rendered =
    render.summary_lines(rebuilt, block.duration_format, support.summary_render_options(block))

  -- The summary region sits below the entries; applying it first (highest rows) keeps
  -- the lower entry edits valid as they expand beneath it.
  local edits = {
    {
      start_index = result.region.start_row - 1,
      end_index = result.region.end_row - 1,
      lines = rendered,
    },
  }
  for _, edit in ipairs(source_edits) do
    edits[#edits + 1] = edit
  end

  table.sort(edits, function(a, b)
    return a.start_index > b.start_index
  end)

  return { edits = edits }
end

return M
