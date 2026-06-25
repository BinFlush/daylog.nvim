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
-- works at two granularities, like :DaylogBalance: with the cursor on a main summary row
-- it maps every contributing entry (bulk), and with the cursor on an entry it maps just
-- that one (so you can map some entries of an activity and not others). The mapping rides
-- on the entry, so the summary stays a pure projection. An empty value clears the alias.
-- A logged (`!L`) entry is refused -- its committed value is tied to its current identity;
-- unlog, map, relog.

M.REFUSE_LOGGED = "daylog: refusing to map a logged entry; unlog it first"
M.NOT_MAPPABLE = "daylog: put the cursor on a summary row or an entry to map it"

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

  local alias
  for _, item in ipairs(ctx.block.entry_items) do
    if item.start_row == rows[1] then
      alias = item.alias
      break
    end
  end

  return { alias = alias }, nil
end

function M.run(lines, cursor_row, alias)
  local ctx, rows, err = resolve_targets(lines, cursor_row)
  if not ctx then
    return nil, err
  end
  if #rows == 0 then
    return nil, M.NOT_MAPPABLE
  end

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

  -- The summary region sits below the entries; apply it first (highest rows) so the
  -- source-entry edits below it stay valid.
  local edits = {}
  if region then
    local rebuilt = summary.summarize_entries(modified, ctx.block.quantize_minutes)
    edits[#edits + 1] = {
      start_index = region.start_row - 1,
      end_index = region.end_row - 1,
      lines = render.summary_lines(
        rebuilt,
        ctx.block.duration_format,
        support.summary_render_options(ctx.block)
      ),
    }
  end

  for _, edit in ipairs(source_edits) do
    edits[#edits + 1] = edit
  end

  table.sort(edits, function(a, b)
    return a.start_index > b.start_index
  end)

  return { edits = edits }
end

return M
