local M = {}

-- Quantization math (PURE): largest-remainder rounding of reporting rows to a bucket.
-- summary.lua owns which row sets are quantized; this module owns the arithmetic.

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

-- Set each item's error_minutes to exact-minus-displayed (unrounded - rounded).
function M.apply_error_minutes(items)
  for _, item in ipairs(items) do
    item.error_minutes = (item.unrounded_duration or item.duration) - item.duration
  end

  return items
end

-- Round each row down to the bucket, then distribute the leftover buckets (to reach `target_total`) to
-- the largest remainders, ties by first-seen order. Marker-blind: logged claims never reach here, they
-- pin their entries' shares afterwards (claims.lua).
function M.quantize_rows(rows, bucket_minutes, target_total)
  local result = copy_rows(rows)
  local quantized_total = 0
  local ranked = {}

  for i, row in ipairs(result) do
    local unrounded_duration = row.unrounded_duration or row.duration
    row.unrounded_duration = unrounded_duration

    local base = math.floor(unrounded_duration / bucket_minutes) * bucket_minutes
    local remainder = unrounded_duration - base

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

  -- Second pass: apply per-row manual nudges (+k rounds up k more buckets) on the baseline. The duration
  -- clamps at zero; a nudge carrying it below zero sets `nudge_below_zero` so refresh can warn the marker
  -- no longer reconciles.
  for _, row in ipairs(result) do
    if row.nudge and row.nudge ~= 0 then
      local base = math.floor(row.unrounded_duration / bucket_minutes) * bucket_minutes
      local current_blocks = (row.duration - base) / bucket_minutes
      local nudged = base + (current_blocks + row.nudge) * bucket_minutes
      if nudged < 0 then
        row.nudge_below_zero = true
      end
      row.duration = math.max(0, nudged)
      row.error_minutes = row.unrounded_duration - row.duration
    end
  end

  return result
end

return M
