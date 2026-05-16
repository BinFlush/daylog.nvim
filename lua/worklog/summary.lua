local M = {}

-- Semantic reporting for worklog blocks.
--
-- Summaries are built directly from semantic entries or worklog blocks. The
-- module owns interval derivation, grouping, tag/location totals, sorting, and
-- quantization so reporting stays a first-class semantic concern.

local NIL_TAG_KEY = "\31"
local NIL_LOCATION_KEY = "\30"

local function round_to_nearest_bucket(minutes, bucket_minutes)
  return math.floor((minutes + (bucket_minutes / 2)) / bucket_minutes) * bucket_minutes
end

local function metadata_key(value, nil_key)
  if value == nil then
    return nil_key
  end

  return value
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

-- Project rows into coarser reporting buckets.
-- `key_fn` decides which rows belong to the same bucket, while `fields`
-- decides which descriptive labels survive into the projected row.
-- Durations are always accumulated, and first-seen group order is preserved.
local function project_rows(rows, key_fn, fields)
  local buckets = {}
  local order = {}

  for _, row in ipairs(rows) do
    local key = key_fn(row)

    if not buckets[key] then
      local bucket = {
        duration = 0,
        exact_duration = 0,
      }

      for _, field in ipairs(fields) do
        bucket[field] = row[field]
      end

      buckets[key] = bucket
      table.insert(order, key)
    end

    buckets[key].duration = buckets[key].duration + row.duration
    buckets[key].exact_duration = buckets[key].exact_duration + (row.exact_duration or row.duration)
  end

  local result = {}

  for _, key in ipairs(order) do
    table.insert(result, buckets[key])
  end

  return result
end

local function summary_item_key(row)
  return table.concat({
    row.text,
    metadata_key(row.tag, NIL_TAG_KEY),
    tostring(row.excluded),
  }, "|")
end

local function metadata_bucket_key(row, field, nil_key)
  return metadata_key(row[field], nil_key)
end

local function summarize_items(rows)
  return project_rows(rows, summary_item_key, { "text", "tag", "excluded" })
end

local function summarize_metadata(rows, field, nil_key)
  return project_rows(
    rows,
    function(row)
      return metadata_bucket_key(row, field, nil_key)
    end,
    { field }
  )
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
      excluded = current.excluded,
    })
  end

  return intervals
end

local function fine_grained_row_key(row)
  return table.concat({
    row.text,
    metadata_key(row.tag, NIL_TAG_KEY),
    metadata_key(row.location, NIL_LOCATION_KEY),
    tostring(row.excluded),
  }, "|")
end

-- Fine-grained rows are the quantization base.
-- They preserve location so tag/location totals can be projected from the
-- same quantized rows, even though main summary rows do not render location.
local function build_fine_grained_rows(intervals)
  return project_rows(intervals, fine_grained_row_key, { "text", "tag", "location", "excluded" })
end

-- Project one row set into every exact reporting section.
-- Main summary items fold location away, while tag and location totals keep
-- their own label fields and all totals are derived from the same source rows.
local function build_summary_from_rows(rows)
  local activity_total = 0
  local workday_total = 0

  for _, row in ipairs(rows) do
    activity_total = activity_total + row.duration

    if not row.excluded then
      workday_total = workday_total + row.duration
    end
  end

  return {
    items = summarize_items(rows),
    tag_items = summarize_metadata(rows, "tag", NIL_TAG_KEY),
    location_items = summarize_metadata(rows, "location", NIL_LOCATION_KEY),
    activity_total = activity_total,
    workday_total = workday_total,
  }
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

  for i, item in ipairs(result) do
    local exact_duration = item.exact_duration or item.duration
    local base = math.floor(exact_duration / bucket_minutes) * bucket_minutes
    local remainder = exact_duration - base

    item.exact_duration = exact_duration
    item.error_minutes = remainder
    item.duration = base
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
    local ranked_item = ranked[i]
    if ranked_item then
      result[ranked_item.index].duration = result[ranked_item.index].duration + bucket_minutes
      result[ranked_item.index].error_minutes = result[ranked_item.index].error_minutes - bucket_minutes
    end
  end

  return result
end

local function items_by_custom_key(items, key_fn)
  local result = {}

  for _, item in ipairs(items) do
    result[key_fn(item)] = item
  end

  return result
end

-- Reapply quantized durations onto exact ordered sections.
-- Exact rows define the visible labels and exact totals, while the quantized
-- rows provide the displayed duration after one shared quantization pass.
local function project_quantized_items(exact_items, quantized_items, key_fn, fields)
  local result = {}
  local quantized_by_key = items_by_custom_key(quantized_items, key_fn)

  for _, item in ipairs(exact_items) do
    local projected = {}
    local quantized_item = quantized_by_key[key_fn(item)]

    for _, field in ipairs(fields) do
      projected[field] = item[field]
    end

    projected.duration = quantized_item and quantized_item.duration or 0
    projected.exact_duration = item.exact_duration
    projected.error_minutes = item.duration - (quantized_item and quantized_item.duration or 0)
    table.insert(result, projected)
  end

  return result
end

function M.summarize_entries(entries)
  local summary = build_summary_from_rows(build_fine_grained_rows(build_intervals(entries)))

  sort_summary_items(summary.items)
  sort_by_duration(summary.tag_items)
  sort_by_duration(summary.location_items)

  return summary
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
    items = project_quantized_items(exact_summary.items, quantized_summary.items, summary_item_key, { "text", "tag", "excluded" }),
    tag_items = project_quantized_items(
      exact_summary.tag_items,
      quantized_summary.tag_items,
      function(row)
        return metadata_bucket_key(row, "tag", NIL_TAG_KEY)
      end,
      { "tag" }
    ),
    location_items = project_quantized_items(
      exact_summary.location_items,
      quantized_summary.location_items,
      function(row)
        return metadata_bucket_key(row, "location", NIL_LOCATION_KEY)
      end,
      { "location" }
    ),
    activity_total = quantized_summary.activity_total,
    workday_total = quantized_summary.workday_total,
    activity_error_minutes = exact_summary.activity_total - quantized_summary.activity_total,
    workday_error_minutes = exact_summary.workday_total - quantized_summary.workday_total,
  }

  sort_summary_items(summary.items)
  sort_by_duration(summary.tag_items)
  sort_by_duration(summary.location_items)

  return summary
end

function M.quantized_summarize_block(block)
  return M.quantized_summarize_entries(block.entries, block.quantize_minutes)
end

return M
