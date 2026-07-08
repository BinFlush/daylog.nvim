local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")
local syntax = require("daylog.syntax")

local M = {}

-- Past-midnight carryover helpers (pure): roll an activity running across midnight into the
-- next day. The shell captures it, closes the source day at 24:00, then seeds the target at 00:00.

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
  }
end

-- The activity in effect at the end of the active log (the final entry with text), or nil
-- when nothing was running (no entries, day closed with a bare timestamp, or a 24:00 boundary).
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

-- The activity item on the given row, or nil; only real timestamped entries in the block at `row`.
local function item_at_row(lines, row)
  local ctx = support.get_validated_at_row(lines, row)
  if not ctx then
    return nil
  end

  return support.entry_item_at_row(ctx.block, row)
end

-- The activity of the entry on the given row (for cross-day repeat); a cursor on a summary
-- row is mapped back to the source entry it summarizes.
function M.entry_at_row(lines, row)
  local item = item_at_row(lines, row)
  if item then
    return activity_from_item(item)
  end

  local entry_row, summary_err = summary_cursor.repeat_entry_row(lines, row)
  if entry_row then
    local resolved = item_at_row(lines, entry_row)
    if resolved then
      -- A summary row shows only the resolved label, so carry that in bare (see support), not the
      -- source entry's description-plus-mapping.
      return activity_from_item(support.resolved_bare_item(resolved))
    end
  end

  if summary_err then
    return nil, summary_err
  end

  local _, err = support.get_validated_at_row(lines, row)
  return nil, err or "daylog: current line is not a valid entry"
end

-- Insert one formatted entry for `activity` at `minutes` into the active log at its sorted
-- position; a drift in `auto_offset` (live OS offset) records the new zone on the seeded entry.
function M.seed_edit(lines, activity, minutes, auto_offset)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  return support.fresh_entry_edit(ctx.block, activity, minutes, auto_offset)
end

-- Append a bare 24:00 entry closing the active log's final task at the day boundary;
-- sticky metadata is carried so it stays bare.
function M.close_edit(lines)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  -- Already closed (24:00 or blank final entry): appending a second close would duplicate the
  -- boundary, so guard here rather than depend on the caller's gate.
  local entries = ctx.block.entries
  local last = entries[#entries]
  if last and (last.text == "" or last.minutes == syntax.END_OF_DAY_MINUTES) then
    return nil, "daylog: the log is already closed"
  end

  local minutes = syntax.END_OF_DAY_MINUTES
  local state = support.get_insert_state(ctx.block, minutes)

  return M.seed_edit(lines, {
    text = "",
    tag = state.tag,
    location = state.location,
    offset = state.offset,
  }, minutes)
end

return M
