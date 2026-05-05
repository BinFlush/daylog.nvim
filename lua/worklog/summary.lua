local M = {}

local function round_to_nearest_15(minutes)
  return math.floor((minutes + 7.5) / 15) * 15
end

local function summarize_labels(items)
  local buckets = {}
  local order = {}

  for _, item in ipairs(items) do
    local key = tostring(item.label)

    if not buckets[key] then
      buckets[key] = {
        label = item.label,
        duration = 0,
        excluded = item.excluded,
      }
      table.insert(order, key)
    end

    buckets[key].duration = buckets[key].duration + item.duration
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
    result[tostring(item.label)] = item
  end

  return result
end

function M.summarize(intervals, default_label)
  local buckets = {}
  local order = {}

  local activity_total = 0
  local workday_total = 0

  for _, iv in ipairs(intervals) do
    local key = iv.text .. "|" .. tostring(iv.label) .. "|" .. tostring(iv.excluded)

    if not buckets[key] then
      buckets[key] = {
        text = iv.text,
        label = iv.label,
        duration = 0,
        excluded = iv.excluded,
      }
      table.insert(order, key)
    end

    buckets[key].duration = buckets[key].duration + iv.duration

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

-- Quantize grouped summary rows together.
-- The overall activity total is rounded to the nearest 15 minutes, each grouped
-- item is rounded down, and the remaining 15-minute blocks are assigned to the
-- largest remainders. `#ooo` items participate in the same pass, but are
-- excluded from the final workday total.
function M.quantized_summarize(intervals, default_label)
  local summary = M.summarize(intervals, default_label)
  local exact_label_items = summary.label_items
  local target_total = round_to_nearest_15(summary.activity_total)
  local quantized_total = 0
  local ranked = {}

  for i, item in ipairs(summary.items) do
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
    local quantized_item = quantized_by_label[tostring(item.label)]

    table.insert(label_items, {
      label = item.label,
      duration = quantized_item and quantized_item.duration or 0,
      error_minutes = item.duration - (quantized_item and quantized_item.duration or 0),
      excluded = item.excluded,
    })
  end

  summary.label_items = label_items

  return summary
end

return M
