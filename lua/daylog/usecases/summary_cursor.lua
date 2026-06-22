local render = require("daylog.render")
local support = require("daylog.usecases.support")

local M = {}

-- Locate the summary row under the cursor (PURE).
--
-- Several commands act on a rendered summary row as a selector: the active
-- log is analyzed from source, its summary is recomputed, and the cursor line
-- is matched against the layout the plugin would currently produce. This module
-- centralizes that "which summary row is the cursor on" question so :DaylogLog,
-- :DaylogRepeat (on a summary row), and :DaylogRename share one staleness check.
--
-- The summary is a pure projection, so the rendered row carries no authority: it
-- only points back at recomputed `summary_items` / `tag_totals` / `location_totals`
-- (each of which knows its contributing source entries). Matching by exact line
-- text -- against the freshly recomputed layout -- is the staleness guard: a row
-- that no longer matches is refused rather than acted on stale.

M.STALE = "daylog: summary row does not match the active log; regenerate the summary"
M.AMBIGUOUS = "daylog: summary row matches multiple rows; regenerate the summary"

-- Layout kinds a cursor can meaningfully select (everything but blanks and the
-- section headers).
local SELECTABLE = {
  [render.LAYOUT_KIND.SUMMARY_ITEM] = true,
  [render.LAYOUT_KIND.TAG_TOTAL] = true,
  [render.LAYOUT_KIND.LOCATION_TOTAL] = true,
  [render.LAYOUT_KIND.LOGGED_TOTAL] = true,
  [render.LAYOUT_KIND.TOTAL] = true,
}

-- Resolve the cursor to a layout row of the active log's regenerated summary.
--
-- Returns, in order of specificity:
--   * result table when the cursor sits on exactly one selectable summary row;
--   * nil, nil when the cursor is not on the active log's summary at all
--     (the caller should fall back to its own handling, e.g. an entry);
--   * nil, message when the cursor is inside the summary region but the row is
--     stale (matches nothing) or ambiguous (matches several rows).
--
-- The result carries the active-log context, the located region, the
-- recomputed summary, the full layout, and the single matched layout row so
-- callers can read its `kind`/`item` and rebuild the summary in place.
function M.resolve(lines, cursor_row)
  if type(cursor_row) ~= "number" or cursor_row < 1 or cursor_row > #lines then
    return nil, nil
  end

  local ctx = support.get_validated_active(lines)
  if not ctx then
    return nil, nil
  end

  local region, recomputed = support.locate_summary(ctx.analysis, ctx.block)
  if not region then
    return nil, nil
  end

  -- The region spans the whole rendered summary (every section) within the active
  -- log's tail, so a summary owned by an earlier log falls outside it and
  -- is correctly not selectable here.
  if cursor_row < region.start_row or cursor_row >= region.end_row then
    return nil, nil
  end

  local cursor_line = lines[cursor_row]
  local layout = render.summary_layout(recomputed, ctx.block.duration_format, {
    quantize_minutes = ctx.block.quantize_minutes,
  })

  local matches = {}
  for _, layout_row in ipairs(layout) do
    if SELECTABLE[layout_row.kind] and layout_row.line == cursor_line then
      table.insert(matches, layout_row)
    end
  end

  if #matches == 0 then
    return nil, M.STALE
  end

  if #matches > 1 then
    return nil, M.AMBIGUOUS
  end

  return {
    ctx = ctx,
    region = region,
    recomputed = recomputed,
    layout = layout,
    layout_row = matches[1],
  }
end

M.ONLY_MAIN_ROW = "daylog: only a main summary row can be repeated"

-- Map a cursor on a main summary row to the latest source entry row that fed it,
-- so "repeat this activity" works from the summary. The latest contributing entry
-- carries the most recent tag/location for the activity. Returns the entry row, or
-- nil + an error -- a nil error means the cursor is not on the active log's
-- summary at all, so the caller keeps its own (entry-lookup) error.
function M.repeat_entry_row(lines, cursor_row)
  local result, err = M.resolve(lines, cursor_row)
  if not result then
    return nil, err
  end

  if result.layout_row.kind ~= render.LAYOUT_KIND.SUMMARY_ITEM then
    return nil, M.ONLY_MAIN_ROW
  end

  local latest
  for _, source_row in ipairs(result.layout_row.item.source_entry_rows or {}) do
    if not latest or source_row > latest then
      latest = source_row
    end
  end

  if not latest then
    return nil, M.STALE
  end

  return latest
end

return M
