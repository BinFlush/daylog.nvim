local entry = require("daylog.entry")
local render = require("daylog.render")
local split = require("daylog.split")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")
local syntax = require("daylog.syntax")

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
-- :Daylog log. A logged activity is frozen against an external system and cannot be split.

M.REFUSE_LOGGED = "daylog: refusing to split a logged activity"
M.REFUSE_OFFSET =
  "daylog: split does not fit; a UTC offset change pushes a cut past the end of the day"
M.NEED_TWO = "daylog: split needs at least two parts"
M.BAD_WEIGHT = "daylog: split weights must be positive numbers"
M.NOTHING = "daylog: nothing to split on this row"
M.NOT_A_ROW = "daylog: put the cursor on an activity summary row to split it"

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

-- A part's identity: the `(n)` suffix lands on the RESOLVED label, so a mapped entry keeps its
-- description and its parts group under `label (n)` -- exactly like a bare group's `text (n)`.
-- Returns text, alias.
local function part_identity(item, index)
  if item.alias ~= nil and item.alias ~= "" then
    return item.text, part_name(item.alias, index)
  end
  return part_name(item.text, index), nil
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

-- The activity's intervals in chronological order. Each record carries the source
-- entry row, its local start minute, and the effective duration -- the real elapsed
-- time, which differs from the local span across a UTC offset change (and is what the
-- summary shows). The split apportions the effective duration; sub-entries are placed at
-- `start + cumulative effective` and carry the interval's own offset (no new utc token),
-- so the log stays real-time-ordered even when a later entry, written in a new time
-- zone, reads earlier on the wall clock.
local function target_intervals(block, source_set)
  local records = {}
  local index_by_row = {}

  for k = 1, #block.entries - 1 do
    local current = block.entries[k]
    if source_set[current.row] then
      local next = block.entries[k + 1]
      records[#records + 1] = {
        row = current.row,
        start = current.minutes,
        effective = (next.minutes - (next.offset or 0)) - (current.minutes - (current.offset or 0)),
      }
      index_by_row[current.row] = #records
    end
  end

  return records, index_by_row
end

function M.run(lines, cursor_row, weights)
  local resolved, err = validate_weights(weights)
  if not resolved then
    return nil, err
  end
  weights = resolved

  local result, resolve_err = summary_cursor.resolve_or_entry(lines, cursor_row)
  if not result then
    return nil, resolve_err
  end

  -- Split acts only on a main activity row; an entry, another summary row, or the cursor
  -- on nothing all point the user at a row (unless the active log itself is invalid above).
  if not result.layout_row or result.layout_row.kind ~= render.LAYOUT_KIND.SUMMARY_ITEM then
    return nil, M.NOT_A_ROW
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

  local records, index_by_row = target_intervals(block, source_set)
  if #records == 0 then
    return nil, M.NOTHING
  end

  local effective = {}
  for i, record in ipairs(records) do
    effective[i] = record.effective
  end

  local matrix = split.allocate(effective, weights)

  -- The present sub-activity parts for each split entry, keyed by its row. A part begins
  -- at the interval start plus its cumulative EFFECTIVE offset, on the interval's own
  -- local clock. Effective ordering always holds, so the only thing that can't be written
  -- without a new offset token is a cut that a westward jump pushes to or past 24:00 --
  -- refuse those. Without an offset change the cuts stay inside the day, so this is inert.
  local parts_by_row = {}
  for _, record in ipairs(records) do
    local parts = split.parts(matrix[index_by_row[record.row]])
    if #parts > 0 and record.start + parts[#parts].offset >= syntax.END_OF_DAY_MINUTES then
      return nil, M.REFUSE_OFFSET
    end
    parts_by_row[record.row] = parts
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
        local text, alias = part_identity(entry_item, part.index)
        local fields = {
          minutes = entry_item.minutes + part.offset,
          text = text,
          alias = alias,
          tag = entry_item.tag,
          location = entry_item.location,
          offset = entry_item.offset,
          logged = nil,
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
        local text, alias = part_identity(semantic_entry, part.index)
        modified[#modified + 1] = {
          minutes = semantic_entry.minutes + part.offset,
          text = text,
          alias = alias,
          tag = semantic_entry.tag,
          location = semantic_entry.location,
          offset = semantic_entry.offset,
          logged = nil,
          nudge = nil,
          row = semantic_entry.row,
        }
      end
    else
      modified[#modified + 1] = semantic_entry
    end
  end

  local summary_edit = support.summary_zone_edit(result.ctx.analysis, block, modified, false)

  return { edits = support.entry_change_edits(summary_edit, source_edits) }
end

return M
