local M = {}

-- Quantization math.
--
-- Rounds fine-grained reporting rows to a bucket using the largest-remainder
-- method, then projects the rounded durations back onto the unrounded reporting
-- sections. summary.lua owns which row sets are quantized; this module owns the
-- arithmetic.

function M.round_to_nearest_bucket(minutes, bucket_minutes)
  return math.floor((minutes + (bucket_minutes / 2)) / bucket_minutes) * bucket_minutes
end

-- The quantization target for a set of fine-grained rows. Frozen (`logged_minutes`)
-- rows are external commitments held at exactly their committed value, so they are not
-- rounded: the un-frozen rows round to their OWN nearest-bucket total and the frozen
-- commitments are added on top. The day total is thus the honest sum of the displayed
-- parts -- a frozen row's manual `round±N` (which lowers only its own value) can no
-- longer push an un-frozen row around to keep some abstract whole-day total. With no
-- frozen rows this is just `round_to_nearest_bucket` of the whole, as before.
function M.frozen_aware_target(rows, bucket_minutes)
  local frozen_total = 0
  local unfrozen_unrounded = 0

  for _, row in ipairs(rows) do
    if row.logged_minutes ~= nil then
      frozen_total = frozen_total + row.logged_minutes
    else
      unfrozen_unrounded = unfrozen_unrounded + (row.unrounded_duration or row.duration)
    end
  end

  return M.round_to_nearest_bucket(unfrozen_unrounded, bucket_minutes) + frozen_total
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

-- Round each row down to the bucket, then distribute the remaining
-- bucket-sized blocks (to reach `target_total`) to the largest remainders,
-- breaking ties by first-seen row order.
--
-- A row carrying `logged_minutes` is a frozen external commitment: it is held at
-- exactly that value and pulled OUT of the largest-remainder pool, so the leftover
-- buckets distribute only over the un-frozen rows against the reduced budget
-- `target_total - frozen_total`. With `target_total` from `frozen_aware_target` that
-- budget is exactly the un-frozen rows' own nearest-bucket total, so a committed row
-- never moves when later entries are appended, and its manual `round±N` can never push
-- an un-frozen row around to prop up some abstract whole-day total.
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

  -- Second pass: apply per-row manual rounding nudges on top of the largest-remainder
  -- baseline. A nudge of +k rounds the row up k more buckets (-k down); because every
  -- displayed section is a sum of these same rows, the shift flows consistently into
  -- the section totals and each section stays a partition. The displayed duration is
  -- clamped at zero (a row can never show negative time); when a nudge would carry the
  -- row below zero the clamp is recorded in `nudge_below_zero` so the refresh pass can
  -- warn that the (hand-written or drifted) marker no longer reconciles.
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

-- Quantize fine-grained rows the way daylog reports them: hold frozen (!S) rows at their
-- commitment and round the un-frozen rows to their own bucket total (frozen_aware_target).
-- The single entry point the display and the committed-value readers share, so they cannot
-- drift apart (a past bug: the two computed the target separately and one lagged).
function M.quantize_fine_grained(rows, bucket_minutes)
  return M.quantize_rows(rows, bucket_minutes, M.frozen_aware_target(rows, bucket_minutes))
end

-- Quantize granule rows to buckets under cell-level commitments, treating each commitment as a
-- rounding of its cell to a committed value. Two passes: (1) honest largest-remainder over all
-- granules (respecting each granule's manual `nudge`); (2) shift each committed cell's granules so the
-- cell sums to its `target` (a bucket multiple), moving buckets to the largest remainders (or off the
-- smallest, for a round-down). Because every report partition is a re-sum of these same granules, all
-- partitions then foot to the same total -- a commitment propagates everywhere the time appears, exactly
-- like a nudge. `commitments` is a list of `{ members = {granule indices}, target = minutes }`; disjoint
-- (single-level) and nested (laminar) commitments always succeed. Returns a fresh row list with
-- `duration` + `error_minutes`.
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
      -- Give buckets to the rows that most want to round up (largest remainder), or take them off the
      -- rows that most want to round down (smallest remainder), so the shift adds the least error. Two
      -- explicit branches, not the `cond and X or Y` idiom -- X (`ra > rb`) can be false, which would
      -- collapse the idiom to `ra < rb` and yield a non-antisymmetric comparator (Lua rejects it).
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
        -- Round-down can run out of room (every member already at zero). Stop only after a FULL cycle
        -- moved nothing -- not after a raw iteration count, which would abandon a still-feasible
        -- reduction partway (`{90,30}` -> 0 must reach 0, not stop at 30). Up never gets stuck.
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
