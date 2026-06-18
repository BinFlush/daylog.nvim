local entry = require("worklog.entry")
local summary_cursor = require("worklog.usecases.summary_cursor")
local support = require("worklog.usecases.support")

local M = {}

-- Build the edit script for repeating the current activity at a new time. The
-- cursor may sit on a timestamped entry or on a main summary row; the latter is
-- mapped back to the source entry it summarizes (see summary_cursor).

function M.run(lines, row, time)
  local ctx, err = support.get_validated_at_row(lines, row)

  if not ctx then
    -- The cursor may be on a main summary row; map it back to the source entry
    -- and repeat that, into the worklog the summary belongs to. A nil summary
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
    return nil, "worklog: current line is not a valid worklog entry"
  end

  local minutes, minutes_err = support.parse_clock_minutes(time)
  if not minutes then
    return nil, minutes_err
  end

  local insertion_state = support.get_insert_state(ctx.block, minutes)

  local line = entry.format({
    minutes = minutes,
    text = current_item.text,
    explicit_tag = current_item.explicit_tag,
    explicit_tag_clear = current_item.explicit_tag_clear,
    explicit_location = current_item.explicit_location,
    explicit_location_clear = current_item.explicit_location_clear,
    tag = current_item.tag,
    location = current_item.location,
    offset = current_item.offset,
    workday_excluded = current_item.workday_excluded,
    logged = false,
  }, insertion_state.tag, insertion_state.location, insertion_state.offset)

  return support.insert_entry_edit(
    ctx.block,
    minutes,
    line,
    current_item.tag,
    current_item.location,
    current_item.offset
  )
end

return M
