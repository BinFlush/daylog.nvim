local projection = require("worklog.projection")
local quantize = require("worklog.quantize")
local syntax = require("worklog.syntax")

local M = {}

-- Semantic reporting for worklog blocks.
--
-- Summaries are built directly from semantic entries or worklog blocks. This
-- module owns the worklog domain of reporting: interval derivation, the report
-- sections, sorting, and logged totals. The generic grouping engine lives in
-- projection.lua and the rounding arithmetic in quantize.lua.

local function build_intervals(entries)
  local intervals = {}

  for i = 1, #entries - 1 do
    local current = entries[i]
    local next = entries[i + 1]

    table.insert(intervals, {
      start = current.minutes,
      stop = next.minutes,
      duration = next.minutes - current.minutes,
      text = current.text,
      tag = current.tag,
      location = current.location,
      workday_excluded = current.workday_excluded,
      logged = current.logged and true or nil,
      source_entry_row = current.row,
    })
  end

  return intervals
end

-- Fine-grained rows are the quantization base.
-- They preserve location so tag/location totals can be projected from the
-- same quantized rows, even though main summary rows do not render location.
-- Provenance accumulates here so each fine-grained row carries the source
-- entry rows of every interval that fed into it.
local function build_fine_grained_rows(intervals)
  return projection.project_rows(
    intervals,
    { "text", "tag", "location", "workday_excluded", "logged" },
    { "text", "tag", "location", "workday_excluded", "logged" },
    true
  )
end

-- Main summary items fold across locations, concatenating provenance from
-- every fine-grained row that shares the same (text, tag, workday_excluded,
-- logged) identity.
local function summarize_items(rows)
  return projection.project_rows(
    rows,
    { "text", "tag", "workday_excluded", "logged" },
    { "text", "tag", "workday_excluded", "logged" },
    true
  )
end

local function summarize_metadata(rows, field)
  return projection.project_rows(rows, { field }, { field })
end

-- Project one row set into every reporting section.
-- Main summary items fold location away, while tag and location totals keep
-- their own label fields and all totals are derived from the same source rows.
local function build_summary_from_rows(rows)
  local activity_total = 0
  local workday_total = 0

  for _, row in ipairs(rows) do
    activity_total = activity_total + row.duration

    if not row.workday_excluded then
      workday_total = workday_total + row.duration
    end
  end

  return {
    summary_items = summarize_items(rows),
    tag_totals = summarize_metadata(rows, "tag"),
    location_totals = summarize_metadata(rows, "location"),
    activity_total = activity_total,
    workday_total = workday_total,
  }
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

local function sort_summary_items(items)
  local groups_by_text = {}
  local groups = {}
  local ordered = {}

  for _, item in ipairs(items) do
    local group = groups_by_text[item.text]

    if not group then
      group = {
        text = item.text,
        items = {},
        duration = 0,
        unrounded_duration = 0,
      }
      groups_by_text[item.text] = group
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

local function finalize_summary_order(summary)
  sort_summary_items(summary.summary_items)
  sort_by_duration(summary.tag_totals)
  sort_by_duration(summary.location_totals)
  return summary
end

-- Emit logged totals in fixed semantic order: logged always before unlogged.
-- `by_logged` is keyed by the boolean logged state.
local function ordered_logged_totals(by_logged)
  local totals = {}

  if by_logged[true] then
    table.insert(totals, by_logged[true])
  end
  if by_logged[false] then
    table.insert(totals, by_logged[false])
  end

  return totals
end

-- Derive logged totals by projecting workday-eligible summary items by logged state.
-- Items must already carry quantized durations and error_minutes (i.e. they come from
-- quantize.project_quantized_items or an apply_error_minutes pass).  Duration,
-- unrounded_duration, and error_minutes are summed directly so the result equals the sum of
-- the visible quantized main summary rows by logged state, preserving the remainder
-- distribution from the shared quantization pass.
local function logged_totals_from_quantized_items(items)
  local buckets = {}
  local has_logged = false

  for _, item in ipairs(items or {}) do
    if not item.workday_excluded then
      local logged = item.logged == true
      has_logged = has_logged or logged

      local bucket = buckets[logged]
      if not bucket then
        bucket = {
          logged = logged,
          duration = 0,
          unrounded_duration = 0,
          error_minutes = 0,
        }
        buckets[logged] = bucket
      end

      bucket.duration = bucket.duration + item.duration
      bucket.unrounded_duration = bucket.unrounded_duration + (item.unrounded_duration or 0)
      bucket.error_minutes = bucket.error_minutes + (item.error_minutes or 0)
    end
  end

  if not has_logged then
    return nil
  end

  return ordered_logged_totals(buckets)
