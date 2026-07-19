local analyze = require("daylog.analyze")
local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")
local syntax = require("daylog.syntax")

local M = {}

-- Log the summary row under the cursor, at the level it reports: a main row logs `!S`, a tag total
-- `!T`, a location total `!L`, the `--- totals ---` workday row `!W`. The row is only a selector: the
-- log is analyzed from source, contributing entries gain/lose the marker, and the summary is rebuilt.
-- One rule at every level.
--
-- Freezing is per-row WYSIWYG: the value written is the number the row currently displays, so logging
-- changes no displayed number. Marking a plain row that has a claim slice of the chosen names MERGES
-- the two -- the claim restates the sum, and one row results.
--
-- Names on a marker are managed independently. `run` ADDS the chosen names: a fresh mark when the row
-- is plain, else a union onto the existing marker, keeping its value. `run_unlog` REMOVES names --
-- the chosen ones, or all when none are given -- and clears the marker once its last name is gone;
-- when the names left behind match a sibling claim, the two merge and their values sum.

local NOT_LOGGABLE = "daylog: put the cursor on a summary, tag, location, or workday row to log it"
local NOTHING_TO_UNLOG = "daylog: this row is not logged; nothing to unlog"
local ALREADY_LOGGED =
  "daylog: this row is already logged to those names; unlog it first to re-freeze"

-- A written value is a fact about one day, so it can never exceed one.
local function too_large_error(minutes)
  return string.format(
    "daylog: that would log %d minutes; a logged value can't exceed %d",
    minutes,
    syntax.END_OF_DAY_MINUTES
  )
end

-- Each selectable layout kind's report level; run and peek share this dispatch.
local LEVEL_BY_KIND = {
  [render.LAYOUT_KIND.SUMMARY_ITEM] = "s",
  [render.LAYOUT_KIND.TAG_TOTAL] = "t",
  [render.LAYOUT_KIND.LOCATION_TOTAL] = "l",
  [render.LAYOUT_KIND.TOTAL] = "w",
}

-- The section each level's rows live in, and the fields identifying the cell a row belongs to.
local SECTION_BY_LEVEL = {
  s = "summary_items",
  t = "tag_totals",
  l = "location_totals",
  w = "total_rows",
}
local CELL_FIELDS = { s = { "text", "tag", "location" }, t = { "tag" }, l = { "location" }, w = {} }

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

-- The entry's logged table with `level` claiming `minutes` for `names`, or the marker removed when
-- `minutes` is nil, preserving every other level.
local function set_level(entry_item, level, minutes, names)
  local logged = analyze.copy_logged(entry_item and entry_item.logged) or {}
  logged[level] = minutes ~= nil and { minutes = minutes, names = names } or nil
  return logged
end

