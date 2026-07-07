local analyze = require("daylog.analyze")
local quantize = require("daylog.quantize")
local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")
local syntax = require("daylog.syntax")

local M = {}

-- Log the summary row under the cursor, at the level it reports: a main row logs `!S`, a tag total
-- `!T`, a location total `!L`, the `--- totals ---` workday row `!W`. The row is only a selector: the
-- log is analyzed from source, contributing entries gain/lose the marker, and the summary is rebuilt.
-- Levels are independent.
--
-- Names on a marker are managed independently. `run` ADDS the chosen names to the row's slice: a fresh
-- mark when the row is unlogged (merging with any same-name slice at the combined total), else it
-- unions the names onto the existing marker, keeping its committed value. `run_unlog` REMOVES names --
-- the chosen ones, or all when none are given -- and clears the marker once its last name is gone. So
-- adding `boss` to a slice logged `!S[ado]` gives `!S[ado,boss]` (one slice reported to both); removing
-- `boss` returns it to `!S[ado]`.

local INCONSISTENT_SOURCE = "daylog: logged marking is inconsistent; regenerate the summary"
local NOT_LOGGABLE = "daylog: put the cursor on a summary, tag, location, or workday row to log it"
local NOTHING_TO_UNLOG = "daylog: this row is not logged; nothing to unlog"
local REMAINDER_ROW =
  "daylog: this row is the drift beyond the cell's committed value; unlog the !S row to re-log it"

-- Each selectable layout kind's report level; run and peek share this dispatch.
local LEVEL_BY_KIND = {
  [render.LAYOUT_KIND.SUMMARY_ITEM] = "s",
  [render.LAYOUT_KIND.TAG_TOTAL] = "t",
  [render.LAYOUT_KIND.LOCATION_TOTAL] = "l",
  [render.LAYOUT_KIND.TOTAL] = "w",
}

-- Canonicalize a name-set: nil when empty, else a deduped, sorted copy.
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

