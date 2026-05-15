local entry = require("worklog.entry")
local support = require("worklog.usecases.support")

local M = {}

-- Build the edit script for repeating the current activity at a new time.

function M.run(lines, row, _current_line, time)
  local ctx, err = support.get_validated_at_row(lines, row)
  local current_item = nil
  local insertion_state = nil

  if not ctx then
    return nil, err
  end

  for _, item in ipairs(ctx.block.items) do
    if item.entry.row == row then
      current_item = item
      break
    end
  end

  if not current_item then
    return nil, "worklog: current line is not a valid worklog entry"
  end

  local minutes = entry.parse(time).minutes
  insertion_state = support.get_insert_state(ctx.block, minutes)

  local ok, representable_err = entry.is_representable(current_item, insertion_state.tag, insertion_state.location)
  if not ok then
    return nil, representable_err
  end

  local line = entry.format({
    minutes = minutes,
    text = current_item.text,
    tag = current_item.tag,
    location = current_item.location,
    excluded = current_item.excluded,
  }, insertion_state.tag, insertion_state.location)
  local insert_index = support.get_insert_index(ctx.block, minutes)

  return {
    edits = {
      {
        start_index = insert_index,
        end_index = insert_index,
        lines = { line },
      },
    },
  }
end

return M
