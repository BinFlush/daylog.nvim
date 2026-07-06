local analyze = require("daylog.analyze")
local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")
local syntax = require("daylog.syntax")

local M = {}

-- Toggle the logged state of the summary row under the cursor, at the level it reports: a main row
-- logs `!S`, a tag total `!T`, a location total `!L`. The row is only a selector: the log is
-- analyzed from source, contributing entries gain/lose the marker, and the summary is rebuilt.
-- Levels are independent. The `--- totals ---` workday row logs `!W` on every non-blank entry.
-- Marking may attach a chosen name-set and merges with the same-name logged slice (recommitting at
-- the combined total); unmarking a named row clears exactly that slice.

local INCONSISTENT_SOURCE = "daylog: logged marking is inconsistent; regenerate the summary"
local NOT_LOGGABLE = "daylog: put the cursor on a summary, tag, location, or workday row to log it"
local REMAINDER_ROW =
  "daylog: this row is the drift beyond the cell's committed value; unlog the !S row to re-log it"

-- Each selectable layout kind's report level; run and peek share this dispatch.
local LEVEL_BY_KIND = {
  [render.LAYOUT_KIND.SUMMARY_ITEM] = "s",
  [render.LAYOUT_KIND.TAG_TOTAL] = "t",
  [render.LAYOUT_KIND.LOCATION_TOTAL] = "l",
  [render.LAYOUT_KIND.TOTAL] = "w",
}

-- Canonicalize the caller's name-set: nil when empty, else a deduped, sorted copy (never trust the
-- shell's ordering).
local function canonical_names(names)
  if names == nil or #names == 0 then
    return nil
  end
  local seen, out = {}, {}
  for _, name in ipairs(names) do
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