-- The rows of `item`'s cell at `level`, from a freshly computed summary: its plain slice and each of
-- its claim slices, so a mark can find the sibling it merges with.
local function cell_rows(block, item, level)
  local rows = summary.summarize_block(block)[SECTION_BY_LEVEL[level]] or {}
  local out = {}
  for _, row in ipairs(rows) do
    local same = true
    for _, field in ipairs(CELL_FIELDS[level]) do
      same = same and row[field] == item[field]
    end
    if same then
      out[#out + 1] = row
    end
  end
  return out
end

-- The cell's claim slice carrying exactly `names`, or nil.
local function slice_with_names(rows, names)
  local key = syntax.names_key({ names = names })
  for _, row in ipairs(rows) do
    if row.logged and syntax.names_key({ names = row.names }) == key then
      return row
    end
  end
  return nil
end

-- The entry items a set of summary rows was built from. The closing entry starts no interval, so it
-- belongs to no plain row and a fresh mark can never reach it; an already-marked closer does belong
-- to its claim and so restamps with it.
local function entries_of(block, rows)
  local wanted = {}
  for _, row in ipairs(rows) do
    for _, source_row in ipairs(row.source_entry_rows or {}) do
      wanted[source_row] = true
    end
  end

  local out = {}
  for _, entry_item in ipairs(block.entry_items) do
    if wanted[entry_item.start_row] then
      out[#out + 1] = entry_item
    end
  end
  return out
end

local function overrides_for(entries, level, minutes, names)
  local overrides = {}
  for _, entry_item in ipairs(entries) do
    local logged = set_level(entry_item, level, minutes, names)
    -- Freezing absorbs any `round±N` on the entry: the nudge is already part of the number being
    -- frozen, so dropping it changes no display -- and a nudge on a logged entry is refused outright.
    overrides[entry_item.start_row] = { logged = logged, nudge = next(logged) ~= nil and 0 or nil }
  end
  return overrides
end

-- Mark the cursor row's slice with `names`. A plain row freezes at the number it displays, merged
-- with the same-named claim slice of its cell when one exists; a claim row only gains names.
local function mark(analysis, block, item, level, names)
  local rows = cell_rows(block, item, level)

  if item.logged then
    local slice = slice_with_names(rows, item.names)
    if slice == nil then
      return nil, summary_cursor.STALE
    end
    if syntax.names_key({ names = names }) == syntax.names_key({ names = item.names }) then
      return nil, ALREADY_LOGGED
    end
    -- A name union keeps the claim's value: the same minutes, now recorded in one more ledger.
    return support.apply_entry_overrides(
      analysis,
      block,
      overrides_for(entries_of(block, { slice }), level, slice.duration, names)
    )
  end

  local sibling = slice_with_names(rows, names)
  local minutes = item.duration + (sibling and sibling.duration or 0)
  if minutes > syntax.END_OF_DAY_MINUTES then
    return nil, too_large_error(minutes)
  end

  local targets = entries_of(block, sibling and { item, sibling } or { item })
  if #targets == 0 then
    return nil, summary_cursor.STALE
  end
  return support.apply_entry_overrides(
    analysis,
    block,
    overrides_for(targets, level, minutes, names)
  )
end

-- Drop `names` from the cursor row's claim. Losing the last name clears the marker; when the names
-- left behind match a sibling claim of the same cell, the two merge and their values sum -- the
-- surviving ledgers received both amounts, so no logged total is lost.
local function unmark(analysis, block, item, level, names)
  local rows = cell_rows(block, item, level)
  local slice = slice_with_names(rows, item.names)
  if slice == nil then
    return nil, summary_cursor.STALE
  end

  if names == nil then
    return support.apply_entry_overrides(
      analysis,
      block,
      overrides_for(entries_of(block, { slice }), level, nil)
    )
  end

  local sibling = slice_with_names(rows, names)
  local minutes = slice.duration + (sibling and sibling.duration or 0)
  if minutes > syntax.END_OF_DAY_MINUTES then
    return nil, too_large_error(minutes)
  end

  local targets = entries_of(block, sibling and { slice, sibling } or { slice })
  return support.apply_entry_overrides(
    analysis,
    block,
    overrides_for(targets, level, minutes, names)
  )
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

-- Add `add_names` to the cursor row's slice (a fresh mark when the row is plain).
function M.run(lines, cursor_row, add_names)
  local resolved, err = resolve_level(lines, cursor_row)
  if not resolved then
    return nil, err
  end
  local item = resolved.item
  local names = union_names(item.logged and item.names or nil, canonical_names(add_names))
  return mark(resolved.ctx.analysis, resolved.ctx.block, item, resolved.level, names)
end

-- Remove `remove_names` from the cursor row's slice -- all of them when nil. Refuses a plain row.
function M.run_unlog(lines, cursor_row, remove_names)
  local resolved, err = resolve_level(lines, cursor_row)
  if not resolved then
    return nil, err
  end
  local item = resolved.item
  if not item.logged then
    return nil, NOTHING_TO_UNLOG
  end
  local names = remove_names ~= nil and difference_names(item.names, remove_names) or nil
  return unmark(resolved.ctx.analysis, resolved.ctx.block, item, resolved.level, names)
end

-- Read-only companion of run: the cursor's report level, its current display name-set (nil when
-- unnamed), and whether it is currently plain -- or nil + err (same errors as run). The shell opens
-- the frecency name picker at `level` to add names, and a picker over `names` to choose which to drop.
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

-- The summary item a by-value log target names in a freshly recomputed summary, matched by level +
-- value + the slice's names_key (a cell holds a plain row beside each of its claims). nil when the
-- value is absent (so a multi-day fan-out skips that day).
local function find_target_item(recomputed, target)
  local key = target.names_key or ""
  if target.level == "s" then
    for _, item in ipairs(recomputed.summary_items or {}) do
      if
        (item.text or "") == target.value
        and item.tag == target.tag
        and item.location == target.location
        and (item.s_names_key or "") == key
        and (item.logged == true) == (target.logged == true)
      then
        return item
      end
    end
  elseif target.level == "t" then
    for _, item in ipairs(recomputed.tag_totals or {}) do
      if
        item.tag == target.value
        and (item.t_names_key or "") == key
        and (item.logged == true) == (target.logged == true)
      then
        return item
      end
    end
  elseif target.level == "l" then
    for _, item in ipairs(recomputed.location_totals or {}) do
      if
        item.location == target.value
        and (item.l_names_key or "") == key
        and (item.logged == true) == (target.logged == true)
      then
        return item
      end
    end
  else
    for _, item in ipairs(recomputed.total_rows or {}) do
      if (item.w_names_key or "") == key and (item.logged == true) == (target.logged == true) then
        return item
      end
    end
  end
  return nil
end

-- Locate a by-value target in `lines`' active log: { ctx, item, level }; nil, nil when the log has no
-- summary yet or lacks the value (skip that day); nil + err on an invalid log.
local function resolve_by_value(lines, target)
  local resolved, err = support.resolve_active_summary_item(lines, function(recomputed)
    return find_target_item(recomputed, target)
  end)
  if not resolved then
    return nil, err
  end
  return { ctx = resolved.ctx, item = resolved.item, level = target.level }
end

-- Log by value rather than by cursor (the multi-day report fan-out): add `add_names` to the slice
-- named by `target` ({ level, value, tag?, logged, names_key, names }). Returns the edit script; nil,
-- nil when the value is absent (skip that day); nil + err on an invalid log.
function M.run_by_value(lines, target, add_names)
  local resolved, err = resolve_by_value(lines, target)
  if not resolved then
    return nil, err
  end
  local item = resolved.item
  local names = union_names(item.logged and item.names or nil, canonical_names(add_names))
  return mark(resolved.ctx.analysis, resolved.ctx.block, item, resolved.level, names)
end

-- Unlog by value (report fan-out): remove `remove_names` from the slice -- all when nil. A day whose
-- slice isn't logged is skipped (nil, nil), since a report unlog spans days that may differ.
function M.run_unlog_by_value(lines, target, remove_names)
  local resolved, err = resolve_by_value(lines, target)
  if not resolved then
    return nil, err
  end
  local item = resolved.item
  if not item.logged then
    return nil, nil
  end
  local names = remove_names ~= nil and difference_names(item.names, remove_names) or nil
  return unmark(resolved.ctx.analysis, resolved.ctx.block, item, resolved.level, names)
end

-- Classify a report layout row into a by-value log target, or nil + err for a non-loggable row. Unlike
-- rename, activity rows and the untagged / no-location groups ARE loggable, so log carries its own
-- classifier (passed to report_cursor.resolve).
function M.classify_report_row(layout_row)
  local level = LEVEL_BY_KIND[layout_row.kind]
  if not level then
    return nil, NOT_LOGGABLE
  end

  local item = layout_row.item
  local target = { level = level, logged = item.logged, names = item.logged and item.names or nil }
  if level == "s" then
    target.value = item.text or ""
    target.tag = item.tag
    -- Rows split per granule, so the location names WHICH row of an activity is meant.
    target.location = item.location
    target.names_key = item.s_names_key or ""
  elseif level == "t" then
    target.value = item.tag
    target.names_key = item.t_names_key or ""
  elseif level == "l" then
    target.value = item.location
    target.names_key = item.l_names_key or ""
  else
    target.names_key = item.w_names_key or ""
  end
  return target
end

return M
