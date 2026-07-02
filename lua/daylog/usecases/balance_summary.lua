local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")

local M = {}

-- Manually balance summary rounding by marking entries with round±N nudges.
--
-- Quantization rounds durations to the block's q= bucket by largest remainder, so
-- residuals can leave an aggregate (a day, hence a week) one or more q-steps off a
-- clean total. This use case lets the cursor on a summary row -- or directly on a
-- entry -- shift the rounding by N q-steps. With the cursor on a summary
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
--
-- Balancing acts on the main (summary-level) axis -- main rows, the activity total, and the workday
-- total. Every section is a re-sum of the one shared granule quantization, so a nudge planned here
-- flows into the tag and location totals too (they stay footed with the balanced activity total).
-- Choosing a tag or location row as the balance TARGET is refused for now -- balance an activity or
-- the workday total (or an entry) instead.
--
-- Frozen logged rows (`!S<minutes>`) are held at their committed value and the
-- quantizer ignores any nudge on them, so they are never selectable: a balance step
-- only ever lands on an un-frozen row. When the only candidates left in scope are
-- logged -- because every other row has been driven to zero by a round-down, or
-- because the scope is all logged -- balancing errors rather than no-op, mirroring the
-- round-down-past-empty refusal.

M.NOT_BALANCEABLE = "daylog: put the cursor on a summary row or an entry to balance its rounding"
M.CANNOT_DOWN = "daylog: cannot round down further here; the contributing items are already empty"
M.ONLY_LOGGED = "daylog: cannot balance here; the remaining items are all logged"
M.NOTHING = "daylog: nothing to balance on this line"
M.SECTION_NOT_BALANCEABLE =
  "daylog: balance an activity or the workday total; a tag or location row can't be the balance target"

