local entry = require("worklog.entry")
local render = require("worklog.render")
local summary = require("worklog.summary")
local summary_block = require("worklog.summary_block")
local summary_cursor = require("worklog.usecases.summary_cursor")
local support = require("worklog.usecases.support")

local M = {}

-- Manually balance summary rounding by marking entries with round±N nudges.
--
-- Quantization rounds durations to the block's q= bucket by largest remainder, so
-- residuals can leave an aggregate (a day, hence a week) one or more q-steps off a
-- clean total. This use case lets the cursor on a summary row -- or directly on a
-- worklog entry -- shift the rounding by N q-steps. With the cursor on a summary
-- row the optimality calculator finds the best contributing fine-grained row(s) to
-- nudge (least added error); on an entry it nudges that entry's row. A fine-grained
-- row is summed from its intervals before quantizing, so its nudge is one value the
-- whole stretch shares: ALL of the row's contributing entries get the marker (it is
-- not a per-interval amount that would multiply). The marker lives on entries (the
-- summary is a pure projection), the one summary is rebuilt in place, and -- because
-- every section is a sum of the same nudged fine-grained rows -- each section stays
-- a partition that foots to its (shifted) total.
--
-- A delta of 0 clears the cursor target's nudge: on a summary row it removes every
-- marker contributing to that row's scope; on an entry it removes that entry's marker.

M.NOT_BALANCEABLE =
  "worklog: put the cursor on a summary row or a worklog entry to balance its rounding"
M.CANNOT_DOWN = "worklog: cannot round down further here; the contributing items are already empty"
M.NOTHING = "worklog: nothing to balance on this line"

-- The set of fine-grained rows a cursor line governs. A main row scopes its own
-- (text, tag) across locations; tag/location/logged totals scope that group; the
-- workday total scopes workday-eligible rows and the activity total scopes all.
local function scope_for(layout_row)
  local kind = layout_row.kind
  local item = layout_row.item
  local K = render.LAYOUT_KIND

  if kind == K.SUMMARY_ITEM then
    return function(row)
      return row.text == item.text
        and row.tag == item.tag
        and (row.workday_excluded == true) == (item.workday_excluded == true)
        and (row.logged == true) == (item.logged == true)
    end
  elseif kind == K.TAG_TOTAL then
    return function(row)
      return row.tag == item.tag
    end
  elseif kind == K.LOCATION_TOTAL then
    return function(row)
      return row.location == item.location
    end
  elseif kind == K.LOGGED_TOTAL then
    return function(row)
      return not row.workday_excluded and (row.logged == true) == (item.logged == true)
    end
  elseif kind == K.TOTAL then
    if layout_row.total == "workday" then
      return function(row)
        return not row.workday_excluded
      end
    end
    return function()
      return true
    end
  end

  return nil
end

-- Greedily move `delta` q-steps across the scoped rows, one bucket per step, to the
-- row that minimizes the added rounding error. Rounding up gives the bucket to the
-- most under-displayed row (max error `e = remainder - blocks*q`); rounding down
-- takes it from the most over-displayed (min e). This single rule is the
-- largest-remainder method generalized: it cancels an opposing nudge first (a
-- below-floor row has the largest e), then rounds the next-best natural candidate.
-- Returns a per-row map index -> net block change, or nil + error when a round-down
-- has nowhere left to go (every scoped row is already empty).
local function plan_steps(rows, scope, bucket_minutes, delta)
  local work = {}
  for i, row in ipairs(rows) do
    local base = math.floor(row.unrounded_duration / bucket_minutes) * bucket_minutes
    work[i] = {
      base = base,
      remainder = row.unrounded_duration - base,
      blocks = (row.duration - base) / bucket_minutes,
      anchor = row.source_entry_rows and row.source_entry_rows[1] or nil,
      in_scope = scope(row) and row.source_entry_rows ~= nil and #row.source_entry_rows > 0,
    }
  end

  local sign = delta > 0 and 1 or -1

  for _ = 1, math.abs(delta) do
    local best
    for _, w in ipairs(work) do
      if w.in_scope then
        local can = sign > 0 or (w.base + (w.blocks - 1) * bucket_minutes) >= 0
        if can then
          local e = w.remainder - w.blocks * bucket_minutes
          local better
          if not best then
            better = true
          elseif e == best.e then
            better = w.anchor < best.w.anchor
          else
            better = sign > 0 and e > best.e or sign < 0 and e < best.e
          end
          if better then
            best = { w = w, e = e }
          end
        end
      end
    end

    if not best then
      return nil, M.CANNOT_DOWN
    end

    best.w.blocks = best.w.blocks + sign
  end

  local changes = {}
  for i, w in ipairs(work) do
    local delta_blocks = w.blocks - (rows[i].duration - w.base) / bucket_minutes
    if delta_blocks ~= 0 then
      changes[i] = delta_blocks
    end
  end

  return changes
end

-- Map the per-row block changes onto per-entry marker changes. A fine-grained row's
-- nudge is a single value its whole activity-stretch shares, so ALL of the row's
-- contributing entries are set to the new value (current row nudge + the change).
-- Setting every interval -- rather than one arbitrary one -- is why the marker can
-- be read off any of them and survives editing another, and why marking an
-- activity's intervals never multiplies the shift.
local function entry_changes_for_rows(rows, row_changes, current_entry_nudge)
  local changes = {}

  for index, delta_blocks in pairs(row_changes) do
    local row = rows[index]
    local new_nudge = (row.nudge or 0) + delta_blocks
    for _, source_row in ipairs(row.source_entry_rows) do
      if (current_entry_nudge[source_row] or 0) ~= new_nudge then
        changes[source_row] = new_nudge
      end
    end
  end

  return changes
