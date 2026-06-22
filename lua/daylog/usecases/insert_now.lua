local support = require("daylog.usecases.support")

local M = {}

-- Build the edit script for inserting a fresh timestamped line into the
-- log containing the cursor.

function M.run(lines, row, time)
  local ctx, err = support.get_validated_at_row(lines, row)
  local minutes

  if not ctx then
    return nil, err
  end

  minutes, err = support.parse_clock_minutes(time)
  if not minutes then
    return nil, err
  end

  local insert_index = support.get_insert_index(ctx.block, minutes)

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