-- The set of fine-grained rows a cursor line governs. A main row scopes its own
-- (text, tag) across locations; the workday total scopes workday-eligible rows and the activity total
-- scopes all. (Tag and location totals are refused earlier -- not a valid balance target.)
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
  local has_frozen_in_scope = false
  for i, row in ipairs(rows) do
    local base = math.floor(row.unrounded_duration / bucket_minutes) * bucket_minutes
    local in_scope = scope(row) and row.source_entry_rows ~= nil and #row.source_entry_rows > 0
    -- A frozen logged row is held at its committed value and the quantizer ignores a
    -- nudge on it, so it can never absorb a step; drop it from the candidates but
    -- remember it was here, so an exhausted balance can report *why* (logged, not empty).
    if in_scope and row.logged_minutes ~= nil then
      has_frozen_in_scope = true
      in_scope = false
    end
    work[i] = {
      base = base,
      remainder = row.unrounded_duration - base,
      blocks = (row.duration - base) / bucket_minutes,
      anchor = row.source_entry_rows and row.source_entry_rows[1] or nil,
      in_scope = in_scope,
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
      -- Nothing left to move. If logged rows are the reason (they were in scope but
      -- excluded), say so; otherwise the un-frozen candidates are simply at zero.
      if has_frozen_in_scope then
        return nil, M.ONLY_LOGGED
      end
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

-- Map each entry row to the nudge already on it (default 0), so a planned change can
-- be compared against the current marker and only the genuine differences emitted.
local function current_nudges(block)
  local nudges = {}
  for _, item in ipairs(block.entry_items) do
    nudges[item.entry.row] = item.nudge or 0
  end
  return nudges
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

  local current_entry_nudge = current_nudges(block)

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

-- The per-entry nudge changes for a cursor directly on an entry: nudge the
-- fine-grained row that entry belongs to, setting every interval of that row to the
-- new value. Returns nil when the cursor entry starts no interval (e.g. the closing
-- entry of the day), which therefore contributes to no row and cannot be rounded.
local function entry_direct_changes(block, cursor_row, delta)
  local rows, bucket_minutes = summary.fine_grained_quantized(block.entries, block.quantize_minutes)

  local current_entry_nudge = current_nudges(block)

  for _, row in ipairs(rows) do
    for _, source_row in ipairs(row.source_entry_rows or {}) do
      if source_row == cursor_row then
        -- A frozen logged row is fixed; a nudge on it would be ignored by the
        -- quantizer, so refuse rather than write a marker that does nothing.
        if delta ~= 0 and row.logged_minutes ~= nil then
          return nil, M.ONLY_LOGGED
        end
        -- Refuse a round-down that would drive the displayed duration below 0, exactly as the
        -- summary-row path (plan_steps) does, instead of writing an out-of-range round-N marker.
        if delta < 0 and (row.duration + delta * bucket_minutes) < 0 then
          return nil, M.CANNOT_DOWN
        end
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

-- Whether two summary layout rows denote the same target, by kind + identity (mirrors
-- `scope_for`). Balance only changes a row's duration/nudge, so these fields are stable,
-- which lets the balanced row be re-found after the rebuild to follow it with the cursor.
local function same_target(a, b)
  if a.kind ~= b.kind then
    return false
  end

  local K = render.LAYOUT_KIND
  if a.kind == K.SUMMARY_ITEM then
    return a.item.text == b.item.text
      and a.item.tag == b.item.tag
      and (a.item.workday_excluded == true) == (b.item.workday_excluded == true)
      and (a.item.logged == true) == (b.item.logged == true)
  elseif a.kind == K.TOTAL then
    return a.total == b.total
  end

  return false
end

-- The buffer line `target_row` renders at in the rebuilt summary, so the cursor can
-- follow a row that reordered. The layout is 1:1 with the rebuilt lines, so its index
-- maps straight onto the region.
local function cursor_for_target(rebuilt, block, region, target_row)
  local layout =
    render.summary_layout(rebuilt, block.duration_format, support.summary_render_options(block))
  for i, row in ipairs(layout) do
    if same_target(row, target_row) then
      return region.start_row + (i - 1)
    end
  end
  return nil
end

-- Build the edit script that rewrites the changed entry lines and, when the block
-- already carries a summary, rebuilds it in place from the nudged entries. Modeled
-- on log_current: the source entries gain/lose their round±N marker and the one
-- summary is regenerated, so it stays a pure projection. `target_row` (the resolved
-- summary layout row, when balancing one) makes the cursor follow it to its new line.
local function build_edits(analysis, block, entry_changes, target_row)
  if next(entry_changes) == nil then
    return nil, M.NOTHING
  end

  local overrides = {}
  for row, new_nudge in pairs(entry_changes) do
    overrides[row] = { nudge = new_nudge }
  end

  local result, rebuilt, region = support.apply_entry_overrides(analysis, block, overrides)

  -- Follow the balanced row to its new line when it reordered.
  if region and target_row then
    result.cursor_row = cursor_for_target(rebuilt, block, region, target_row)
  end

  return result
end

-- `delta` is a signed integer of q-steps; 0 clears the cursor target's nudge.
function M.run(lines, cursor_row, delta)
  delta = delta or 0

  local result, resolve_err = summary_cursor.resolve_or_entry(lines, cursor_row)
  if not result then
    return nil, resolve_err or M.NOT_BALANCEABLE
  end

  if result.layout_row then
    local kind = result.layout_row.kind
    if kind == render.LAYOUT_KIND.TAG_TOTAL or kind == render.LAYOUT_KIND.LOCATION_TOTAL then
      return nil, M.SECTION_NOT_BALANCEABLE
    end

    local entry_changes, err = summary_entry_changes(result.ctx.block, result.layout_row, delta)
    if not entry_changes then
      return nil, err
    end
    return build_edits(result.ctx.analysis, result.ctx.block, entry_changes, result.layout_row)
  end

  -- The cursor is not on a summary row; balance the entry under it directly.
  local entry_changes, direct_err = entry_direct_changes(result.ctx.block, cursor_row, delta)
  if not entry_changes then
    return nil, direct_err or M.NOT_BALANCEABLE
  end
  if next(entry_changes) == nil then
    return nil, M.NOTHING
  end

  return build_edits(result.ctx.analysis, result.ctx.block, entry_changes)
end

return M
