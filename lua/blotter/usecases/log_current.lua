local render = require("blotter.render")
local summary = require("blotter.summary")
local summary_cursor = require("blotter.usecases.summary_cursor")
local support = require("blotter.usecases.support")

local M = {}

-- Toggle the logged state of the main summary row under the cursor.
--
-- A worklog has a single summary. The rendered row is only a selector: the active
-- worklog is analyzed from source, the matching summary item is recomputed, the
-- contributing source entries gain or lose a trailing !L, and the one summary is
-- rebuilt from the updated source. The summary is a pure projection, so the rebuild
-- needs no note preservation.
--
-- The cursor-to-row resolution and its staleness/ambiguity guard are the shared
-- summary_cursor.resolve; :WorklogLog accepts only a main summary_item row (a tag,
-- location, logged, or total row is not loggable). Out-of-office rows cannot be
-- marked, and the contributing entries must already agree on their logged state.

local REFUSE_OOO = "worklog: refusing to mark out-of-office time as logged"
local INCONSISTENT_SOURCE = "worklog: logged marking is inconsistent; regenerate the summary"

-- Recompute the summary with `logged` toggled on the target source rows, by copying
-- the block's semantic entries and flipping them in memory. This avoids re-parsing
-- the buffer and yields the post-mark summary directly.
local function rebuilt_summary(block, target_rows, target_logged)
  local entries = support.modified_entries(block, function(copy)
    if target_rows[copy.row] then
      copy.logged = target_logged
    end
  end)

  return summary.summarize_entries(entries, block.quantize_minutes)
end

function M.run(lines, cursor_row)
  local result, err = summary_cursor.resolve(lines, cursor_row)
  if not result then
    -- resolve surfaces STALE/AMBIGUOUS directly. On a silent decline -- the cursor is
    -- not on the active worklog's summary, or that worklog is invalid -- surface the
    -- precise reason (a block diagnostic when present), else the generic stale message.
    if err then
      return nil, err
    end

    local _, validate_err = support.get_validated_active(lines)
    return nil, validate_err or summary_cursor.STALE
  end

  -- Only a main summary row carries loggable source entries; a tag / location /
  -- logged / total row is not loggable.
  if result.layout_row.kind ~= render.LAYOUT_KIND.SUMMARY_ITEM then
    return nil, summary_cursor.STALE
  end

  local block = result.ctx.block
  local item = result.layout_row.item
  local target_logged = not item.logged

  if target_logged and item.workday_excluded then
    return nil, REFUSE_OOO
  end

  local source_rows = item.source_entry_rows or {}
  if #source_rows == 0 then
    return nil, summary_cursor.STALE
  end

  local target_rows = {}
  for _, source_row in ipairs(source_rows) do
    target_rows[source_row] = true
  end

  for _, entry_item in ipairs(block.entry_items) do
    if
      target_rows[entry_item.start_row] and (entry_item.logged == true) ~= (item.logged == true)
    then
      return nil, INCONSISTENT_SOURCE
    end
  end

  local source_edits = support.rewrite_entry_lines(block, function(entry_item)
    if target_rows[entry_item.start_row] then
      return { logged = target_logged }
    end
  end)

  local rebuilt = rebuilt_summary(block, target_rows, target_logged)
  local rendered =
    render.summary_lines(rebuilt, block.duration_format, support.summary_render_options(block))

  -- The summary rebuild targets higher rows than the source-entry edits, so it is
  -- applied first to avoid index drift when the rendered summary changes size.
  local all_edits = {
    {
      start_index = result.region.start_row - 1,
      end_index = result.region.end_row - 1,
      lines = rendered,
    },
  }
  for _, edit in ipairs(source_edits) do
    table.insert(all_edits, edit)
  end

  return { edits = all_edits }
end

return M
