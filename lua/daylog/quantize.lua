local projection = require("daylog.projection")

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

-- Set each item's error_minutes to exact-minus-displayed (unrounded - rounded). This
-- is the same quantity project_quantized_items derives during a quantization pass,
-- only here the items already carry both durations (the combine path re-projects
-- already-rounded day rows, whose duration == unrounded_duration, giving a 0 error).
-- The two paths are kept separate on purpose -- unifying them would add a pass and
-- couple two helpers in the footing-critical path to save one subtraction.
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

-- Reapply the rounded durations onto the unrounded ordered sections.
-- The unrounded rows define the visible labels and true totals, while the rounded
-- rows provide the displayed duration after one shared quantization pass.
-- Provenance, when present on the unrounded item, flows into the projection so
-- visible rows can still be traced back to source.
function M.project_quantized_items(unrounded_items, quantized_items, key_fields, fields)
  local result = {}
  local quantized_index = projection.items_by_fields(quantized_items, key_fields)

  for _, item in ipairs(unrounded_items) do
    local projected = {}
    local quantized_item = projection.get_nested(quantized_index, item, key_fields)

    for _, field in ipairs(fields) do
      projected[field] = item[field]
    end

    -- The unrounded and rounded projections should stay aligned. Falling back to zero
    -- keeps this helper defensive if an internal mismatch ever slips through.
    projected.duration = quantized_item and quantized_item.duration or 0
    projected.unrounded_duration = item.unrounded_duration
    projected.error_minutes = item.duration - (quantized_item and quantized_item.duration or 0)
    -- Carry the cumulative manual nudge through to the displayed item so render can
    -- surface the round±N marker. Sparse: only set when nonzero, so an unbalanced
    -- summary keeps its exact shape.
    if quantized_item and quantized_item.nudge and quantized_item.nudge ~= 0 then
      projected.nudge = quantized_item.nudge
    end

    if item.source_entry_rows then
      projected.source_entry_rows = item.source_entry_rows
    end

    table.insert(result, projected)
  end

  return result
end

return M
