local rename_summary = require("daylog.usecases.rename_summary")

local M = {}

-- Resolve a cursor on a multi-day report to a rename target (PURE).
--
-- The :DaylogDays report is a read-only projection of several days'
-- summaries. Like the in-file summary, each rendered row is only a selector: it
-- points back at a recomputed summary item. This module maps a 1-based cursor row of
-- the flat report layout (render.days_report_layout) to which
-- logs to rewrite and what item to rename:
--
--   * an aggregate row renames the item across every day of the period (the shell
--     fans the rename out, by value, over all the day files);
--   * a per-day row renames it in that one day's file.
--
-- The actual rewrite is done per file by rename_summary.run_by_value, so the report
-- stays a pure projection -- this only decides the target and the file scope.

M.NOT_A_ROW = "daylog: put the cursor on a summary item, tag, or location row of the report"

-- Map `cursor_row` (1-based) within `layout` to { scope, path?, date_label?, target }
-- where `target` is the { kind, current, tag? } rename_summary acts on. Returns nil
-- plus a message for a blank, header, or totals row (nothing renamable there).
function M.resolve(layout, cursor_row)
  if type(cursor_row) ~= "number" then
    return nil, M.NOT_A_ROW
  end

  local row = layout[cursor_row]
  if not row then
    return nil, M.NOT_A_ROW
  end

  local target, err = rename_summary.classify(row)
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
