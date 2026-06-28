local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")
local syntax = require("daylog.syntax")

local M = {}

-- Past-midnight carryover helpers.
--
-- These pure helpers support rolling an activity that was running across
-- midnight from one day's log into the next. The shell layer captures the
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

-- The activity in effect at the end of the active log, i.e. the final
-- entry when it still has activity text. Returns nil when nothing was running
-- (no entries, the day already closed with a bare timestamp, or the final entry
-- is the 24:00 end-of-day boundary).
function M.last_running_entry(lines)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  local items = ctx.block.entry_items
  local last = items[#items]
  if not last or last.text == "" or last.minutes == syntax.END_OF_DAY_MINUTES then
    return nil
  end

  return activity_from_item(last)
end

-- The activity item on the given row, or nil. Only looks at real timestamped
-- entries in the log block at `row`.
local function item_at_row(lines, row)
  local ctx = support.get_validated_at_row(lines, row)
  if not ctx then
    return nil
  end

  return support.entry_item_at_row(ctx.block, row)
end

-- The activity of the entry on the given row, used to repeat it after the
-- buffer has switched to the new day. The cursor may instead be on a main summary
-- row, in which case it is mapped back to the source entry it summarizes, so
-- cross-day :DaylogRepeat works from the summary too.
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
  return nil, err or "daylog: current line is not a valid entry"
end

-- Insert one formatted entry for `activity` at `minutes` into the active
-- log, placed at the sorted position with sticky metadata resolved. `auto_offset`
-- (optional) is the live OS offset; a drift from the offset in effect records the new
-- zone on the seeded entry (used by the cross-day repeat into an existing today).
function M.seed_edit(lines, activity, minutes, auto_offset)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  return support.fresh_entry_edit(ctx.block, activity, minutes, auto_offset)
end

-- Append a bare 24:00 entry that closes the active log's final task at the
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
