local claims = require("daylog.claims")
local projection = require("daylog.projection")
local quantize = require("daylog.quantize")
local syntax = require("daylog.syntax")

local M = {}

-- Semantic reporting for log blocks: report sections, sorting, day merging. PURE.
-- (Shares and claims live in claims.lua, grouping in projection.lua, rounding in quantize.lua.)
--
-- Every section is the block's counted entries partitioned at its own level, and every row displays
-- the sum of its entries' shares against the clock they measured -- so all four sections foot
-- identically, in displayed time and in residuals alike.

-- The rounding bucket for a block, defaulting a nil OR non-positive quantize. Guarding <= 0 (not just
-- nil) keeps a direct call with q=0 from dividing by zero -- 0 is truthy in Lua, so `q or DEFAULT`
-- would pass it straight through into the quantizer.
local function bucket_of(quantize_minutes)
  return (quantize_minutes and quantize_minutes > 0) and quantize_minutes
    or syntax.DEFAULT_QUANTIZE_MINUTES
end

M.entry_summary_text = claims.label
M.is_blank_entry = claims.is_blank

-- The real intervals of a block, for the time bar and highlighter: every counted span that actually
-- runs, so a marked closing entry (which displays a row but occupies no clock) is left out.
function M.build_intervals(entries)
  local intervals = {}
  for _, span in ipairs(claims.spans(entries)) do
    if span.stop ~= nil then
      intervals[#intervals + 1] = span
    end
  end
  return intervals
end

-- The closing entry starts no interval, so its row is in no `source_entry_rows`; return it when it
-- WOULD group into `item` (same resolved text/tag/location/logged), so identity edits (:Daylog map /
-- rename) can reach a same-activity entry that currently closes the log. Returns nil when it does not.
function M.closing_entry_row_for(entries, item)
  local last = entries[#entries]
  if not last then
    return nil
  end

  if
    claims.label(last) == item.text
    and last.tag == item.tag
    and last.location == item.location
    and (last.logged and last.logged.s ~= nil and true or nil) == item.logged
  then
    return last.row
  end

  return nil
end

-- The descriptive fields each section's rows carry beyond their slice: level `s` names the granule,
-- `t`/`l` their own cell, `w` the whole block.
local CELL_FIELDS = {
  s = { "text", "tag", "location" },
  t = { "tag" },
  l = { "location" },
  w = {},
}

-- Build one report section: the spans partitioned at `level` into (cell, slice) rows, each displaying
-- the sum of its entries' shares. A claim's row carries the level's marker token and name-set; the
-- unmarked remainder of the cell is its plain row. The display row's `round±N` rides the section row
-- holding its first entry, so a manual adjustment stays visible without being counted twice.
local function build_section(state, level)
  local names_key_field = level .. "_names_key"
  local cell_of = claims.CELL[level]

  local section_of_span = {}
  local groups = claims.group(state.spans, function(span)
    local marker = span.logged_by_level and span.logged_by_level[level]
    return cell_of(span) .. "\1" .. (marker and "1" or "0") .. "\1" .. span[names_key_field]
  end)

  local rows = {}
  for _, found in ipairs(groups) do
    local first = found.first
    local marked = first.logged_by_level ~= nil and first.logged_by_level[level] ~= nil
    local row = {
      duration = 0,
      unrounded_duration = found.measured,
      logged = marked or nil,
      names = marked and first[level .. "_names"] or nil,
      [names_key_field] = marked and first[names_key_field] or nil,
      source_entry_rows = {},
    }

    for _, field in ipairs(CELL_FIELDS[level]) do
      row[field] = first[field]
    end

    for _, index in ipairs(found.members) do
      row.duration = row.duration + state.shares[index]
      row.source_entry_rows[#row.source_entry_rows + 1] = state.spans[index].source_entry_row
      row.marked = row.marked or state.spans[index].marked
      section_of_span[index] = row
    end

    rows[#rows + 1] = row
  end

  for _, display_row in ipairs(state.rows) do
    local anchor = section_of_span[display_row.members[1]]
    if display_row.nudge and display_row.nudge ~= 0 then
      anchor.nudge = (anchor.nudge or 0) + display_row.nudge
    end
    anchor.nudge_below_zero = anchor.nudge_below_zero or display_row.nudge_below_zero
  end

  return quantize.apply_error_minutes(rows)
end

local function sort_by_duration(items)
  local indexed = {}

  for i, item in ipairs(items) do
    table.insert(indexed, {
      index = i,
      item = item,
    })
  end

  table.sort(indexed, function(a, b)
    if a.item.duration == b.item.duration then
      local a_unrounded = a.item.unrounded_duration or a.item.duration
      local b_unrounded = b.item.unrounded_duration or b.item.duration

      if a_unrounded ~= b_unrounded then
        return a_unrounded > b_unrounded
      end

      return a.index < b.index
    end

    return a.item.duration > b.item.duration
  end)

  for i, indexed_item in ipairs(indexed) do
    items[i] = indexed_item.item
  end

  return items
end

-- Group `items` by `key_fn`, order each group's rows then the groups by displayed duration, and
-- flatten back in place -- so a cell's rows (its claim slices and their plain remainder) stay adjacent
-- instead of being split by an unrelated row of intermediate duration. nil keys share one group.
local function sort_grouped(items, key_fn)
  local groups_by_key = {}
  local groups = {}
  local ordered = {}

  for _, item in ipairs(items) do
    local key = key_fn(item)
    if key == nil then
      key = "\0"
    end

    local group = groups_by_key[key]
    if not group then
      group = { items = {}, duration = 0, unrounded_duration = 0 }
      groups_by_key[key] = group
      table.insert(groups, group)
    end

    table.insert(group.items, item)
    group.duration = group.duration + item.duration
    group.unrounded_duration = group.unrounded_duration + (item.unrounded_duration or item.duration)
  end

  for _, group in ipairs(groups) do
    sort_by_duration(group.items)
  end

  sort_by_duration(groups)

  for _, group in ipairs(groups) do
    for _, item in ipairs(group.items) do
      table.insert(ordered, item)
    end
  end

  for i, item in ipairs(ordered) do
    items[i] = item
  end

  return items
end

-- Main rows group by activity text (a granule's location-split rows stay adjacent); tag/location
-- totals group by their own cell so its slices render together. Grouping only reorders rows.
local function finalize_summary_order(summary)
  sort_grouped(summary.summary_items, function(item)
    return item.text
  end)
  sort_grouped(summary.tag_totals, function(item)
    return item.tag
  end)
  sort_grouped(summary.location_totals, function(item)
    return item.location
  end)
  return summary
end

-- Build the full summary from one share resolution: every section sums the same per-entry shares
-- under its own partition, so all four foot alike.
function M.summarize_entries(entries, quantize_minutes)
  local bucket_minutes = bucket_of(quantize_minutes)
  local state = claims.resolve(entries, bucket_minutes)

  local activity_total, activity_real = 0, 0
  for index, span in ipairs(state.spans) do
    activity_total = activity_total + state.shares[index]
    activity_real = activity_real + span.duration
  end

  return finalize_summary_order({
    summary_items = build_section(state, "s"),
    tag_totals = build_section(state, "t"),
    location_totals = build_section(state, "l"),
    -- Blank entries are counted nowhere, so the totals are the day's claims plus its plain remainder.
    total_rows = build_section(state, "w"),
    activity_total = activity_total,
    activity_error_minutes = activity_real - activity_total,
    bucket_minutes = bucket_minutes,
  })
end

function M.summarize_block(block)
  return M.summarize_entries(block.entries, block.quantize_minutes)
end

-- The activity-identity key (resolved text, tag, location) EXCLUDING logged state, so an
-- about-to-be-logged row finds the claim slice it merges with. PURE.
function M.activity_identity_key(row)
  return table.concat({
    row.text or "",
    row.tag or "",
    row.location or "",
  }, "\0")
end

function M.combine_summaries(summaries)
  local summary_items = {}
  local tag_totals = {}
  local location_totals = {}
  local total_rows = {}
  local activity_total = 0
  local activity_error_minutes = 0

  for _, item in ipairs(summaries or {}) do
    activity_total = activity_total + item.activity_total
    activity_error_minutes = activity_error_minutes + (item.activity_error_minutes or 0)

    for _, row in ipairs(item.summary_items or {}) do
      table.insert(summary_items, row)
    end

    for _, row in ipairs(item.tag_totals or {}) do
      table.insert(tag_totals, row)
    end

    for _, row in ipairs(item.location_totals or {}) do
      table.insert(location_totals, row)
    end

    for _, row in ipairs(item.total_rows or {}) do
      table.insert(total_rows, row)
    end
  end

  local summary = {
    -- `logged` and the level's name-set key are in every key so a section's claim and plain rows, and
    -- differently-named claims, stay separate across days (same-name rows merge).
    summary_items = quantize.apply_error_minutes(
      projection.project_rows(
        summary_items,
        { "text", "tag", "location", "logged", "s_names_key" },
        { "text", "tag", "location", "logged", "s_names_key", "names" }
      )
    ),
    tag_totals = quantize.apply_error_minutes(
      projection.project_rows(
        tag_totals,
        { "tag", "logged", "t_names_key" },
        { "tag", "logged", "t_names_key", "names" }
      )
    ),
    location_totals = quantize.apply_error_minutes(
      projection.project_rows(
        location_totals,
        { "location", "logged", "l_names_key" },
        { "location", "logged", "l_names_key", "names" }
      )
    ),
    total_rows = quantize.apply_error_minutes(
      projection.project_rows(
        total_rows,
        { "logged", "w_names_key" },
        { "logged", "w_names_key", "names" }
      )
    ),
    activity_total = activity_total,
    activity_error_minutes = activity_error_minutes,
  }

  return finalize_summary_order(summary)
end

return M
