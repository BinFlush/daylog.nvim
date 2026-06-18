local entry = require("worklog.entry")
local support = require("worklog.usecases.support")

local M = {}

-- Insert a fully-formed "HH:MM <text>" entry into the worklog containing the
-- cursor. `text` is the resolved activity string (no leading timestamp); it is
-- sanitized here (entry.sanitize_text) so a value built from external data -- e.g.
-- a work-item title ending in #x / @x / !L -- can never form trailing metadata,
-- regardless of the source. A sibling of insert_now: that one stamps a bare
-- timestamp, this one stamps a timestamp plus an activity.

function M.run(lines, row, time, text)
  local ctx, err = support.get_validated_at_row(lines, row)
  if not ctx then
    return nil, err
  end

  local minutes
  minutes, err = support.parse_clock_minutes(time)
  if not minutes then
    return nil, err
  end

  -- Inherit the sticky tag/location/offset at the insertion point. Passing that
  -- same state as the entry's effective metadata makes entry.format emit no tokens,
  -- and passing it to insert_entry_edit makes the follower rewrite a guaranteed
  -- no-op -- so the result is byte-identical to a hand-typed "HH:MM <text>" and no
  -- following entry silently changes tag, location, or offset.
  local state = support.get_insert_state(ctx.block, minutes)
  local inserted_line = entry.format({
    minutes = minutes,
    text = entry.sanitize_text(text),
    tag = state.tag,
    location = state.location,
    offset = state.offset,
    logged = false,
  }, state.tag, state.location, state.offset)

  local result = support.insert_entry_edit(
    ctx.block,
    minutes,
    inserted_line,
    state.tag,
    state.location,
    state.offset
  )

  -- Land the cursor at end of the inserted line and enter insert mode, matching
  -- insert_now's affordance so the user can keep typing notes.
  local insert_index = support.get_insert_index(ctx.block, minutes)
  result.cursor = { insert_index + 1, #inserted_line }
  result.startinsert = true

  return result
end

return M
