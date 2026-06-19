local M = {}

-- Generic row grouping and projection.
--
-- No blotter domain knowledge: callers pass the key fields that define a
-- bucket's identity and the descriptive fields that survive into each projected
-- row. summary.lua and quantize.lua build all their reporting sections on top of
-- these helpers.

local NIL = {}

local function normalize_key_part(value)
  if value == nil then
    return NIL
  end

  return value
end

local function get_nested(root, item, key_fields)
  local node = root

  assert(#key_fields > 0, "get_nested requires at least one key field")

  for i = 1, #key_fields do
    node = node[normalize_key_part(item[key_fields[i]])]

    if not node then
      return nil
    end
  end

  return node
end

local function put_nested(root, item, key_fields, value)
  local node = root

  assert(#key_fields > 0, "put_nested requires at least one key field")

  for i = 1, #key_fields - 1 do
    local key = normalize_key_part(item[key_fields[i]])

    if not node[key] then
      node[key] = {}
    end

    node = node[key]
  end

  node[normalize_key_part(item[key_fields[#key_fields]])] = value
end

-- Project rows into coarser reporting buckets.
-- `key_fields` decides which row fields define identity, while `fields` decides
-- which descriptive labels survive into the projected row.
-- Durations are always accumulated, and first-seen group order is preserved.
-- When `accumulate_source_blot_rows` is true, every row's `source_blot_rows`
-- (or single `source_blot_row`) is concatenated into the bucket in stable
-- source order so main summary items can carry provenance back to the
-- contributing blots.
-- `nudge_mode` controls how the manual rounding nudge aggregates into a bucket:
-- "sum" (the default) adds it up -- correct when projecting fine-grained rows into
-- sections, where a section's nudge is the cumulative shift of its rows. "max"
-- takes the signed value of largest magnitude -- correct when folding the intervals
-- of one fine-grained row, which all carry that row's single nudge (so marking some
-- or all of an activity's intervals yields the same row nudge, never a multiple).
function M.project_rows(rows, key_fields, fields, accumulate_source_blot_rows, nudge_mode)
  local buckets = {}
  local order = {}

  for _, row in ipairs(rows) do
    local bucket = get_nested(buckets, row, key_fields)

    if not bucket then
      bucket = {
        duration = 0,
        unrounded_duration = 0,
      }

      for _, field in ipairs(fields) do
        bucket[field] = row[field]
      end

      if accumulate_source_blot_rows then
        bucket.source_blot_rows = {}
      end

      put_nested(buckets, row, key_fields, bucket)
      table.insert(order, bucket)
    end

    bucket.duration = bucket.duration + row.duration
    bucket.unrounded_duration = bucket.unrounded_duration + (row.unrounded_duration or row.duration)
    -- The manual rounding nudge stays sparse (absent unless a nonzero nudge
    -- contributes), so a blotter with no manual balancing projects to byte-identical
    -- rows. "max" folds an activity's intervals to its single row nudge; "sum"
    -- accumulates rows into a section's cumulative nudge.
    if row.nudge and row.nudge ~= 0 then
      if nudge_mode == "max" then
        if not bucket.nudge or math.abs(row.nudge) > math.abs(bucket.nudge) then
          bucket.nudge = row.nudge
        end
      else
        bucket.nudge = (bucket.nudge or 0) + row.nudge
      end
    end

    if accumulate_source_blot_rows then
      if row.source_blot_rows then
        for _, source_row in ipairs(row.source_blot_rows) do
          table.insert(bucket.source_blot_rows, source_row)
        end
      elseif row.source_blot_row then
        table.insert(bucket.source_blot_rows, row.source_blot_row)
      end
    end
  end

  return order
end

-- Index items by their key fields for later lookup with `get_nested`.
function M.items_by_fields(items, key_fields)
  local result = {}

  for _, item in ipairs(items) do
    put_nested(result, item, key_fields, item)
  end

  return result
end

M.get_nested = get_nested

return M
