local entry = require("worklog.entry")
local support = require("worklog.usecases.support")
local syntax = require("worklog.syntax")

local M = {}

-- Past-midnight carryover helpers.
--
-- These pure helpers support rolling an activity that was running across
-- midnight from one day's worklog into the next. The shell layer captures the
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
    workday_excluded = item.workday_excluded,
  }
end

-- The activity in effect at the end of the active worklog, i.e. the final
-- entry when it still has activity text. Returns nil when nothing was running
-- (no entries, or the day already closed with a bare timestamp).
function M.last_running_entry(lines)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  local items = ctx.block.entry_items
  local last = items[#items]
  if not last or last.text == "" then
    return nil
  end

  return activity_from_item(last)
end

-- The activity of the entry on the given row, used to repeat it after the
-- buffer has switched to the new day.
function M.entry_at_row(lines, row)
  local ctx, err = support.get_validated_at_row(lines, row)
  if not ctx then
    return nil, err
  end

  for _, item in ipairs(ctx.block.entry_items) do
    if item.entry.row == row then
      return activity_from_item(item)
    end
  end

  return nil, "worklog: current line is not a valid worklog entry"
end

-- Insert one formatted entry for `activity` at `minutes` into the active
-- worklog, placed at the sorted position with sticky metadata resolved.
function M.seed_edit(lines, activity, minutes)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  local state = support.get_insert_state(ctx.block, minutes)
  local line = entry.format({
    minutes = minutes,
    text = activity.text,
    explicit_tag = activity.explicit_tag,
    explicit_tag_clear = activity.explicit_tag_clear,
    explicit_location = activity.explicit_location,
    explicit_location_clear = activity.explicit_location_clear,
    tag = activity.tag,
    location = activity.location,
    workday_excluded = activity.workday_excluded,
    logged = false,
  }, state.tag, state.location)

  return support.insert_entry_edit(ctx.block, minutes, line, activity.tag, activity.location)
end

-- Append a bare 24:00 entry that closes the active worklog's final task at the
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
    workday_excluded = state.tag == syntax.OUT_OF_OFFICE_TAG,
  }, minutes)
end

return M
