local analyze = require("blotter.analyze")
local blot = require("blotter.blot")
local summary_cursor = require("blotter.usecases.summary_cursor")
local support = require("blotter.usecases.support")

local M = {}

-- Build the edit script for repeating the current activity at a new time. The
-- cursor may sit on a timestamped blot or on a main summary row; the latter is
-- mapped back to the source blot it summarizes (see summary_cursor).

function M.run(lines, row, time)
  local ctx, err = support.get_validated_at_row(lines, row)

  if not ctx then
    -- The cursor may be on a main summary row; map it back to the source blot
    -- and repeat that, into the blotter the summary belongs to. A nil summary
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
  for _, item in ipairs(ctx.block.blot_items) do
    if item.blot.row == row then
      current_item = item
      break
    end
  end

  if not current_item then
    return nil, "blotter: current line is not a valid blot"
  end

  local minutes, minutes_err = support.parse_clock_minutes(time)
  if not minutes then
    return nil, minutes_err
  end

  local insertion_state = support.get_insert_state(ctx.block, minutes)

  -- A repeat is a fresh blot: it copies the activity's metadata from the source but
  -- takes the new time and never inherits the source's logged or round±N marker.
  local fields = analyze.copy_fields(current_item)
  fields.minutes = minutes
  fields.logged = false
  fields.nudge = nil

  local line =
    blot.format(fields, insertion_state.tag, insertion_state.location, insertion_state.offset)

  return support.insert_blot_edit(
    ctx.block,
    minutes,
    line,
    current_item.tag,
    current_item.location,
    current_item.offset
  )
end

return M
