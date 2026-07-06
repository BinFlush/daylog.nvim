local support = require("daylog.usecases.support")
local syntax = require("daylog.syntax")

local M = {}

-- Build the edit script inserting a fresh timestamped line into the cursor's log; a drift in
-- `auto_offset` (live OS offset) records the new zone on the entry.

function M.run(lines, row, time, auto_offset)
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
  local state = support.get_insert_state(ctx.block, minutes)
  local stamp = support.offset_stamp(state.offset, auto_offset)

  local result
  if stamp ~= nil then
    -- The zone drifted: record it so the interval stays correct. The utc token must trail the
    -- not-yet-typed activity, so place it after a two-space gutter and land the cursor in the gap
    -- (startinsert = "cursor" keeps insert mode AT the gap); insert_entry_edit also compensates a
    -- follower inheriting the old offset.
    local inserted_line = time .. "  " .. syntax.utc_offset_token(stamp)
    result =
      support.insert_entry_edit(ctx.block, minutes, inserted_line, state.tag, state.location, stamp)
    result.offset_change = { from = state.offset, to = stamp }
    result.startinsert = "cursor"
  else
    result = {
      edits = {
        {
          start_index = insert_index,
          end_index = insert_index,
          lines = { time .. " " },
        },
      },
      startinsert = true,
    }
  end

  result.cursor = { insert_index + 1, #time + 1 }
  return result
end

return M
