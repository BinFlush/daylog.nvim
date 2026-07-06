local analyze = require("daylog.analyze")
local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")

local M = {}

-- Toggle the logged state of the summary row under the cursor, at the level it reports: a main row
-- logs `!S`, a tag total `!T`, a location total `!L`. The row is only a selector: the log is
-- analyzed from source, contributing entries gain/lose the marker, and the summary is rebuilt.
-- Levels are independent. The `--- totals ---` workday row logs `!W` on every non-blank entry.

local INCONSISTENT_SOURCE = "daylog: logged marking is inconsistent; regenerate the summary"
local NOT_LOGGABLE = "daylog: put the cursor on a summary, tag, location, or workday row to log it"
local REMAINDER_ROW =
  "daylog: this row is the drift beyond the cell's committed value; unlog the !S row to re-log it"

-- The entry's logged table with `level` set to `committed` (frozen minutes) on a mark, or removed
-- on an unmark, preserving other levels. Always a table (never nil, which an override can't use to
-- clear a field); an empty one reads as "logged at no level".
local function set_level(entry_item, level, committed)
  local logged = analyze.copy_logged(entry_item and entry_item.logged) or {}
  logged[level] = committed
  return logged
end

-- The frozen committed value to stamp per source entry when marking `!S`. Marking merges the row
-- with any already-logged row of the same activity, so the commitment is the SUM of both rows'
-- displayed durations, written onto EVERY entry in the merged row (newly and already logged). Keyed
-- by activity identity (includes location), so each location's slice freezes on its own.
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

  -- An empty provenance here is not staleness (the layout was freshly recomputed): it is the
  -- remainder slice of a fully-marked cell whose real time grew past its commitment.
  local source_rows = item.source_entry_rows or {}
  if #source_rows == 0 then
    return nil, REMAINDER_ROW
  end

  local target_rows = {}
  for _, source_row in ipairs(source_rows) do
    target_rows[source_row] = true
  end

  local entry_by_row = {}
  for _, entry_item in ipairs(block.entry_items) do
    entry_by_row[entry_item.start_row] = entry_item
    -- A blank is uncounted and never carries a marker; it shouldn't reach a summary row's source
    -- rows anyway -- defensive backstop.
    if target_rows[entry_item.start_row] and summary.is_blank_entry(entry_item) then
      target_rows[entry_item.start_row] = nil
    end
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

-- Toggle `!T` / `!L` on a tag or location total row. Groups by a single field (no sub-split), so
-- marking freezes the WHOLE group at its displayed section total on every entry; unmarking drops
-- the marker from the entries currently logged at the level.
local FIELD_BY_LEVEL = { t = "tag", l = "location" }

local function log_section_row(analysis, block, item, level)
  local field = FIELD_BY_LEVEL[level]
  local target_logged = not item.logged

  -- A blank inherits the sticky tag/location, so it would otherwise match a tag/location cell;
  -- exclude it up front at every level. The `w` cell is the whole counted day; tag/location cells
  -- group by their own field value.
  local group = {}
  for _, entry_item in ipairs(block.entry_items) do
    local in_cell = not summary.is_blank_entry(entry_item)
      and (level == "w" or (field ~= nil and entry_item[field] == item[field]))
    if in_cell then
      group[#group + 1] = entry_item
    end
  end
  if #group == 0 then
    return nil, summary_cursor.STALE
  end

  local overrides = {}
  if target_logged then
    local totals = summary.summarize_block(block)
    local committed
    if level == "w" then
      committed = totals.activity_total -- the workday is the whole counted day
    else
      local rows = level == "l" and totals.location_totals or totals.tag_totals
      committed = 0
      for _, row in ipairs(rows) do
        if row[field] == item[field] then
          committed = committed + row.duration
        end
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
    -- The totals row is the whole counted day: it logs `!W` on every non-blank entry.
    return log_section_row(result.ctx.analysis, result.ctx.block, layout_row.item, "w")
  end

  return nil, NOT_LOGGABLE
end

return M
