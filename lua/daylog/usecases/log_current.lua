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
      logged_by_key[summary.activity_identity_key(row)] = row
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
        local existing = logged_by_key[summary.activity_identity_key(row)]
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

function M.run(lines, cursor_row)
  local result, err = summary_cursor.resolve_or_entry(lines, cursor_row)
  if not result then
    return nil, err
  end

  -- Only a main summary row carries loggable source entries; an entry, a tag /
  -- location / logged / total row, or the cursor on nothing is not loggable.
  if not result.layout_row or result.layout_row.kind ~= render.LAYOUT_KIND.SUMMARY_ITEM then
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

  -- One override per affected entry drives both the source-line rewrite and the summary rebuild,
  -- so they cannot disagree. On mark, every entry the merge touches (`frozen` -- the newly logged
  -- rows and any already-logged row they absorb) takes the combined committed total; on unmark the
  -- target entries drop their !L marker (build_intervals nils a non-logged interval's
  -- logged_minutes, so clearing `logged` alone suffices).
  local overrides = {}
  if target_logged then
    for row, minutes in pairs(frozen) do
      overrides[row] = { logged = true, logged_minutes = minutes }
    end
  else
    for row in pairs(target_rows) do
      overrides[row] = { logged = false }
    end
  end

  local edits = support.apply_entry_overrides(result.ctx.analysis, block, overrides)
  return edits
end

return M
