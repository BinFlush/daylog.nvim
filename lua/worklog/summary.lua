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

local function summarize_metadata(items, field, nil_key)
  local buckets = {}
  local order = {}

  for _, item in ipairs(items) do
    local key = metadata_key(item[field], nil_key)

    if not buckets[key] then
      buckets[key] = {
        [field] = item[field],
        duration = 0,
        exact_duration = 0,
      }
      table.insert(order, key)
    end

    buckets[key].duration = buckets[key].duration + item.duration
    buckets[key].exact_duration = buckets[key].exact_duration + (item.exact_duration or item.duration)
  end

  local summary_items = {}

  for _, key in ipairs(order) do
    table.insert(summary_items, buckets[key])
  end

  return summary_items
end

local function items_by_key(items, field, nil_key)
  local result = {}

  for _, item in ipairs(items) do
    result[metadata_key(item[field], nil_key)] = item
  end

  return result
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

local function build_summary_from_intervals(intervals)
  local buckets = {}
  local order = {}

  local activity_total = 0
  local workday_total = 0

  for _, iv in ipairs(intervals) do
    local key = table.concat({
      iv.text,
      metadata_key(iv.tag, NIL_TAG_KEY),
      metadata_key(iv.location, NIL_LOCATION_KEY),
      tostring(iv.excluded),
    }, "|")

    if not buckets[key] then
      buckets[key] = {
        text = iv.text,
        tag = iv.tag,
        location = iv.location,
        duration = 0,
        exact_duration = 0,
        excluded = iv.excluded,
      }
      table.insert(order, key)
    end

    buckets[key].duration = buckets[key].duration + iv.duration
    buckets[key].exact_duration = buckets[key].exact_duration + iv.duration

    activity_total = activity_total + iv.duration

    if not iv.excluded then
      workday_total = workday_total + iv.duration
    end
  end

  local items = {}

  for _, key in ipairs(order) do
    table.insert(items, buckets[key])
  end

  return {
    items = items,
    tag_items = summarize_metadata(items, "tag", NIL_TAG_KEY),
    location_items = summarize_metadata(items, "location", NIL_LOCATION_KEY),
    activity_total = activity_total,
    workday_total = workday_total,
  }
end

function M.summarize_entries(entries)
  local summary = build_summary_from_intervals(build_intervals(entries))

  sort_by_duration(summary.items)
  sort_by_duration(summary.tag_items)
  sort_by_duration(summary.location_items)

  return summary
end

function M.summarize_block(block)
  return M.summarize_entries(block.entries)
end

-- Quantize grouped summary rows together.
-- The overall activity total is rounded to the nearest configured bucket, each
-- grouped item is rounded down to that bucket, and the remaining bucket-sized
-- blocks are assigned to the largest remainders. `#ooo` items participate in
-- the same pass, but are excluded from the final workday total.
function M.quantized_summarize_entries(entries, quantize_minutes)
  local bucket_minutes = quantize_minutes or 15
  local summary = build_summary_from_intervals(build_intervals(entries))
  local exact_tag_items = summary.tag_items
  local exact_location_items = summary.location_items
  local exact_activity_total = summary.activity_total
  local exact_workday_total = summary.workday_total
  local target_total = round_to_nearest_bucket(summary.activity_total, bucket_minutes)
  local quantized_total = 0
  local ranked = {}

  for i, item in ipairs(summary.items) do
    item.exact_duration = item.duration
    local base = math.floor(item.duration / bucket_minutes) * bucket_minutes
    local remainder = item.duration - base

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
      summary.items[ranked_item.index].duration = summary.items[ranked_item.index].duration + bucket_minutes
      summary.items[ranked_item.index].error_minutes = summary.items[ranked_item.index].error_minutes - bucket_minutes
    end
  end

  summary.activity_total = 0
  summary.workday_total = 0

  for _, item in ipairs(summary.items) do
    summary.activity_total = summary.activity_total + item.duration

    if not item.excluded then
      summary.workday_total = summary.workday_total + item.duration
    end
  end

  local quantized_tag_items = summarize_metadata(summary.items, "tag", NIL_TAG_KEY)
  local quantized_by_tag = items_by_key(quantized_tag_items, "tag", NIL_TAG_KEY)
  local tag_items = {}

  for _, item in ipairs(exact_tag_items) do
    local quantized_item = quantized_by_tag[metadata_key(item.tag, NIL_TAG_KEY)]

    table.insert(tag_items, {
      tag = item.tag,
      duration = quantized_item and quantized_item.duration or 0,
      exact_duration = item.exact_duration,
      error_minutes = item.duration - (quantized_item and quantized_item.duration or 0),
    })
  end

  local quantized_location_items = summarize_metadata(summary.items, "location", NIL_LOCATION_KEY)
  local quantized_by_location = items_by_key(quantized_location_items, "location", NIL_LOCATION_KEY)
  local location_items = {}

  for _, item in ipairs(exact_location_items) do
    local quantized_item = quantized_by_location[metadata_key(item.location, NIL_LOCATION_KEY)]

    table.insert(location_items, {
      location = item.location,
      duration = quantized_item and quantized_item.duration or 0,
      exact_duration = item.exact_duration,
      error_minutes = item.duration - (quantized_item and quantized_item.duration or 0),
    })
  end

  summary.tag_items = tag_items
  summary.location_items = location_items
  summary.activity_error_minutes = exact_activity_total - summary.activity_total
  summary.workday_error_minutes = exact_workday_total - summary.workday_total

  sort_by_duration(summary.items)
  sort_by_duration(summary.tag_items)
  sort_by_duration(summary.location_items)

  return summary
end

function M.quantized_summarize_block(block)
  return M.quantized_summarize_entries(block.entries, block.quantize_minutes)
end

return M
