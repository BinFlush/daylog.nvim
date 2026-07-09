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
-- the largest remainders, ties by first-seen order. A `logged_minutes` row is a frozen commitment held
-- at its value and pulled OUT of the pool, so leftovers distribute only over un-frozen rows.
function M.quantize_rows(rows, bucket_minutes, target_total)
  local result = copy_rows(rows)
  local quantized_total = 0
  local frozen_total = 0
  local ranked = {}

  for i, row in ipairs(result) do
    local unrounded_duration = row.unrounded_duration or row.duration
    row.unrounded_duration = unrounded_duration

    if row.logged_minutes ~= nil then
      row.duration = row.logged_minutes
      row.error_minutes = unrounded_duration - row.logged_minutes
      frozen_total = frozen_total + row.logged_minutes
    else
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
  end

  table.sort(ranked, function(a, b)
    if a.remainder == b.remainder then
      return a.index < b.index
    end

    return a.remainder > b.remainder
  end)

  local blocks = math.floor((target_total - frozen_total - quantized_total) / bucket_minutes)

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
    if row.nudge and row.nudge ~= 0 and row.logged_minutes == nil then
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

-- Quantize granules under cell-level commitments. Two passes: (1) honest largest-remainder over all
-- granules; (2) shift each committed cell's granules so the cell sums to its `target`, moving buckets to
-- the largest remainders (or off the smallest, round-down). `commitments` is a list of
-- `{ members = {granule indices}, target = minutes }`; disjoint and laminar commitments always succeed.
function M.constrained_quantize(granules, bucket_minutes, commitments)
  local unrounded_total = 0
  for _, row in ipairs(granules) do
    unrounded_total = unrounded_total + (row.unrounded_duration or row.duration)
  end

  local result = M.quantize_rows(
    granules,
    bucket_minutes,
    M.round_to_nearest_bucket(unrounded_total, bucket_minutes)
  )

  local function remainder(row)
    return (row.unrounded_duration or row.duration) - row.duration
  end

  for _, commitment in ipairs(commitments or {}) do
    local current = 0
    for _, index in ipairs(commitment.members) do
      current = current + result[index].duration
    end

    local delta = commitment.target - current
    if delta ~= 0 then
      local up = delta > 0
      local ordered = {}
      for _, index in ipairs(commitment.members) do
        ordered[#ordered + 1] = index
      end
      -- Buckets go to the rows that most want to round up (or off those that most want down), least
      -- error. Two explicit branches, not `cond and X or Y`: a false X would give a non-antisymmetric
      -- comparator Lua rejects.
      table.sort(ordered, function(a, b)
        local ra, rb = remainder(result[a]), remainder(result[b])
        if ra == rb then
          return a < b
        end
        if up then
          return ra > rb
        end
        return ra < rb
      end)

      local remaining = math.abs(delta) / bucket_minutes
      local cursor = 0
      local moved_this_cycle = false
      while remaining > 0 do
        local index = ordered[(cursor % #ordered) + 1]
        local row = result[index]
        if up or row.duration >= bucket_minutes then
          row.duration = row.duration + (up and bucket_minutes or -bucket_minutes)
          remaining = remaining - 1
          moved_this_cycle = true
        end
        cursor = cursor + 1
        -- Round-down can run out of room; stop only after a FULL cycle moved nothing, not a raw
        -- iteration count (which would abandon a still-feasible reduction, e.g. `{90,30}` -> 0).
        if not up and cursor % #ordered == 0 then
          if not moved_this_cycle then
            break
          end
          moved_this_cycle = false
        end
      end
    end
  end

  for _, row in ipairs(result) do
    row.error_minutes = remainder(row)
  end
  return result
end

return M