-- The canonical union / difference of two name lists (nil when the result is empty).
local function union_names(current, added)
  local out = {}
  for _, name in ipairs(current or {}) do
    out[#out + 1] = name
  end
  for _, name in ipairs(added or {}) do
    out[#out + 1] = name
  end
  return canonical_names(out)
end

local function difference_names(current, removed)
  local drop = {}
  for _, name in ipairs(removed or {}) do
    drop[name] = true
  end
  local out = {}
  for _, name in ipairs(current or {}) do
    if not drop[name] then
      out[#out + 1] = name
    end
  end
  return canonical_names(out)
end

-- The entry's logged table with `level` frozen at `committed` minutes and `names` on a mark, or removed
-- on a clear (`committed` nil), preserving other levels.
local function set_level(entry_item, level, committed, names)
  local logged = analyze.copy_logged(entry_item and entry_item.logged) or {}
  logged[level] = committed ~= nil and { minutes = committed, names = names } or nil
  return logged
end

-- Rewrite only `level`'s name-set on `entry_item`, keeping its current committed minutes -- extend or
-- reduce a logged slice's names without disturbing its value (or a bare marker's bareness).
local function rename_level(entry_item, level, names)
  local logged = analyze.copy_logged(entry_item and entry_item.logged) or {}
  local marker = logged[level] or {}
  logged[level] = { minutes = marker.minutes, names = names }
  return logged
end

-- The frozen committed value to stamp per source entry when freshly marking `!S`. Marking merges the
-- row with any already-logged row of the same activity AND the same chosen name-set, so the commitment
-- is the SUM of both rows' displayed durations, written onto EVERY entry in the merged row. Keyed by
-- activity identity (includes location) plus name-set, so each slice freezes on its own.
local function frozen_values(block, target_rows, names)
  local rows, bucket_minutes = summary.fine_grained_quantized(block.entries, block.quantize_minutes)
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
        -- The unlogged target's own duration already reflects any nudge; only the EXISTING frozen
        -- row needs its honest rounded duration in place of its committed value -- a commitment below
        -- the row's own rounded duration would otherwise drop that uncommitted remainder, under-
        -- committing the merge.
        local existing_honest = existing
          and quantize.round_to_nearest_bucket(
            existing.unrounded_duration or existing.duration,
            bucket_minutes
          )
        local combined = row.duration + (existing_honest or 0)
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

-- Add/reduce/clear `!S` on a main summary row. Adding to an unlogged row freshly marks (per-slice
-- frozen_values, merging with a same-name slice); adding to or reducing a logged row rewrites its
-- name-set at the preserved value; clearing removes the marker from the slice.
local function log_summary_row(analysis, block, item, names, clear)
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
    -- A blank is uncounted and never carries a marker; defensive backstop.
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

  local overrides = {}
  if clear then
    for row in pairs(target_rows) do
      overrides[row] = { logged = set_level(entry_by_row[row], "s", nil) }
    end
  elseif not item.logged then
    for row, minutes in pairs(frozen_values(block, target_rows, names)) do
      overrides[row] = { logged = set_level(entry_by_row[row], "s", minutes, names) }
    end
  else
    for row in pairs(target_rows) do
      overrides[row] = { logged = rename_level(entry_by_row[row], "s", names) }
    end
  end

  return support.apply_entry_overrides(analysis, block, overrides)
end

-- Add/reduce/clear `!T` / `!L` / `!W` on a tag, location, or workday total row. A fresh mark sweeps the
-- cell's unlogged remainder plus the chosen name-set's slice and commits their combined total; adding
-- to or reducing a logged slice rewrites its name-set at the preserved value; clearing drops the marker
-- from exactly that slice.
local FIELD_BY_LEVEL = { t = "tag", l = "location" }

local function log_section_row(analysis, block, item, level, names, clear)
  local field = FIELD_BY_LEVEL[level]
  local cursor_key = item[level .. "_names_key"] or ""

  local function in_cell(entry_item)
    return not summary.is_blank_entry(entry_item)
      and (level == "w" or (field ~= nil and entry_item[field] == item[field]))
  end

  if not clear and not item.logged then
    -- Fresh mark: sweep the cell's unlogged entries plus the chosen name-set's slice, committing at
    -- their combined displayed total. The block's last entry starts no interval (it only closes the
    -- prior one), so never mark it -- a marker there would silently under-log once a later entry is
    -- appended beneath it.
    local chosen_key = syntax.names_key({ names = names })
    local closer = block.entry_items[#block.entry_items]
    local group = {}
    for _, entry_item in ipairs(block.entry_items) do
      if in_cell(entry_item) and entry_item ~= closer then
        local marker = entry_item.logged and entry_item.logged[level]
        if marker == nil or syntax.names_key(marker) == chosen_key then
          group[#group + 1] = entry_item
        end
      end
    end
    if #group == 0 then
      return nil, summary_cursor.STALE
    end

    local totals = summary.summarize_block(block)
    local rows = level == "w" and (totals.total_rows or {})
      or (level == "l" and totals.location_totals or totals.tag_totals)
    local committed = 0
    for _, row in ipairs(rows) do
      local key = row[level .. "_names_key"] or ""
      local row_in_cell = level == "w" or row[field] == item[field]
      -- The commitment is the cell's UNLOGGED remainder (key "", not already committed) plus the
      -- chosen name-set's slice -- never another name-set's committed slice (that would over-commit).
      if row_in_cell and ((key == "" and not row.logged) or key == chosen_key) then
        committed = committed + row.duration
      end
    end

    local overrides = {}
    for _, entry_item in ipairs(group) do
      overrides[entry_item.start_row] = { logged = set_level(entry_item, level, committed, names) }
    end
    return support.apply_entry_overrides(analysis, block, overrides)
  end

  -- Clear or reduce/extend: act on exactly the cursor row's current name-set slice, preserving its
  -- committed value.
  local group = {}
  for _, entry_item in ipairs(block.entry_items) do
    if in_cell(entry_item) then
      local marker = entry_item.logged and entry_item.logged[level]
      if marker ~= nil and syntax.names_key(marker) == cursor_key then
        group[#group + 1] = entry_item
      end
    end
  end
  if #group == 0 then
    return nil, summary_cursor.STALE
  end

  local overrides = {}
  for _, entry_item in ipairs(group) do
    if clear then
      overrides[entry_item.start_row] = { logged = set_level(entry_item, level, nil) }
    else
      overrides[entry_item.start_row] = { logged = rename_level(entry_item, level, names) }
    end
  end
  return support.apply_entry_overrides(analysis, block, overrides)
end

-- Resolve the cursor to a selectable summary row and its report level, or nil + err. Shared prologue
-- of run, run_unlog, and peek.
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

local function dispatch(resolved, names, clear)
  local analysis, block, item = resolved.ctx.analysis, resolved.ctx.block, resolved.item
  if resolved.level == "s" then
    return log_summary_row(analysis, block, item, names, clear)
  end
  return log_section_row(analysis, block, item, resolved.level, names, clear)
end

-- Add `add_names` to the cursor row's slice (a fresh mark when the row is unlogged).
function M.run(lines, cursor_row, add_names)
  local resolved, err = resolve_level(lines, cursor_row)
  if not resolved then
    return nil, err
  end
  -- An unlogged remainder row carries its cell's name-set for display, but a fresh mark starts from
  -- nothing; only a currently-logged slice contributes existing names to the union.
  local current = resolved.item.logged and resolved.item.names or nil
  local names = union_names(current, canonical_names(add_names))
  return dispatch(resolved, names, false)
end

-- Remove `remove_names` from the cursor row's slice -- all of them when nil -- clearing the marker once
-- its last name is gone. Refuses an unlogged row.
function M.run_unlog(lines, cursor_row, remove_names)
  local resolved, err = resolve_level(lines, cursor_row)
  if not resolved then
    return nil, err
  end
  if not resolved.item.logged then
    return nil, NOTHING_TO_UNLOG
  end
  local names
  if remove_names ~= nil then
    names = difference_names(resolved.item.names, remove_names)
  end
  return dispatch(resolved, names, names == nil)
end

-- Read-only companion of run: the cursor's report level, its current display name-set (nil when
-- unnamed), and whether it is currently unlogged -- or nil + err (same errors as run). The shell opens
-- the frecency name picker at `level` to add names, and a picker over `names` to choose which to unlog.
function M.peek(lines, cursor_row)
  local resolved, err = resolve_level(lines, cursor_row)
  if not resolved then
    return nil, err
  end

  return {
    level = resolved.level,
    marking = not resolved.item.logged,
    names = resolved.item.logged and resolved.item.names or nil,
  }
end

return M
