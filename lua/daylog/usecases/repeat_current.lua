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

  return support.fresh_entry_edit(ctx.block, current_item, minutes, auto_offset)
end

return M
