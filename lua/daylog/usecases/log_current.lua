local analyze = require("daylog.analyze")
local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")

local M = {}

-- Toggle the logged state of the summary row under the cursor, at the level that row reports:
-- a main (activity) row logs at the summary level (`!S`), a tag total at the tag level (`!T`), a
-- location total at the location level (`!L`). The rendered row is only a selector: the active log is
-- analyzed from source, the contributing entries gain or lose that level's marker, and the one summary
-- is rebuilt from the updated source (a pure projection, so no note preservation is needed).
--
-- The levels are independent, so marking a tag does not touch the summary or location markers on the
-- same entries. Out-of-office (`#ooo`) time can never be logged, at any level -- so the totals' non-work
-- row is refused, and only its workday row logs (`!W`, stamped on every non-#ooo entry).

local REFUSE_OOO = "daylog: refusing to mark out-of-office time as logged"
local INCONSISTENT_SOURCE = "daylog: logged marking is inconsistent; regenerate the summary"
local NOT_LOGGABLE = "daylog: put the cursor on a summary, tag, location, or workday row to log it"

-- The entry's logged table with `level` set to `committed` (the frozen minutes) on a mark, or removed
-- (`committed == nil`) on an unmark -- preserving the entry's other levels. Always a table (never nil,
-- which an override cannot use to clear a field); an empty one reads as "logged at no level"
-- everywhere (every reader keys on `[level]`).
local function set_level(entry_item, level, committed)
  local logged = analyze.copy_logged(entry_item and entry_item.logged) or {}
  logged[level] = committed
  return logged
end

-- The frozen committed value to stamp on each source entry when marking `!S`. Marking a row logged
-- merges it with any already-logged row of the same activity, so the new commitment is the SUM of the
-- two rows' currently displayed durations -- and, because the value is replicated per row, it must be
-- written onto EVERY entry in the merged row: the ones logged now AND the ones already logged (whose
-- value grows to the new total). Keyed by activity identity (which includes location), so an activity
-- spanning locations freezes each location's slice at its own committed value, matching the main base.
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

-- Toggle `!S` on a main summary row. The summary level splits its base by location, so the freeze is
-- per (activity, location) slice via frozen_values; every merged entry takes the combined value.
local function log_summary_row(analysis, block, item)
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

  local entry_by_row = {}
  for _, entry_item in ipairs(block.entry_items) do
    entry_by_row[entry_item.start_row] = entry_item
    local entry_logged = entry_item.logged and entry_item.logged.s ~= nil
    if target_rows[entry_item.start_row] and (entry_logged or false) ~= (item.logged == true) then
      return nil, INCONSISTENT_SOURCE
    end
  end

  local frozen = target_logged and frozen_values(block, target_rows) or {}

  local overrides = {}
  if target_logged then
    for row, minutes in pairs(frozen) do
      overrides[row] = { logged = set_level(entry_by_row[row], "s", minutes) }
    end
  else
    for row in pairs(target_rows) do
      overrides[row] = { logged = set_level(entry_by_row[row], "s", nil) }
    end
  end

  return support.apply_entry_overrides(analysis, block, overrides)
end

-- Toggle `!T` / `!L` on a tag or location total row. A tag/location groups by a single field with no
-- sub-split (unlike the summary level's location axis), so marking freezes the WHOLE group at its
-- current displayed section total and stamps that one value on every one of its entries; unmarking
-- drops the marker from the entries currently logged at the level.
local FIELD_BY_LEVEL = { t = "tag", l = "location", w = "workday_excluded" }

local function log_section_row(analysis, block, item, level)
  local field = FIELD_BY_LEVEL[level]
  local target_logged = not item.logged

  local group = {}
  for _, entry_item in ipairs(block.entry_items) do
    if entry_item[field] == item[field] then
      if target_logged and entry_item.workday_excluded then
        return nil, REFUSE_OOO
      end
      group[#group + 1] = entry_item
    end
  end
  if #group == 0 then
    return nil, summary_cursor.STALE
  end

  local overrides = {}
  if target_logged then
    local totals = summary.summarize_block(block)
    local rows = totals.tag_totals
    if level == "l" then
      rows = totals.location_totals
    elseif level == "w" then
      rows = totals.total_rows
    end
    local committed = 0
    for _, row in ipairs(rows) do
      if row[field] == item[field] then
        committed = committed + row.duration
      end
    end

    for _, entry_item in ipairs(group) do
      overrides[entry_item.start_row] = { logged = set_level(entry_item, level, committed) }
    end
  else
    for _, entry_item in ipairs(group) do
      if entry_item.logged and entry_item.logged[level] ~= nil then
        overrides[entry_item.start_row] = { logged = set_level(entry_item, level, nil) }
      end
    end
  end

  return support.apply_entry_overrides(analysis, block, overrides)
end

function M.run(lines, cursor_row)
  local result, err = summary_cursor.resolve_or_entry(lines, cursor_row)
  if not result then
    return nil, err
  end

  local layout_row = result.layout_row
  if not layout_row then
    return nil, NOT_LOGGABLE
  end

  local K = render.LAYOUT_KIND
  if layout_row.kind == K.SUMMARY_ITEM then
    return log_summary_row(result.ctx.analysis, result.ctx.block, layout_row.item)
  elseif layout_row.kind == K.TAG_TOTAL then
    return log_section_row(result.ctx.analysis, result.ctx.block, layout_row.item, "t")
  elseif layout_row.kind == K.LOCATION_TOTAL then
    return log_section_row(result.ctx.analysis, result.ctx.block, layout_row.item, "l")
  elseif layout_row.kind == K.TOTAL then
    -- The totals partition: the workday row logs `!W`; the non-work (#ooo) row is refused inside
    -- log_section_row, since #ooo time can never be logged.
    return log_section_row(result.ctx.analysis, result.ctx.block, layout_row.item, "w")
  end

  return nil, NOT_LOGGABLE
end

return M
