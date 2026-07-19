local entry = require("daylog.entry")
local support = require("daylog.usecases.support")
local syntax = require("daylog.syntax")

local M = {}

-- Insert a fully-formed "HH:MM <text>" entry into the cursor's log; `text` is sanitized
-- (entry.sanitize_text) so external data (a work-item title ending in #x/@x/!L) can't form
-- trailing metadata.

function M.run(lines, row, time, text, auto_offset)
  local ctx, err = support.get_validated_at_row(lines, row)
  if not ctx then
    return nil, err
  end

  local minutes
  minutes, err = support.parse_clock_minutes(time)
  if not minutes then
    return nil, err
  end

  -- Inherit the sticky tag/location/offset at the insertion point: passing it as the entry's
  -- effective metadata makes entry.format emit no tokens and the follower rewrite a no-op, so the
  -- result is byte-identical to a hand-typed line and no following entry silently changes metadata.
  -- A drifted live offset is the exception: the entry takes the new offset and the follower is compensated.
  local state = support.get_insert_state(ctx.block, minutes)
  local stamp = support.offset_stamp(state.offset, auto_offset)
  local ins_offset = stamp or state.offset

  local fields = {
    minutes = minutes,
    text = entry.sanitize_text(text),
    tag = state.tag,
    location = state.location,
    offset = ins_offset,
  }
  -- An insert joins a claim of the cell it lands in when that fits the claim better; a bare insert
  -- into an unclaimed day gets nothing.
  fields.logged = support.auto_mark(ctx.block, fields, minutes)

  local inserted_line = entry.format(fields, state.tag, state.location, state.offset)

  local result = support.insert_entry_edit(
    ctx.block,
    minutes,
    inserted_line,
    state.tag,
    state.location,
    ins_offset
  )

  if stamp ~= nil then
    result.offset_change = { from = state.offset, to = stamp }
  end

  -- Enter insert mode so the user can keep typing the description. A drifted offset makes entry.format
  -- trail a `utc±H` token; land the cursor BEFORE it (startinsert = "cursor", like insert_now) so
  -- continued typing extends the description instead of being swallowed past the offset -- which would
  -- reparse the token into the text and silently drop the entry's offset. Otherwise append at EOL.
  local insert_index = support.get_insert_index(ctx.block, minutes)
  if stamp ~= nil then
    local utc_token = " " .. syntax.utc_offset_token(ins_offset)
    result.cursor = { insert_index + 1, #inserted_line - #utc_token }
    result.startinsert = "cursor"
  else
    result.cursor = { insert_index + 1, #inserted_line }
    result.startinsert = true
  end

  return result
end

return M
