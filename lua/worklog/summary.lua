local M = {}

local function round_to_nearest_15(minutes)
  return math.floor((minutes + 7.5) / 15) * 15
end

function M.summarize(intervals)
  local buckets = {}
  local order = {}

  local activity_total = 0
  local workday_total = 0

  for _, iv in ipairs(intervals) do
    local key = iv.text .. "|" .. tostring(iv.excluded)

    if not buckets[key] then
      buckets[key] = {
        text = iv.text,
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
    activity_total = activity_total,
    workday_total = workday_total,
  }
end

-- Quantize grouped summary rows together.
-- The overall activity total is rounded to the nearest 15 minutes, each grouped
-- item is rounded down, and the remaining 15-minute blocks are assigned to the
-- largest remainders. `#ooo` items participate in the same pass, but are
-- excluded from the final workday total.
function M.quantized_summarize(intervals)
  local summary = M.summarize(intervals)
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

  return summary
end

return M