-- The entry's logged table with `level` frozen at `committed` minutes and `names` on a mark
-- (`{ minutes, names }`), or removed on an unmark, preserving other levels. Always a table (never nil,
-- which an override can't use to clear a field); an empty one reads as "logged at no level".
local function set_level(entry_item, level, committed, names)
  local logged = analyze.copy_logged(entry_item and entry_item.logged) or {}
  logged[level] = committed ~= nil and { minutes = committed, names = names } or nil
  return logged
end

-- The frozen committed value to stamp per source entry when marking `!S`. Marking merges the row
-- with any already-logged row of the same activity AND the same chosen name-set, so the commitment is
-- the SUM of both rows' displayed durations, written onto EVERY entry in the merged row. Keyed by
-- activity identity (includes location) plus name-set, so each slice freezes on its own.
local function frozen_values(block, target_rows, names)
  local rows = summary.fine_grained_quantized(block.entries, block.quantize_minutes)
  local chosen_key = syntax.names_key({ names = names })

  local logged_by_key = {}
  for _, row in ipairs(rows) do
    if row.logged then
      logged_by_key[summary.activity_identity_key(row) .. "\0" .. (row.s_names_key or "")] = row
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
        local existing = logged_by_key[summary.activity_identity_key(row) .. "\0" .. chosen_key]
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

-- Toggle `!S` on a main summary row. The summary level splits its base by (location, name-set), so the
-- freeze is per slice via frozen_values; every merged entry takes the combined value.
local function log_summary_row(analysis, block, item, names)
  local target_logged = not item.logged
  local row_key = item.s_names_key or ""

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
    -- An entry counts as logged like this row only when its own s name-set matches the row's slice.
    local entry_s = entry_item.logged and entry_item.logged.s
    local entry_logged = entry_s ~= nil and syntax.names_key(entry_s) == row_key
    if target_rows[entry_item.start_row] and (entry_logged or false) ~= (item.logged == true) then
      return nil, INCONSISTENT_SOURCE
    end
  end

  local frozen = target_logged and frozen_values(block, target_rows, names) or {}

  local overrides = {}
  if target_logged then
    for row, minutes in pairs(frozen) do
      overrides[row] = { logged = set_level(entry_by_row[row], "s", minutes, names) }
    end
  else
    for row in pairs(target_rows) do
      overrides[row] = { logged = set_level(entry_by_row[row], "s", nil) }
    end
  end

  return support.apply_entry_overrides(analysis, block, overrides)
end

-- Toggle `!T` / `!L` on a tag or location total row. Marking merges the chosen name-set's slice with
-- the cell's unlogged remainder and recommits every swept entry at their combined displayed total;
-- unmarking drops the marker from exactly the entries in the row's name-set slice.
local FIELD_BY_LEVEL = { t = "tag", l = "location" }

local function log_section_row(analysis, block, item, level, names)
  local field = FIELD_BY_LEVEL[level]
  local target_logged = not item.logged
  -- Marking matches on the CHOSEN name-set; unmarking on the row's own slice.
  local match_key = target_logged and syntax.names_key({ names = names })
    or (item[level .. "_names_key"] or "")

  -- A blank inherits the sticky tag/location, so it would otherwise match a tag/location cell;
  -- exclude it up front at every level. The `w` cell is the whole counted day; tag/location cells
  -- group by their own field value. Marking sweeps the unlogged entries plus the same-name logged
  -- slice (the merge/recommit); unmarking sweeps only the entries in the row's slice.
  local group = {}
  for _, entry_item in ipairs(block.entry_items) do
    local in_cell = not summary.is_blank_entry(entry_item)
      and (level == "w" or (field ~= nil and entry_item[field] == item[field]))
    if in_cell then
      local marker = entry_item.logged and entry_item.logged[level]
      local include
      if target_logged then
        include = marker == nil or syntax.names_key(marker) == match_key
      else
        include = marker ~= nil and syntax.names_key(marker) == match_key
      end
      if include then
        group[#group + 1] = entry_item
      end
    end
  end
  if #group == 0 then
    return nil, summary_cursor.STALE
  end

  local overrides = {}
  if target_logged then
    -- The commitment is the SUM of the cell's displayed unnamed and chosen-name rows -- the unlogged
    -- remainder plus the same-name slice, never a differently-named one.
    local totals = summary.summarize_block(block)
    local rows
    if level == "w" then
      rows = totals.total_rows or {}
    else
      rows = level == "l" and totals.location_totals or totals.tag_totals
    end
    local committed = 0
    for _, row in ipairs(rows) do
      local key = row[level .. "_names_key"] or ""
      local row_in_cell = level == "w" or row[field] == item[field]
      if row_in_cell and (key == "" or key == match_key) then
        committed = committed + row.duration
      end
    end

    for _, entry_item in ipairs(group) do
      overrides[entry_item.start_row] = { logged = set_level(entry_item, level, committed, names) }
    end
  else
    for _, entry_item in ipairs(group) do
      overrides[entry_item.start_row] = { logged = set_level(entry_item, level, nil) }
    end
  end

  return support.apply_entry_overrides(analysis, block, overrides)
end

-- Resolve the cursor to a selectable summary row and its report level, or nil + err. Shared prologue
-- of run and peek.
local function resolve_level(lines, cursor_row)
  local result, err = summary_cursor.resolve_or_entry(lines, cursor_row)
  if not result then
    return nil, err
  end

  local layout_row = result.layout_row
  if not layout_row then
    return nil, NOT_LOGGABLE
  end

  local level = LEVEL_BY_KIND[layout_row.kind]
  if not level then
    return nil, NOT_LOGGABLE
  end

  return { ctx = result.ctx, item = layout_row.item, level = level }
end

function M.run(lines, cursor_row, names)
  local resolved, err = resolve_level(lines, cursor_row)
  if not resolved then
    return nil, err
  end

  names = canonical_names(names)
  local analysis, block, item = resolved.ctx.analysis, resolved.ctx.block, resolved.item
  if resolved.level == "s" then
    return log_summary_row(analysis, block, item, names)
  end
  return log_section_row(analysis, block, item, resolved.level, names)
end

-- Read-only companion of run: what the toggle would do without editing anything. Returns
-- `{ level, marking, names }` -- `marking` true when the row is currently unlogged (the toggle marks),
-- `names` the row's display name-set (nil when unnamed) -- or nil + err (same errors as run).
function M.peek(lines, cursor_row)
  local resolved, err = resolve_level(lines, cursor_row)
  if not resolved then
    return nil, err
  end

  return {
    level = resolved.level,
    marking = not resolved.item.logged,
    names = resolved.item.names,
  }
end

return M