end

-- Quantize grouped summary rows together.
-- The overall activity total is rounded to the nearest configured bucket, each
-- fine-grained row is rounded down to that bucket, and the remaining
-- bucket-sized blocks are assigned to the largest remainders. Every displayed
-- quantized section is then projected from that one quantized fine-grained
-- base. `#ooo` rows participate in the same pass, but are excluded from the
-- final workday total.
function M.summarize_entries(entries, quantize_minutes)
  local bucket_minutes = quantize_minutes or syntax.DEFAULT_QUANTIZE_MINUTES
  local unrounded_rows = build_fine_grained_rows(build_intervals(entries))
  local unrounded_summary = build_summary_from_rows(unrounded_rows)
  local target_total =
    quantize.round_to_nearest_bucket(unrounded_summary.activity_total, bucket_minutes)
  local quantized_rows = quantize.quantize_rows(unrounded_rows, bucket_minutes, target_total)
  local quantized_summary = build_summary_from_rows(quantized_rows)

  local summary = {
    summary_items = quantize.project_quantized_items(
      unrounded_summary.summary_items,
      quantized_summary.summary_items,
      { "text", "tag", "workday_excluded", "logged" },
      { "text", "tag", "workday_excluded", "logged" }
    ),
    tag_totals = quantize.project_quantized_items(
      unrounded_summary.tag_totals,
      quantized_summary.tag_totals,
      { "tag" },
      { "tag" }
    ),
    location_totals = quantize.project_quantized_items(
      unrounded_summary.location_totals,
      quantized_summary.location_totals,
      { "location" },
      { "location" }
    ),
    activity_total = quantized_summary.activity_total,
    workday_total = quantized_summary.workday_total,
    activity_error_minutes = unrounded_summary.activity_total - quantized_summary.activity_total,
    workday_error_minutes = unrounded_summary.workday_total - quantized_summary.workday_total,
  }

  local logged_totals = logged_totals_from_quantized_items(summary.summary_items)
  if logged_totals then
    summary.logged_totals = logged_totals
  end

  return finalize_summary_order(summary)
end

function M.summarize_block(block)
  return M.summarize_entries(block.entries, block.quantize_minutes)
end

function M.combine_summaries(summaries)
  local summary_items = {}
  local tag_totals = {}
  local location_totals = {}
  local activity_total = 0
  local workday_total = 0
  local activity_error_minutes = 0
  local workday_error_minutes = 0

  for _, item in ipairs(summaries or {}) do
    activity_total = activity_total + item.activity_total
    workday_total = workday_total + item.workday_total
    activity_error_minutes = activity_error_minutes + (item.activity_error_minutes or 0)
    workday_error_minutes = workday_error_minutes + (item.workday_error_minutes or 0)

    for _, row in ipairs(item.summary_items or {}) do
      table.insert(summary_items, row)
    end

    for _, row in ipairs(item.tag_totals or {}) do
      table.insert(tag_totals, row)
    end

    for _, row in ipairs(item.location_totals or {}) do
      table.insert(location_totals, row)
    end
  end

  local summary = {
    summary_items = quantize.apply_error_minutes(
      projection.project_rows(
        summary_items,
        { "text", "tag", "workday_excluded", "logged" },
        { "text", "tag", "workday_excluded", "logged" }
      )
    ),
    tag_totals = quantize.apply_error_minutes(
      projection.project_rows(tag_totals, { "tag" }, { "tag" })
    ),
    location_totals = quantize.apply_error_minutes(
      projection.project_rows(location_totals, { "location" }, { "location" })
    ),
    activity_total = activity_total,
    workday_total = workday_total,
    activity_error_minutes = activity_error_minutes,
    workday_error_minutes = workday_error_minutes,
  }

  local logged_totals = logged_totals_from_quantized_items(summary.summary_items)
  if logged_totals then
    summary.logged_totals = logged_totals
  end

  return finalize_summary_order(summary)
end

return M
