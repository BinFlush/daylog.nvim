local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")

local M = {}

-- Toggle the logged state of the main summary row under the cursor.
--
-- A log has a single summary. The rendered row is only a selector: the active
-- log is analyzed from source, the matching summary item is recomputed, the
-- contributing source entries gain or lose a trailing !L, and the one summary is
-- rebuilt from the updated source. The summary is a pure projection, so the rebuild
-- needs no note preservation.
--
-- The cursor-to-row resolution and its staleness/ambiguity guard are the shared
-- summary_cursor.resolve; :DaylogLog accepts only a main summary_item row (a tag,
-- location, logged, or total row is not loggable). Out-of-office rows cannot be
-- marked, and the contributing entries must already agree on their logged state.

local REFUSE_OOO = "daylog: refusing to mark out-of-office time as logged"
local INCONSISTENT_SOURCE = "daylog: logged marking is inconsistent; regenerate the summary"

-- Everything that decides which summary row an interval folds into, except `logged`,
-- so an about-to-be-logged row can find the already-logged row it will merge with.
local function activity_key(row)
  return table.concat({
    row.text or "",
    row.tag or "",
    row.location or "",
    row.workday_excluded and "1" or "0",
  }, "\0")
end

-- The frozen committed value to stamp on each source entry when marking !L. Marking a
-- row logged merges it with any already-logged row of the same activity, so the new
-- commitment is the SUM of the two rows' currently displayed durations -- and, because
-- the value is replicated per row, it must be written onto EVERY entry in the merged
-- row: the ones logged now AND the ones already logged (whose value grows to the new
-- total). Computed from the pre-mark summary (rows still separate here), keyed by
-- source entry row. Returns the map for the target rows and the rows they absorb.
local function frozen_values(block, target_rows)
  local rows = summary.fine_grained_quantized(block.entries, block.quantize_minutes)

  local logged_by_key = {}
  for _, row in ipairs(rows) do
    if row.logged then
      logged_by_key[activity_key(row)] = row
    end
  end

  local frozen = {}
  for _, row in ipairs(rows) do
    if not row.logged then
      local is_target = false
      for _, source_row in ipairs(row.source_entry_rows or {}) do
        if target_rows[source_row] then
          is_target = true
          break
        end
      end

      if is_target then
        local existing = logged_by_key[activity_key(row)]
        local combined = row.duration + (existing and existing.duration or 0)
        for _, source_row in ipairs(row.source_entry_rows or {}) do
          frozen[source_row] = combined
        end
        if existing then
          for _, source_row in ipairs(existing.source_entry_rows or {}) do
            frozen[source_row] = combined
          end
        end
      end
    end
  end

  return frozen
end

-- Recompute the summary with `logged` toggled, by copying the block's semantic entries
-- and flipping them in memory. This avoids re-parsing the buffer and yields the
-- post-mark summary directly. On mark, every entry the merge touches (in `frozen` --
-- the newly logged rows and any already-logged row they absorb) takes the combined
-- value; on unmark the target entries clear both fields so no stale value lingers.
local function rebuilt_summary(block, target_rows, target_logged, frozen)
  local entries = support.modified_entries(block, function(copy)
    if target_logged then
      if frozen[copy.row] ~= nil then
        copy.logged = true
        copy.logged_minutes = frozen[copy.row]
      end
    elseif target_rows[copy.row] then
      copy.logged = false
      copy.logged_minutes = nil
    end
  end)

  return summary.summarize_entries(entries, block.quantize_minutes)
end

function M.run(lines, cursor_row)
  local result, err = summary_cursor.resolve(lines, cursor_row)
  if not result then
    -- resolve surfaces STALE/AMBIGUOUS directly. On a silent decline -- the cursor is
    -- not on the active log's summary, or that log is invalid -- surface the
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

  local frozen = target_logged and frozen_values(block, target_rows) or {}

  local source_edits = support.rewrite_entry_lines(block, function(entry_item)
    if target_logged then
      -- `frozen` covers every entry in the merged row: the target entries and any
      -- already-logged entries absorbed into it, all stamped with the combined total.
      if frozen[entry_item.start_row] ~= nil then
        return { logged = true, logged_minutes = frozen[entry_item.start_row] }
      end
    elseif target_rows[entry_item.start_row] then
      return { logged = false }
    end
  end)

  local rebuilt = rebuilt_summary(block, target_rows, target_logged, frozen)
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
