local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")

local M = {}

-- Build the edit script repeating the current activity at a new time; a cursor on a summary
-- row is mapped back to the source entry it summarizes (see summary_cursor).

function M.run(lines, row, time, auto_offset)
  local ctx, err = support.get_validated_at_row(lines, row)
  local from_summary = false

  if not ctx then
    -- A cursor on a summary row maps back to its source entry; a nil summary error means the
    -- cursor isn't on the summary, so keep `err`.
    local entry_row, summary_err = summary_cursor.repeat_entry_row(lines, row)
    if not entry_row then
      return nil, summary_err or err
    end

    from_summary = true
    row = entry_row
    ctx, err = support.get_validated_at_row(lines, row)
    if not ctx then
      return nil, err
    end
  end

  local current_item = support.entry_item_at_row(ctx.block, row)
  if not current_item then
    return nil, "daylog: current line is not a valid entry"
  end

  -- The summary shows only the resolved label, so repeating from it brings that in as a bare entry --
  -- never the source row's hidden `lhs => rhs` mapping.
  if from_summary then
    current_item = support.resolved_bare_item(current_item)
  end

  local minutes, minutes_err = support.parse_clock_minutes(time)
  if not minutes then
    return nil, minutes_err
  end

  return support.fresh_entry_edit(ctx.block, current_item, minutes, auto_offset)
end

return M
