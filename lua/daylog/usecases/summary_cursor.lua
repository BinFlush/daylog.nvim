local render = require("daylog.render")
local support = require("daylog.usecases.support")

local M = {}

-- Locate the summary row under the cursor (PURE).
--
-- Centralizes the "which summary row is the cursor on" question so :Daylog log/repeat/
-- rename share one staleness check: the active log is recomputed and the cursor line
-- matched by exact text against the layout the plugin would currently produce -- a row
-- that no longer matches is refused rather than acted on stale.

M.STALE = "daylog: summary row does not match the active log; regenerate the summary"
M.AMBIGUOUS = "daylog: summary row matches multiple rows; regenerate the summary"

-- Layout kinds a cursor can meaningfully select (not blanks or section headers).
local SELECTABLE = {
  [render.LAYOUT_KIND.SUMMARY_ITEM] = true,
  [render.LAYOUT_KIND.TAG_TOTAL] = true,
  [render.LAYOUT_KIND.LOCATION_TOTAL] = true,
  [render.LAYOUT_KIND.TOTAL] = true,
}

-- Resolve the cursor to a layout row of the active log's regenerated summary. Returns:
-- a result table on exactly one selectable row; nil, nil when not on the summary at all
-- (caller falls back, e.g. to an entry) -- with a third value carrying the validated
-- active-log context when found, so resolve_or_entry avoids re-analyzing; nil, message
-- when inside the summary but the row is stale (matches nothing) or ambiguous (several).
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
    return nil, nil, ctx
  end

  -- The region spans the active log's whole summary, so an earlier log's summary falls
  -- outside it and is correctly not selectable here.
  if cursor_row < region.start_row or cursor_row >= region.end_row then
    return nil, nil, ctx
  end

  local cursor_line = lines[cursor_row]
  local layout = render.summary_layout(recomputed, ctx.block.duration_format, {
    quantize_minutes = ctx.block.quantize_minutes,
  })

  local matches = {}
  local on_non_data_line = false
  for _, layout_row in ipairs(layout) do
    if layout_row.line == cursor_line then
      if SELECTABLE[layout_row.kind] then
        table.insert(matches, layout_row)
      else
        on_non_data_line = true -- a section header, banner, or blank of a current summary
      end
    end
  end

  if #matches == 0 then
    -- The cursor sits on a non-data line (header/banner/blank) of an up-to-date summary: it is not
    -- stale, just not selectable, so fall through to the caller's own "cursor on neither" message.
    if on_non_data_line then
      return nil, nil, ctx
    end
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

-- Shared prologue of the entry-changing summary commands: resolve the cursor to a summary
-- row OR an entry of the active log, parsing once. Returns the resolve result (carrying
-- `layout_row`) on a summary row; { ctx, entry_item = <item or nil> } on a valid log the
-- cursor is not on a row of; or nil, err for a stale/ambiguous row or no valid active log.
-- Callers branch on `layout_row` vs `entry_item` and supply their own "cursor on neither".
function M.resolve_or_entry(lines, cursor_row)
  local result, err, ctx = M.resolve(lines, cursor_row)
  if result then
    return result
  end
  if err then
    return nil, err
  end

  -- resolve declined without error: not on a summary row. It threaded the validated log
  -- when it had one; otherwise re-validate to surface the precise reason.
  if not ctx then
    local ctx_err
    ctx, ctx_err = support.get_validated_active(lines)
    if not ctx then
      return nil, ctx_err
    end
  end

  return { ctx = ctx, entry_item = support.entry_item_at_row(ctx.block, cursor_row) }
end

M.ONLY_MAIN_ROW = "daylog: only a main summary row can be repeated"

-- Map a cursor on a main summary row to the latest source entry row that fed it (it
-- carries the activity's most recent tag/location), so "repeat" works from the summary.
-- Returns the entry row, or nil + err -- a nil err means the cursor is not on the summary,
-- so the caller keeps its own entry-lookup error.
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
