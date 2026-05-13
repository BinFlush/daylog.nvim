local M = {}

-- Semantic reporting for worklog blocks.
--
-- Summaries are built directly from semantic entries or worklog blocks. The
-- module owns interval derivation, grouping, label totals, sorting, and
-- quantization so reporting stays a first-class semantic concern.

local NIL_LABEL_KEY = "\31"

local function round_to_nearest_15(minutes)
  return math.floor((minutes + 7.5) / 15) * 15
end

local function label_key(label)
  if label == nil then
    return NIL_LABEL_KEY
  end

  return label
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

local function summarize_labels(items)
  local buckets = {}
  local order = {}

  for _, item in ipairs(items) do
    local key = label_key(item.label)

    if not buckets[key] then
      buckets[key] = {
        label = item.label,
        duration = 0,
        exact_duration = 0,
        excluded = item.excluded,
      }
      table.insert(order, key)
    end

    buckets[key].duration = buckets[key].duration + item.duration
    buckets[key].exact_duration = buckets[key].exact_duration + (item.exact_duration or item.duration)
  end

  local label_items = {}

  for _, key in ipairs(order) do
    table.insert(label_items, buckets[key])
  end

  return label_items
end

local function label_items_by_key(items)
  local result = {}

  for _, item in ipairs(items) do
    result[label_key(item.label)] = item
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
      label = current.label,
      excluded = current.excluded,
    })
  end

  return intervals
end

local function build_summary_from_intervals(intervals, default_label)
  local buckets = {}
  local order = {}

  local activity_total = 0
  local workday_total = 0

  for _, iv in ipairs(intervals) do
    local key = iv.text .. "|" .. label_key(iv.label) .. "|" .. tostring(iv.excluded)

    if not buckets[key] then
      buckets[key] = {
        text = iv.text,
        label = iv.label,
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
    label_items = summarize_labels(items),
    default_label = default_label,
    activity_total = activity_total,
    workday_total = workday_total,
  }
end

function M.summarize_entries(entries, default_label)
  local summary = build_summary_from_intervals(build_intervals(entries), default_label)

  sort_by_duration(summary.items)
  sort_by_duration(summary.label_items)

  return summary
end

function M.summarize_block(block)
  return M.summarize_entries(block.entries, block.default_label)
end

-- Quantize grouped summary rows together.
-- The overall activity total is rounded to the nearest 15 minutes, each grouped
-- item is rounded down, and the remaining 15-minute blocks are assigned to the
-- largest remainders. `#ooo` items participate in the same pass, but are
-- excluded from the final workday total.
function M.quantized_summarize_entries(entries, default_label)
  local summary = build_summary_from_intervals(build_intervals(entries), default_label)
  local exact_label_items = summary.label_items
  local exact_activity_total = summary.activity_total
  local exact_workday_total = summary.workday_total
  local target_total = round_to_nearest_15(summary.activity_total)
  local quantized_total = 0
  local ranked = {}

  for i, item in ipairs(summary.items) do
    item.exact_duration = item.duration
    local base = math.floor(item.duration / 15) * 15
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

  local blocks = math.floor((target_total - quantized_total) / 15)

  for i = 1, blocks do
    local ranked_item = ranked[i]
    if ranked_item then
      summary.items[ranked_item.index].duration = summary.items[ranked_item.index].duration + 15
      summary.items[ranked_item.index].error_minutes = summary.items[ranked_item.index].error_minutes - 15
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

  local quantized_label_items = summarize_labels(summary.items)
  local quantized_by_label = label_items_by_key(quantized_label_items)
  local label_items = {}

  for _, item in ipairs(exact_label_items) do
    local quantized_item = quantized_by_label[label_key(item.label)]

    table.insert(label_items, {
      label = item.label,
      duration = quantized_item and quantized_item.duration or 0,
      exact_duration = item.exact_duration,
      error_minutes = item.duration - (quantized_item and quantized_item.duration or 0),
      excluded = item.excluded,
    })
  end

  summary.label_items = label_items
  summary.activity_error_minutes = exact_activity_total - summary.activity_total
  summary.workday_error_minutes = exact_workday_total - summary.workday_total

  sort_by_duration(summary.items)
  sort_by_duration(summary.label_items)

  return summary
end

function M.quantized_summarize_block(block)
  return M.quantized_summarize_entries(block.entries, block.default_label)
end

return M
