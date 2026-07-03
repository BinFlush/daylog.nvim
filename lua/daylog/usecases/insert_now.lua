local support = require("daylog.usecases.support")
local syntax = require("daylog.syntax")

local M = {}

-- Build the edit script for inserting a fresh timestamped line into the
-- log containing the cursor. `auto_offset` (optional) is the live OS offset; when it
-- has drifted from the offset in effect (DST/travel), the entry records the new zone.

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
    -- The zone drifted: record it so this entry's interval stays correct. The token
    -- must trail the activity, which the user has not typed yet, so place it after a
    -- two-space gutter and land the cursor in the gap (#time + 1) -- typing then yields
    -- the canonical "HH:MM <text> utc±N". insert_entry_edit also compensates a follower
    -- that was silently inheriting the old offset. `startinsert = "cursor"` keeps insert
    -- mode AT the gap; a plain append would land the typed text after the utc token.
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
