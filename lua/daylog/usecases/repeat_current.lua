local analyze = require("daylog.analyze")
local entry = require("daylog.entry")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")

local M = {}

-- Build the edit script for repeating the current activity at a new time. The
-- cursor may sit on a timestamped entry or on a main summary row; the latter is
-- mapped back to the source entry it summarizes (see summary_cursor).

function M.run(lines, row, time, auto_offset)
  local ctx, err = support.get_validated_at_row(lines, row)

  if not ctx then
    -- The cursor may be on a main summary row; map it back to the source entry
    -- and repeat that, into the log the summary belongs to. A nil summary
    -- error means the cursor is not on the summary at all, so keep `err`.
    local entry_row, summary_err = summary_cursor.repeat_entry_row(lines, row)
    if not entry_row then
      return nil, summary_err or err
    end

    row = entry_row
    ctx, err = support.get_validated_at_row(lines, row)
    if not ctx then
      return nil, err
    end
  end

  local current_item = nil
  for _, item in ipairs(ctx.block.entry_items) do
    if item.entry.row == row then
      current_item = item
      break
    end
  end

  if not current_item then
    return nil, "daylog: current line is not a valid entry"
  end

  local minutes, minutes_err = support.parse_clock_minutes(time)
  if not minutes then
    return nil, minutes_err
  end

  local insertion_state = support.get_insert_state(ctx.block, minutes)

  -- A repeat is a fresh entry: it copies the activity's metadata from the source but
  -- takes the new time and never inherits the source's logged or round±N marker. The
  -- mapping alias (` => label`) is part of the activity's identity, so it is kept.
  local fields = analyze.copy_fields(current_item)
  fields.minutes = minutes
  fields.logged = false
  fields.nudge = nil

  -- A drifted live offset (auto_timezone) overrides the copied source offset, so the
  -- repeat records the zone the activity is happening in now.
  local stamp = support.offset_stamp(insertion_state.offset, auto_offset)
  local ins_offset = current_item.offset
  if stamp ~= nil then
    fields.offset = stamp
    ins_offset = stamp
  end

  local line =
    entry.format(fields, insertion_state.tag, insertion_state.location, insertion_state.offset)

  local result = support.insert_entry_edit(
    ctx.block,
    minutes,
    line,
    current_item.tag,
    current_item.location,
    ins_offset
  )

  if stamp ~= nil then
    result.offset_change = { from = insertion_state.offset, to = stamp }
  end

  return result
end

return M
