local render = require("daylog.render")
local split = require("daylog.split")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")
local syntax = require("daylog.syntax")

local M = {}

-- Split the activity under the cursor into N weighted sub-activities (PURE).
--
-- Each interval is cut into consecutive sub-intervals `foo (1)`, `foo (2)`, ... by whole minutes,
-- distributed by the weight vector. Total time is preserved exactly (endpoints never move), so the
-- day still foots. The 2-D apportionment lives in split.lua; this turns it into entry edits and a
-- rebuilt summary. An activity whose entries carry any logging marker (!S/!T/!L/!W) is frozen and
-- cannot be split.

M.REFUSE_LOGGED = "daylog: refusing to split a logged activity"
M.REFUSE_OFFSET =
  "daylog: split does not fit; a UTC offset change pushes a cut past the end of the day"
M.NEED_TWO = "daylog: split needs at least two parts"
M.BAD_WEIGHT = "daylog: split weights must be positive numbers"
M.NOTHING = "daylog: nothing to split on this row"
M.NOT_A_ROW = "daylog: put the cursor on an activity summary row to split it"

-- The sub-activity name for part `index`. A blank activity becomes just the `(index)` suffix,
-- which is plain text (never a control token), so it round-trips without sanitizing.
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

-- The activity's intervals in chronological order. Each record carries the source row, local start
-- minute, and effective duration -- the real elapsed time, which differs from the local span
-- across a UTC offset change. The split apportions effective duration and places sub-entries at
-- `start + cumulative effective` on the interval's own offset, so the log stays real-time-ordered.
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

  local source_set = {}
  for _, row in ipairs(item.source_entry_rows or {}) do
    source_set[row] = true
  end

  -- A logging commitment at ANY level (!S / !T / !L / !W) freezes the interval; the rewrite carries no
  -- logged token, so splitting would silently drop the marker. Refuse rather than corrupt it.
  for _, entry in ipairs(block.entries) do
    if source_set[entry.row] and entry.logged ~= nil then
      return nil, M.REFUSE_LOGGED
    end
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

  -- Sub-activity parts per split entry, keyed by row. A part starts at the interval start plus its
  -- cumulative effective offset. The only cut that can't be written without a new offset token is
  -- one a westward jump pushes to or past 24:00 -- refuse those.
  local parts_by_row = {}
  for _, record in ipairs(records) do
    local parts = split.parts(matrix[index_by_row[record.row]])
    if #parts > 0 and record.start + parts[#parts].offset >= syntax.END_OF_DAY_MINUTES then
      return nil, M.REFUSE_OFFSET
    end
    parts_by_row[record.row] = parts
  end

  -- Rewrite each split entry into its parts, threading sticky tag/location/offset so the first
  -- part reproduces the original's tokens and inserted parts inherit them. Every part carries the
  -- resolved metadata, so the entry after the activity needs no compensating token.
  local source_edits = support.rewrite_entry_lines(block, function(entry_item)
    local parts = parts_by_row[entry_item.start_row]
    if not parts then
      return nil
    end

    local field_sets = {}
    for i, part in ipairs(parts) do
      local text, alias = part_identity(entry_item, part.index)
      field_sets[i] = {
        minutes = entry_item.minutes + part.offset,
        text = text,
        alias = alias,
        tag = entry_item.tag,
        location = entry_item.location,
        offset = entry_item.offset,
        logged = nil,
      }
    end
    return field_sets
  end)

  -- Rebuild the summary from the post-split entries. The original interval's offset rides on each
  -- sub-entry, so durations and footing are preserved.
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
