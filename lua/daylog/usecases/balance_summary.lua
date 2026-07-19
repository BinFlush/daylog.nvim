local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")

local M = {}

-- Manually balance summary rounding by marking entries with round±N nudges.
--
-- A cursor on a summary row nudges the best contributing fine-grained row(s) (least
-- added error); on an entry it nudges that entry's row. A fine-grained row's nudge is
-- one value its whole stretch shares, so ALL its contributing entries get the marker
-- (never a per-interval amount that would multiply). Markers live on entries; the one
-- summary is rebuilt in place and every section stays a partition footing to its total.
-- A delta of 0 clears the cursor target's nudge.
--
-- Only the main axis is a valid target (main rows, activity total, workday total); a tag
-- or location row is refused. Frozen logged rows (`!S`) are held at their committed value
-- and never selectable; when only logged candidates remain, balancing errors
-- (ONLY_LOGGED) rather than no-op, mirroring the round-down-past-empty refusal.

M.NOT_BALANCEABLE = "daylog: put the cursor on a summary row or an entry to balance its rounding"
M.CANNOT_DOWN = "daylog: cannot round down further here; the contributing items are already empty"
M.ONLY_LOGGED = "daylog: cannot balance here; the remaining items are all logged"
M.NOTHING = "daylog: nothing to balance on this line"
M.SECTION_NOT_BALANCEABLE =
  "daylog: balance an activity or the workday total; a tag or location row can't be the balance target"

-- The set of summary rows a cursor line governs: a main row scopes itself (rows split per
-- granule, so its own label at its own tag and location); the workday total scopes every row.
local function scope_for(layout_row)
  local kind = layout_row.kind
  local item = layout_row.item
  local K = render.LAYOUT_KIND

  if kind == K.SUMMARY_ITEM then
    return function(row)
      return row.text == item.text
        and row.tag == item.tag
        and row.location == item.location
        and (row.logged == true) == (item.logged == true)
    end
  elseif kind == K.TOTAL then
    -- A claimed (!W) totals slice is pinned; refuse it rather than silently nudge the
    -- plain slice, which is the real target and scopes every counted row.
    if item and item.logged then
      return nil, M.ONLY_LOGGED
    end
    return function()
      return true
    end
  end

  return nil
end

-- Greedily move `delta` q-steps across the scoped rows, one bucket per step, to the row
-- that minimizes added rounding error (largest-remainder generalized: up -> max error
-- `e = remainder - blocks*q`, down -> min e). Returns a per-row map index -> net block
-- change, or nil + error when a round-down has nowhere left to go.
local function plan_steps(rows, scope, bucket_minutes, delta)
  local work = {}
  local has_frozen_in_scope = false
  for i, row in ipairs(rows) do
    local base = math.floor(row.unrounded_duration / bucket_minutes) * bucket_minutes
    local in_scope = scope(row) and row.source_entry_rows ~= nil and #row.source_entry_rows > 0
    -- A row is nudgeable only while every one of its entries is marker-free: a nudge on a
    -- logged entry is refused outright, and a claim would override the shift anyway. Remember
    -- one was here, so an exhausted balance can report *why* (logged, not empty).
    if in_scope and row.marked then
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
      -- Nothing left: logged rows excluded from scope, else the candidates are at zero.
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

-- Map per-row block changes onto per-entry marker changes: ALL of a row's contributing
-- entries are set to the new value (current row nudge + change), so the marker reads off
-- any interval and never multiplies the shift.
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

-- The net per-entry nudge changes for a cursor on a summary row; a delta of 0 clears
-- every nudge contributing to the scope.
local function summary_entry_changes(block, layout_row, delta)
  local scope, scope_err = scope_for(layout_row)
  if not scope then
    return nil, scope_err or M.NOTHING
  end

  local totals = summary.summarize_block(block)
  local rows, bucket_minutes = totals.summary_items, totals.bucket_minutes

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

-- The per-entry nudge changes for a cursor directly on an entry: nudge the fine-grained
-- row it belongs to, setting every interval. Returns nil when the cursor entry starts no
-- interval (e.g. the day's closing entry) and so contributes to no row.
local function entry_direct_changes(block, cursor_row, delta)
  local totals = summary.summarize_block(block)
  local rows, bucket_minutes = totals.summary_items, totals.bucket_minutes

  local current_entry_nudge = current_nudges(block)

  for _, row in ipairs(rows) do
    for _, source_row in ipairs(row.source_entry_rows or {}) do
      if source_row == cursor_row then
        -- A nudge on a logged entry is refused outright; never write one here either.
        if delta ~= 0 and row.marked then
          return nil, M.ONLY_LOGGED
        end
        -- Refuse a round-down that would drive the displayed duration below 0 (as
        -- plan_steps does), not an out-of-range round-N marker.
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

-- Whether two summary layout rows denote the same target, by kind + identity; balance
-- leaves these fields stable, so the balanced row is re-findable after the rebuild.
local function same_target(a, b)
  if a.kind ~= b.kind then
    return false
  end

  local K = render.LAYOUT_KIND
  if a.kind == K.SUMMARY_ITEM then
    return a.item.text == b.item.text
      and a.item.tag == b.item.tag
      and (a.item.logged == true) == (b.item.logged == true)
  elseif a.kind == K.TOTAL then
    -- A split workday renders logged + unlogged rows both `total == "workday"`; include
    -- logged state so the cursor follows the balanced row, not the first.
    return a.total == b.total
      and (a.item and a.item.logged == true) == (b.item and b.item.logged == true)
  end

  return false
end

-- The buffer line `target_row` renders at in the rebuilt summary, so the cursor follows a
-- reordered row; the layout is 1:1 with the rebuilt lines, so its index maps onto the region.
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

-- Build the edit script rewriting the changed entry lines and rebuilding the summary in
-- place from the nudged entries (it stays a pure projection). `target_row`, when
-- balancing one, makes the cursor follow it to its new line.
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