end

-- The net per-entry nudge changes for a cursor on a summary row: the calculator
-- picks the rows to nudge and the source entries to mark. A delta of 0 clears every
-- nudge contributing to the scope.
local function summary_entry_changes(block, layout_row, delta)
  local scope = scope_for(layout_row)
  if not scope then
    return nil, M.NOTHING
  end

  local rows, bucket_minutes = summary.fine_grained_quantized(block.entries, block.quantize_minutes)

  local current_entry_nudge = {}
  for _, item in ipairs(block.entry_items) do
    current_entry_nudge[item.entry.row] = item.nudge or 0
  end

  if delta == 0 then
    local changes = {}
    for _, row in ipairs(rows) do
      if scope(row) then
        for _, source_row in ipairs(row.source_entry_rows or {}) do
          if (current_entry_nudge[source_row] or 0) ~= 0 then
            changes[source_row] = 0
          end
        end
      end
    end
    return changes
  end

  local row_changes, err = plan_steps(rows, scope, bucket_minutes, delta)
  if not row_changes then
    return nil, err
  end

  return entry_changes_for_rows(rows, row_changes, current_entry_nudge)
end

-- The per-entry nudge changes for a cursor directly on a worklog entry: nudge the
-- fine-grained row that entry belongs to, setting every interval of that row to the
-- new value. Returns nil when the cursor entry starts no interval (e.g. the closing
-- entry of the day), which therefore contributes to no row and cannot be rounded.
local function entry_direct_changes(block, cursor_row, delta)
  local rows = summary.fine_grained_quantized(block.entries, block.quantize_minutes)

  local current_entry_nudge = {}
  for _, item in ipairs(block.entry_items) do
    current_entry_nudge[item.entry.row] = item.nudge or 0
  end

  for _, row in ipairs(rows) do
    for _, source_row in ipairs(row.source_entry_rows or {}) do
      if source_row == cursor_row then
        local new_nudge = delta == 0 and 0 or (row.nudge or 0) + delta
        local changes = {}
        for _, entry_row in ipairs(row.source_entry_rows) do
          if (current_entry_nudge[entry_row] or 0) ~= new_nudge then
            changes[entry_row] = new_nudge
          end
        end
        return changes
      end
    end
  end

  return nil
end

-- Build the edit script that rewrites the changed entry lines and, when the block
-- already carries a summary, rebuilds it in place from the nudged entries. Modeled
-- on log_current: the source entries gain/lose their round±N marker and the one
-- summary is regenerated, so it stays a pure projection.
local function build_edits(analysis, block, entry_changes)
  if next(entry_changes) == nil then
    return nil, M.NOTHING
  end

  local source_edits = {}
  local current_tag = block.header_tag
  local current_location = block.header_location
  local current_offset = block.header_offset

  for _, item in ipairs(block.entry_items) do
    local new_nudge = entry_changes[item.entry.row]
    if new_nudge ~= nil then
      local line = entry.format({
        minutes = item.minutes,
        text = item.text,
        tag = item.tag,
        location = item.location,
        offset = item.offset,
        nudge = new_nudge,
        workday_excluded = item.workday_excluded,
        logged = item.logged,
      }, current_tag, current_location, current_offset)

      table.insert(source_edits, {
        start_index = item.start_row - 1,
        end_index = item.start_row,
        lines = { line },
      })
    end

    current_tag = item.tag
    current_location = item.location
    current_offset = item.offset
  end

  -- Rebuild the one summary from the nudged entries, replacing its located region.
  local modified = support.modified_entries(block, function(copy)
    if entry_changes[copy.row] ~= nil then
      copy.nudge = entry_changes[copy.row]
    end
  end)

  local options = { leading_blank = false, quantize_minutes = block.quantize_minutes }
  local expected =
    render.summary_lines(summary.summarize_block(block), block.duration_format, options)
  local region = summary_block.find(analysis, block, expected)

  local edits = {}

  if region then
    local rebuilt = summary.summarize_entries(modified, block.quantize_minutes)
    table.insert(edits, {
      start_index = region.start_row - 1,
      end_index = region.end_row - 1,
      lines = render.summary_lines(rebuilt, block.duration_format, options),
    })
  end

  for _, edit in ipairs(source_edits) do
    table.insert(edits, edit)
  end

  -- Apply highest-row-first so the summary rebuild does not shift the source rows.
  table.sort(edits, function(a, b)
    return a.start_index > b.start_index
  end)

  return { edits = edits }
end

-- `delta` is a signed integer of q-steps; 0 clears the cursor target's nudge.
function M.run(lines, cursor_row, delta)
  delta = delta or 0

  local result, resolve_err = summary_cursor.resolve(lines, cursor_row)

  if result then
    local entry_changes, err = summary_entry_changes(result.ctx.block, result.layout_row, delta)
    if not entry_changes then
      return nil, err
    end
    return build_edits(result.ctx.analysis, result.ctx.block, entry_changes)
  end

  if resolve_err then
    return nil, resolve_err
  end

  -- The cursor is not on the active worklog's summary; try a worklog entry directly.
  local ctx, ctx_err = support.get_validated_active(lines)
  if not ctx then
    return nil, ctx_err or M.NOT_BALANCEABLE
  end

  local entry_changes = entry_direct_changes(ctx.block, cursor_row, delta)
  if not entry_changes then
    return nil, M.NOT_BALANCEABLE
  end
  if next(entry_changes) == nil then
    return nil, M.NOTHING
  end

  return build_edits(ctx.analysis, ctx.block, entry_changes)
end

return M
