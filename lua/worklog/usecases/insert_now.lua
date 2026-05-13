local entry = require("worklog.entry")
local support = require("worklog.usecases.support")

local M = {}

-- Build the edit script for inserting a fresh timestamped line into the
-- worklog containing the cursor.

function M.run(lines, row, time)
  local ctx, err = support.get_validated_at_row(lines, row)
  if not ctx then
    return nil, err
  end

  local parsed_entry = entry.parse(time)
  local insert_index = support.get_insert_index(ctx.block, parsed_entry.minutes)

  return {
    edits = {
      {
        start_index = insert_index,
        end_index = insert_index,
        lines = { time .. " " },
      },
    },
    cursor = { insert_index + 1, #time + 1 },
    startinsert = true,
  }
end

return M
