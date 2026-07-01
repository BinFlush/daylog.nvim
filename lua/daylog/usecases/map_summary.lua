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
-- line range (a visual selection) it maps every entry line in the range and expands every
-- summary row in the range to the entries feeding it -- so selecting a span of summary rows
-- collapses those activities under one label. The mapping rides on the entry, so the summary
-- stays a pure projection. An empty value clears the alias. A logged (`!S`) entry is refused
-- -- its committed value is tied to its current identity; unlog, map, relog.

M.REFUSE_LOGGED = "daylog: refusing to map a logged entry; unlog it first"
M.NOT_MAPPABLE = "daylog: put the cursor on a summary row or an entry to map it"
M.NO_RANGE_ENTRIES = "daylog: nothing in the selection to map"

-- The source entry rows feeding a main summary row: its interval contributors plus a
-- same-activity closing entry. The closing entry starts no interval, so it is absent from
-- source_entry_rows; include it when its activity matches the row, so a same-activity closer
-- is mapped too.
local function item_source_rows(block, item)
  local rows = {}
  for _, row in ipairs(item.source_entry_rows or {}) do
    rows[#rows + 1] = row
  end
  local closing = summary.closing_entry_row_for(block.entries, item)
  if closing then
    rows[#rows + 1] = closing
  end
  return rows
end

-- The target entry rows for the cursor: a main summary row's source entries, or a single
-- entry under the cursor. Returns ctx, rows, err.
local function resolve_targets(lines, cursor_row)
  local result, resolve_err = summary_cursor.resolve_or_entry(lines, cursor_row)
  if not result then
    return nil, nil, resolve_err or M.NOT_MAPPABLE
  end

  if result.layout_row then
    if result.layout_row.kind ~= render.LAYOUT_KIND.SUMMARY_ITEM then
      return nil, nil, M.NOT_MAPPABLE
    end

    return result.ctx, item_source_rows(result.ctx.block, result.layout_row.item), nil
  end

  if result.entry_item then
    return result.ctx, { result.entry_item.start_row }, nil
  end

  return nil, nil, M.NOT_MAPPABLE
end

-- The active log's target entry rows for a [r1, r2] line range -- a visual selection. Each
-- entry line maps itself; each main summary row in the range expands to the entries feeding
-- it, so a span of summary rows collapses those activities together. Structural lines
-- (headers, blanks, total rows) and any other log's lines contribute nothing, and a selection
-- with no mappable target is refused. Returns ctx, rows, err.
local function resolve_range_targets(lines, r1, r2)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, nil, err or M.NOT_MAPPABLE
  end

  local lo, hi = math.min(r1, r2), math.max(r1, r2)
  local rows, seen = {}, {}
  local function add(row)
    if not seen[row] then
      seen[row] = true
      rows[#rows + 1] = row
    end
  end

  for row = lo, hi do
    local item = support.entry_item_at_row(ctx.block, row)
    if item then
      add(item.start_row)
    else
      -- A summary item row expands to every entry feeding it. A resolve error (STALE for the
      -- header / blanks inside the region, AMBIGUOUS) means "not a mappable row here", so it
      -- is skipped exactly like a non-entry body line rather than refusing the whole range.
      local result = summary_cursor.resolve(lines, row)
      if result and result.layout_row.kind == render.LAYOUT_KIND.SUMMARY_ITEM then
        for _, source_row in ipairs(item_source_rows(ctx.block, result.layout_row.item)) do
          add(source_row)
        end
      end
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

-- Set `alias` (empty clears) on every entry in `rows`, refusing the whole edit if any entry that
-- would actually change is logged. Mapping an entry onto its own description is a no-op -- a bare row
-- and `text => text` resolve identically -- so the target's bare form is the desired state: a ranged
-- map of several items onto one of them (a,b,c,d,e => c) leaves c untouched rather than writing a
-- redundant `c => c`, and a row already at the requested state contributes no edit. The override map
-- then drives both the source-line rewrite and the rebuilt projection through
-- support.apply_entry_overrides, so they agree by construction.
local function apply_alias(ctx, rows, alias)
  local value = entry.sanitize_alias(alias)

  local target = {}
  for _, row in ipairs(rows) do
    target[row] = true
  end

  local overrides = {}
  for _, item in ipairs(ctx.block.entry_items) do
    if target[item.start_row] then
      local desired = (value == item.text) and "" or value
      if desired ~= (item.alias or "") then
        if item.logged and item.logged.s then
          return nil, M.REFUSE_LOGGED
        end
        overrides[item.start_row] = { alias = desired }
      end
    end
  end

  local result = support.apply_entry_overrides(ctx.analysis, ctx.block, overrides)
  return result
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

-- M.run over a [r1, r2] line range (a visual selection): map every entry line in the range,
-- and collapse every summary row in the range to the entries feeding it.
function M.run_range(lines, r1, r2, alias)
  local ctx, rows, err = resolve_range_targets(lines, r1, r2)
  if not ctx then
    return nil, err
  end

  return apply_alias(ctx, rows, alias)
end

return M
