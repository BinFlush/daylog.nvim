local rename_summary = require("daylog.usecases.rename_summary")

local M = {}

-- Resolve a cursor on a multi-day report to a rename target (PURE).
--
-- Each report row is only a selector back to a recomputed summary item; this maps a 1-based
-- cursor row of the report layout to a rename target: an aggregate row renames across every day
-- of the period (the shell fans it out by value over all files), a per-day row in that one file.
-- The rewrite itself is per-file in rename_summary, so the report stays a pure projection.

M.NOT_A_ROW = "daylog: put the cursor on a summary item, tag, or location row of the report"

-- Map `cursor_row` (1-based) in `layout` to { scope, path?, date_label?, target }; `classify` turns a
-- layout row into the opaque `target` the caller's operation acts on (defaults to rename's classifier,
-- log passes its own). nil plus a message for a blank, header, or otherwise ineligible row.
function M.resolve(layout, cursor_row, classify)
  if type(cursor_row) ~= "number" then
    return nil, M.NOT_A_ROW
  end

  local row = layout[cursor_row]
  if not row then
    return nil, M.NOT_A_ROW
  end

  local target, err = (classify or rename_summary.classify)(row)
  if not target then
    return nil, err
  end

  return {
    scope = row.scope,
    path = row.path,
    date_label = row.date_label,
    target = target,
  }
end

return M
