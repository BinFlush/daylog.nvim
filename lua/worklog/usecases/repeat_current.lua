local entry = require("worklog.entry")
local support = require("worklog.usecases.support")

local M = {}

-- Build the edit script for repeating the current activity at a new time.

function M.run(lines, row, current_line, time)
  local ctx, err = support.get_validated_at_row(lines, row)
  if not ctx then
    return nil, err
  end

  local current_entry = entry.parse(current_line, ctx.default_label)
  if not current_entry or current_entry == false then
    return nil, "worklog: current line is not a valid worklog entry"
  end

  local minutes = entry.parse(time).minutes
  local line = entry.format({
    minutes = minutes,
    text = current_entry.text,
    label = current_entry.label,
    excluded = current_entry.excluded,
  }, ctx.default_label)
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
