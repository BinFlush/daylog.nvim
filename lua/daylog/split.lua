local M = {}

-- Split apportionment math. PURE.
--
-- :Daylog split cuts each of an activity's intervals into N weighted sub-activities by whole
-- minutes. Each interval's parts must sum exactly to its length (row sum); each sub-activity's
-- total should track its weighted share p_i * T (soft column target). The method is an
-- error-carrying largest remainder over intervals in order: a share a short interval can't afford
-- rolls into `carry` and is repaid by a later one, keeping columns near target.

-- Distribute interval `durations` (whole minutes) across #`weights` sub-activities: returns an
-- integer matrix `m[j][i] >= 0`, row j summing exactly to `durations[j]`, column i tracking
-- `p_i * sum(durations)`. Precondition: weights positive (the usecase validates this).
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

  -- carry[i] is sub-activity i's unpaid fractional share; it stays in (-1, 1) and sums to
  -- zero across i, so the columns track p_i*T up to the final rounding.
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

    -- Reconcile the row to its exact total (|diff| < n): give a leftover minute to the part
    -- wanting it most, take a surplus from the part wanting it least, never below zero.
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

-- Turn one allocation row into its present sub-activities in index order, each with its
-- minute offset from the interval start; zero-minute parts are dropped.
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
