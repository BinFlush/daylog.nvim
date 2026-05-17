local M = {}

-- Semantic reporting for worklog blocks.
--
-- Summaries are built directly from semantic entries or worklog blocks. The
-- module owns interval derivation, grouping, tag/location totals, sorting, and
-- quantization so reporting stays a first-class semantic concern.

local NIL = {}

local function normalize_key_part(value)
  if value == nil then
    return NIL
  end

  return value
end

local function get_nested(root, item, key_fields)
  local node = root

  assert(#key_fields > 0, "get_nested requires at least one key field")

  for i = 1, #key_fields do
    node = node[normalize_key_part(item[key_fields[i]])]

    if not node then
      return nil
    end
  end

  return node
end

local function put_nested(root, item, key_fields, value)
  local node = root

  assert(#key_fields > 0, "put_nested requires at least one key field")

  for i = 1, #key_fields - 1 do
    local key = normalize_key_part(item[key_fields[i]])

    if not node[key] then
      node[key] = {}
    end

    node = node[key]
  end

  node[normalize_key_part(item[key_fields[#key_fields]])] = value
end

-- Project rows into coarser reporting buckets.
-- `key_fields` decides which row fields define identity, while `fields` decides
-- which descriptive labels survive into the projected row.
-- Durations are always accumulated, and first-seen group order is preserved.
local function project_rows(rows, key_fields, fields)
  local buckets = {}
  local order = {}

  for _, row in ipairs(rows) do
    local bucket = get_nested(buckets, row, key_fields)

    if not bucket then
      bucket = {
        duration = 0,
        exact_duration = 0,
      }

      for _, field in ipairs(fields) do
        bucket[field] = row[field]
      end

      put_nested(buckets, row, key_fields, bucket)
      table.insert(order, bucket)
    end

    bucket.duration = bucket.duration + row.duration
    bucket.exact_duration = bucket.exact_duration + (row.exact_duration or row.duration)
  end

  return order
end

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
    })
  end

  return intervals
end

-- Fine-grained rows are the quantization base.
-- They preserve location so tag/location totals can be projected from the
-- same quantized rows, even though main summary rows do not render location.
local function build_fine_grained_rows(intervals)
  return project_rows(
    intervals,
    { "text", "tag", "location", "workday_excluded" },
    { "text", "tag", "location", "workday_excluded" }
  )
end

local function summarize_items(rows)
  return project_rows(
    rows,
    { "text", "tag", "workday_excluded" },
    { "text", "tag", "workday_excluded" }
  )
end

local function summarize_metadata(rows, field)
  return project_rows(rows, { field }, { field })
end

-- Project one row set into every exact reporting section.
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
      local a_exact = a.item.exact_duration or a.item.duration
      local b_exact = b.item.exact_duration or b.item.duration

      if a_exact ~= b_exact then
        return a_exact > b_exact
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

local function sort_text_groups_by_duration(groups)
  local indexed = {}

  for i, group in ipairs(groups) do
    table.insert(indexed, {
      index = i,
      group = group,
    })
  end

  table.sort(indexed, function(a, b)
    if a.group.duration == b.group.duration then
      local a_exact = a.group.exact_duration or a.group.duration
      local b_exact = b.group.exact_duration or b.group.duration

      if a_exact ~= b_exact then
        return a_exact > b_exact
      end

      return a.index < b.index
    end

    return a.group.duration > b.group.duration
  end)

  for i, indexed_group in ipairs(indexed) do
    groups[i] = indexed_group.group
  end

  return groups
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
        exact_duration = 0,
      }
      groups_by_text[item.text] = group
      table.insert(groups, group)
    end

    table.insert(group.items, item)
    group.duration = group.duration + item.duration
    group.exact_duration = group.exact_duration + (item.exact_duration or item.duration)
  end

  for _, group in ipairs(groups) do
    sort_by_duration(group.items)
  end

  sort_text_groups_by_duration(groups)

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

local function round_to_nearest_bucket(minutes, bucket_minutes)
  return math.floor((minutes + (bucket_minutes / 2)) / bucket_minutes) * bucket_minutes
end

local function copy_rows(rows)
  local result = {}

  for _, row in ipairs(rows) do
    local copy = {}

    for key, value in pairs(row) do
      copy[key] = value
    end

    table.insert(result, copy)
  end

  return result
end

local function quantize_rows(rows, bucket_minutes, target_total)
  local result = copy_rows(rows)
  local quantized_total = 0
  local ranked = {}

  for i, row in ipairs(result) do
    local exact_duration = row.exact_duration or row.duration
    local base = math.floor(exact_duration / bucket_minutes) * bucket_minutes
    local remainder = exact_duration - base

    row.exact_duration = exact_duration
    row.error_minutes = remainder
    row.duration = base
    quantized_total = quantized_total + base

    table.insert(ranked, {
      index = i,
      remainder = remainder,
    })
  end

  table.sort(ranked, function(a, b)
    if a.remainder == b.remainder then
      return a.index < b.index
    end

    return a.remainder > b.remainder
  end)

  local blocks = math.floor((target_total - quantized_total) / bucket_minutes)

  for i = 1, blocks do
    local ranked_row = ranked[i]
    if ranked_row then
      result[ranked_row.index].duration = result[ranked_row.index].duration + bucket_minutes
      result[ranked_row.index].error_minutes = result[ranked_row.index].error_minutes
        - bucket_minutes
    end
  end

  return result
end

local function items_by_fields(items, key_fields)
  local result = {}

  for _, item in ipairs(items) do
    put_nested(result, item, key_fields, item)
  end

  return result
end

-- Reapply quantized durations onto exact ordered sections.
-- Exact rows define the visible labels and exact totals, while the quantized
-- rows provide the displayed duration after one shared quantization pass.
local function project_quantized_items(exact_items, quantized_items, key_fields, fields)
  local result = {}
  local quantized_index = items_by_fields(quantized_items, key_fields)

  for _, item in ipairs(exact_items) do
    local projected = {}
    local quantized_item = get_nested(quantized_index, item, key_fields)

    for _, field in ipairs(fields) do
      projected[field] = item[field]
    end

    -- Exact and quantized projections should stay aligned. Falling back to zero
    -- keeps this helper defensive if an internal mismatch ever slips through.
    projected.duration = quantized_item and quantized_item.duration or 0
    projected.exact_duration = item.exact_duration
    projected.error_minutes = item.duration - (quantized_item and quantized_item.duration or 0)
    table.insert(result, projected)
  end

  return result
end

function M.summarize_entries(entries)
  local summary = build_summary_from_rows(build_fine_grained_rows(build_intervals(entries)))
  return finalize_summary_order(summary)
end

function M.summarize_block(block)
  return M.summarize_entries(block.entries)
end

-- Quantize grouped summary rows together.
-- The overall activity total is rounded to the nearest configured bucket, each
-- fine-grained row is rounded down to that bucket, and the remaining
-- bucket-sized blocks are assigned to the largest remainders. Every displayed
-- quantized section is then projected from that one quantized fine-grained
-- base. `#ooo` rows participate in the same pass, but are excluded from the
-- final workday total.
function M.quantized_summarize_entries(entries, quantize_minutes)
  local bucket_minutes = quantize_minutes or 15
  local exact_rows = build_fine_grained_rows(build_intervals(entries))
  local exact_summary = build_summary_from_rows(exact_rows)
  local target_total = round_to_nearest_bucket(exact_summary.activity_total, bucket_minutes)
  local quantized_rows = quantize_rows(exact_rows, bucket_minutes, target_total)
  local quantized_summary = build_summary_from_rows(quantized_rows)

  local summary = {
    summary_items = project_quantized_items(
      exact_summary.summary_items,
      quantized_summary.summary_items,
      { "text", "tag", "workday_excluded" },
      { "text", "tag", "workday_excluded" }
    ),
    tag_totals = project_quantized_items(
      exact_summary.tag_totals,
      quantized_summary.tag_totals,
      { "tag" },
      { "tag" }
    ),
    location_totals = project_quantized_items(
      exact_summary.location_totals,
      quantized_summary.location_totals,
      { "location" },
      { "location" }
    ),
    activity_total = quantized_summary.activity_total,
    workday_total = quantized_summary.workday_total,
    activity_error_minutes = exact_summary.activity_total - quantized_summary.activity_total,
    workday_error_minutes = exact_summary.workday_total - quantized_summary.workday_total,
  }

  return finalize_summary_order(summary)
end

function M.quantized_summarize_block(block)
  return M.quantized_summarize_entries(block.entries, block.quantize_minutes)
end

return M
