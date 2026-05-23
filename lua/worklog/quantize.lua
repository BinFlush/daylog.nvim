local projection = require("worklog.projection")

local M = {}

-- Quantization math.
--
-- Rounds fine-grained reporting rows to a bucket using the largest-remainder
-- method, then projects the quantized durations back onto the exact reporting
-- sections. summary.lua owns which row sets are quantized; this module owns the
-- arithmetic.

function M.round_to_nearest_bucket(minutes, bucket_minutes)
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

function M.apply_error_minutes(items)
  for _, item in ipairs(items) do
    item.error_minutes = (item.exact_duration or item.duration) - item.duration
  end

  return items
end

-- Round each row down to the bucket, then distribute the remaining
-- bucket-sized blocks (to reach `target_total`) to the largest remainders,
-- breaking ties by first-seen row order.
function M.quantize_rows(rows, bucket_minutes, target_total)
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

-- Reapply quantized durations onto exact ordered sections.
-- Exact rows define the visible labels and exact totals, while the quantized
-- rows provide the displayed duration after one shared quantization pass.
-- Provenance, when present on the exact item, flows into the quantized
-- projection so visible quantized rows can still be traced back to source.
function M.project_quantized_items(exact_items, quantized_items, key_fields, fields)
  local result = {}
  local quantized_index = projection.items_by_fields(quantized_items, key_fields)

  for _, item in ipairs(exact_items) do
    local projected = {}
    local quantized_item = projection.get_nested(quantized_index, item, key_fields)

    for _, field in ipairs(fields) do
      projected[field] = item[field]
    end

    -- Exact and quantized projections should stay aligned. Falling back to zero
    -- keeps this helper defensive if an internal mismatch ever slips through.
    projected.duration = quantized_item and quantized_item.duration or 0
    projected.exact_duration = item.exact_duration
    projected.error_minutes = item.duration - (quantized_item and quantized_item.duration or 0)

    if item.source_entry_rows then
      projected.source_entry_rows = item.source_entry_rows
    end

    table.insert(result, projected)
  end

  return result
end

return M
