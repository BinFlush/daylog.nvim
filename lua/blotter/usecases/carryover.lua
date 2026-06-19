local analyze = require("blotter.analyze")
local blot = require("blotter.blot")
local summary_cursor = require("blotter.usecases.summary_cursor")
local support = require("blotter.usecases.support")
local syntax = require("blotter.syntax")

local M = {}

-- Past-midnight carryover helpers.
--
-- These pure helpers support rolling an activity that was running across
-- midnight from one day's blotter into the next. The shell layer captures the
-- activity, closes the source day at the 24:00 boundary, then seeds the target
-- day with the continuation at 00:00.

local function activity_from_item(item)
  return {
    text = item.text,
    explicit_tag = item.explicit_tag,
    explicit_tag_clear = item.explicit_tag_clear,
    explicit_location = item.explicit_location,
    explicit_location_clear = item.explicit_location_clear,
    tag = item.tag,
    location = item.location,
    offset = item.offset,
    workday_excluded = item.workday_excluded,
  }
end

-- The activity in effect at the end of the active blotter, i.e. the final
-- blot when it still has activity text. Returns nil when nothing was running
-- (no blots, the day already closed with a bare timestamp, or the final blot
-- is the 24:00 end-of-day boundary).
function M.last_running_entry(lines)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  local items = ctx.block.blot_items
  local last = items[#items]
  if not last or last.text == "" or last.minutes == syntax.END_OF_DAY_MINUTES then
    return nil
  end

  return activity_from_item(last)
end

-- The activity item on the given row, or nil. Only looks at real timestamped
-- blots in the blotter block at `row`.
local function item_at_row(lines, row)
  local ctx = support.get_validated_at_row(lines, row)
  if not ctx then
    return nil
  end

  for _, item in ipairs(ctx.block.blot_items) do
    if item.blot.row == row then
      return item
    end
  end

  return nil
end

-- The activity of the blot on the given row, used to repeat it after the
-- buffer has switched to the new day. The cursor may instead be on a main summary
-- row, in which case it is mapped back to the source blot it summarizes, so
-- cross-day :BlotRepeat works from the summary too.
function M.entry_at_row(lines, row)
  local item = item_at_row(lines, row)
  if item then
    return activity_from_item(item)
  end

  local entry_row, summary_err = summary_cursor.repeat_entry_row(lines, row)
  if entry_row then
    local resolved = item_at_row(lines, entry_row)
    if resolved then
      return activity_from_item(resolved)
    end
  end

  if summary_err then
    return nil, summary_err
  end

  local _, err = support.get_validated_at_row(lines, row)
  return nil, err or "blotter: current line is not a valid blot"
end

-- Insert one formatted blot for `activity` at `minutes` into the active
-- blotter, placed at the sorted position with sticky metadata resolved.
function M.seed_edit(lines, activity, minutes)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  local state = support.get_insert_state(ctx.block, minutes)

  -- A carried/closing blot is fresh: it copies the activity's sticky metadata but
  -- takes the boundary/continuation time and never inherits a logged or round±N marker.
  local fields = analyze.copy_fields(activity)
  fields.minutes = minutes
  fields.logged = false
  fields.nudge = nil

  local line = blot.format(fields, state.tag, state.location, state.offset)

  return support.insert_blot_edit(
    ctx.block,
    minutes,
    line,
    activity.tag,
    activity.location,
    activity.offset
  )
end

-- Append a bare 24:00 blot that closes the active blotter's final task at the
-- day boundary. The sticky metadata is carried so the close stays bare.
function M.close_edit(lines)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  local minutes = syntax.END_OF_DAY_MINUTES
  local state = support.get_insert_state(ctx.block, minutes)

  return M.seed_edit(lines, {
    text = "",
    tag = state.tag,
    location = state.location,
    offset = state.offset,
    workday_excluded = state.tag == syntax.OUT_OF_OFFICE_TAG,
  }, minutes)
end

return M
