local entry = require("daylog.entry")
local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")

local M = {}

-- Set or clear an entry's mapping alias (PURE).
--
-- An alias (` => label`) makes an entry resolve to `label` in the summary -- it counts
-- toward, and is shown as, that target, while the entry keeps its descriptive text. This
-- works at three granularities: with the cursor on a main summary row it maps every
-- contributing entry (bulk), with the cursor on an entry it maps just that one, and over a
-- line range (a visual selection) it maps every entry line in the range. The mapping rides
-- on the entry, so the summary stays a pure projection. An empty value clears the alias.
-- A logged (`!L`) entry is refused -- its committed value is tied to its current identity;
-- unlog, map, relog.

M.REFUSE_LOGGED = "daylog: refusing to map a logged entry; unlog it first"
M.NOT_MAPPABLE = "daylog: put the cursor on a summary row or an entry to map it"
M.NO_RANGE_ENTRIES = "daylog: no entries in the selection to map"

-- The target entry rows for the cursor: a main summary row's source entries, or a single
-- entry under the cursor. Returns ctx, rows, err.
local function resolve_targets(lines, cursor_row)
  local result, resolve_err = summary_cursor.resolve(lines, cursor_row)
  if result then
    if result.layout_row.kind ~= render.LAYOUT_KIND.SUMMARY_ITEM then
      return nil, nil, M.NOT_MAPPABLE
    end

    local item = result.layout_row.item
    local rows = {}
    for _, row in ipairs(item.source_entry_rows or {}) do
      rows[#rows + 1] = row
    end
    -- The closing entry contributes no interval, so it is absent from source_entry_rows;
    -- include it when its activity matches the row, so a same-activity closer is mapped too.
    local closing = summary.closing_entry_row_for(result.ctx.block.entries, item)
    if closing then
      rows[#rows + 1] = closing
    end

    return result.ctx, rows, nil
  end

  if resolve_err then
    return nil, nil, resolve_err
  end

  local ctx, ctx_err = support.get_validated_active(lines)
  if not ctx then
    return nil, nil, ctx_err or M.NOT_MAPPABLE
  end

  for _, item in ipairs(ctx.block.entry_items) do
    if item.start_row == cursor_row then
      return ctx, { cursor_row }, nil
    end
  end

  return nil, nil, M.NOT_MAPPABLE
end

-- The active log's entry rows whose line falls within [r1, r2] -- a visual selection.
-- Non-entry lines (header, blank, the summary) and entries in any other log are ignored;
-- a selection that covers no active-log entries is refused. Returns ctx, rows, err.
local function resolve_range_targets(lines, r1, r2)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, nil, err or M.NOT_MAPPABLE
  end

  local lo, hi = math.min(r1, r2), math.max(r1, r2)
  local rows = {}
  for _, item in ipairs(ctx.block.entry_items) do
    if item.start_row >= lo and item.start_row <= hi then
      rows[#rows + 1] = item.start_row
    end
  end

  if #rows == 0 then
    return nil, nil, M.NO_RANGE_ENTRIES
  end

  return ctx, rows, nil
end

-- The current alias of the first target entry, for a prompt default.
local function first_alias(ctx, rows)
  for _, item in ipairs(ctx.block.entry_items) do
    if item.start_row == rows[1] then
      return item.alias
    end
  end
  return nil
end

-- Set `alias` (empty clears) on every entry in `rows`, refusing the whole edit if any is
-- logged, then rebuild the one summary. The target set drives both the source-line rewrite
-- and the recomputed projection.
local function apply_alias(ctx, rows, alias)
  local value = entry.sanitize_alias(alias)

  local target = {}
  for _, row in ipairs(rows) do
    target[row] = true
  end

  for _, item in ipairs(ctx.block.entry_items) do
    if target[item.start_row] and item.logged then
      return nil, M.REFUSE_LOGGED
    end
  end

  local source_edits = support.rewrite_entry_lines(ctx.block, function(item)
    if target[item.start_row] then
      return { alias = value }
    end
  end)

  local modified = support.modified_entries(ctx.block, function(copy)
    if target[copy.row] then
      copy.alias = value
    end
  end)

  local region = support.locate_summary(ctx.analysis, ctx.block)
  local summary_edit = support.summary_edit(ctx.block, modified, region)

  return { edits = support.entry_change_edits(summary_edit, source_edits) }
end

-- Validate the cursor is on a mappable target and report the current alias of its first
-- entry (for a prompt default), without editing. Lets the shell fail before any async
-- picker. Returns { alias = <current or nil> }, or nil, err.
function M.peek(lines, cursor_row)
  local ctx, rows, err = resolve_targets(lines, cursor_row)
  if not ctx then
    return nil, err
  end
  if #rows == 0 then
    return nil, M.NOT_MAPPABLE
  end

  return { alias = first_alias(ctx, rows) }, nil
end

-- M.peek over a [r1, r2] line range (a visual selection) rather than the cursor.
function M.peek_range(lines, r1, r2)
  local ctx, rows, err = resolve_range_targets(lines, r1, r2)
  if not ctx then
    return nil, err
  end

  return { alias = first_alias(ctx, rows) }, nil
end

function M.run(lines, cursor_row, alias)
  local ctx, rows, err = resolve_targets(lines, cursor_row)
  if not ctx then
    return nil, err
  end
  if #rows == 0 then
    return nil, M.NOT_MAPPABLE
  end

  return apply_alias(ctx, rows, alias)
end

-- M.run over a [r1, r2] line range (a visual selection): map every entry line in the range.
function M.run_range(lines, r1, r2, alias)
  local ctx, rows, err = resolve_range_targets(lines, r1, r2)
  if not ctx then
    return nil, err
  end

  return apply_alias(ctx, rows, alias)
end

return M
