local M = {}

-- Split apportionment math. PURE.
--
-- :Daylog split cuts each of an activity's time intervals into N weighted
-- sub-activities by whole minutes. The interval endpoints are fixed, so each
-- interval's parts must sum exactly to its length (a row sum), while each
-- sub-activity's total across all the activity's intervals should track its weighted
-- share p_i * T as closely as possible (a soft column target). This module owns that
-- 2-D rounding; the usecase owns turning it into entries.
--
-- The method is an error-carrying largest remainder, processing intervals in
-- chronological order. A short interval that cannot afford every part yields zeros for
-- the ones it skips; the unmet fractional share rolls into `carry` and is repaid by a
-- later, longer interval -- so the column totals stay near target even when individual
-- rows are too small to split evenly.

-- Distribute a list of interval `durations` (whole minutes) across #`weights`
-- sub-activities. Returns an integer matrix `m[j][i] >= 0` whose row j sums exactly to
-- `durations[j]`; column i sums track `p_i * sum(durations)`. Precondition: weights are
-- positive and sum to a positive number (the usecase validates this).
function M.allocate(durations, weights)
  local n = #weights

  local total_weight = 0
  for _, w in ipairs(weights) do
    total_weight = total_weight + w
  end

  local p = {}
  for i = 1, n do
    p[i] = weights[i] / total_weight
  end

  -- carry[i] is the as-yet-unpaid share for sub-activity i (its fractional debt). It
  -- stays within (-1, 1) and sums to zero across i, so the columns track p_i*T exactly
  -- up to the final rounding.
  local carry = {}
  for i = 1, n do
    carry[i] = 0
  end

  local matrix = {}

  for j, duration in ipairs(durations) do
    local want = {}
    local a = {}
    local assigned = 0

    for i = 1, n do
      want[i] = p[i] * duration + carry[i]
      local floored = math.floor(want[i])
      if floored < 0 then
        floored = 0
      end
      a[i] = floored
      assigned = assigned + floored
    end

    -- Reconcile the row to its exact total. |diff| < n, so these loops are cheap.
    -- Hand a leftover minute to the part that wants it most (largest want-a); take a
    -- surplus minute from the part that wants it least, never below zero.
    local diff = duration - assigned
    if diff > 0 then
      for _ = 1, diff do
        local best
        for i = 1, n do
          local desire = want[i] - a[i]
          if not best or desire > best.desire then
            best = { index = i, desire = desire }
          end
        end
        a[best.index] = a[best.index] + 1
      end
    elseif diff < 0 then
      for _ = 1, -diff do
        local best
        for i = 1, n do
          if a[i] >= 1 then
            local desire = want[i] - a[i]
            if not best or desire < best.desire then
              best = { index = i, desire = desire }
            end
          end
        end
        a[best.index] = a[best.index] - 1
      end
    end

    for i = 1, n do
      carry[i] = want[i] - a[i]
    end

    matrix[j] = a
  end

  return matrix
end

-- Turn one allocation row into its present sub-activities in index order, each with
-- the minute offset from the interval start where its sub-entry begins. Zero-minute
-- parts are dropped (no sub-entry is created for them in this interval), so the offsets
-- of the present parts are strictly increasing and each part is at least one minute.
function M.parts(allocation_row)
  local parts = {}
  local offset = 0

  for index, minutes in ipairs(allocation_row) do
    if minutes > 0 then
      parts[#parts + 1] = { index = index, offset = offset, minutes = minutes }
    end
    offset = offset + minutes
  end

  return parts
end

return M
