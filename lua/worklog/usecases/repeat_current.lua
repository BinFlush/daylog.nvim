local entry = require("worklog.entry")
local support = require("worklog.usecases.support")

local M = {}

-- Build the edit script for repeating the current activity at a new time.

function M.run(lines, row, time)
  local ctx, err = support.get_validated_at_row(lines, row)
  local current_item = nil
  local minutes

  if not ctx then
    return nil, err
  end

  for _, item in ipairs(ctx.block.entry_items) do
    if item.entry.row == row then
      current_item = item
      break
    end
  end

  if not current_item then
    return nil, "worklog: current line is not a valid worklog entry"
  end

  minutes, err = support.parse_clock_minutes(time)
  if not minutes then
    return nil, err
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
    workday_excluded = current_item.workday_excluded,
    logged = false,
  }, insertion_state.tag, insertion_state.location)

  return support.insert_entry_edit(
    ctx.block,
    minutes,
    line,
    current_item.tag,
    current_item.location
  )
end

return M
