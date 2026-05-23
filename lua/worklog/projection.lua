local M = {}

-- Generic row grouping and projection.
--
-- No worklog domain knowledge: callers pass the key fields that define a
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
-- When `accumulate_source_entry_rows` is true, every row's `source_entry_rows`
-- (or single `source_entry_row`) is concatenated into the bucket in stable
-- source order so main summary items can carry provenance back to the
-- contributing entries.
function M.project_rows(rows, key_fields, fields, accumulate_source_entry_rows)
  local buckets = {}
  local order = {}

  for _, row in ipairs(rows) do
    local bucket = get_nested(buckets, row, key_fields)

    if not bucket then
      bucket = {
        duration = 0,
        exact_duration = 0,
      }

      for _, field in ipairs(fields) do
        bucket[field] = row[field]
      end

      if accumulate_source_entry_rows then
        bucket.source_entry_rows = {}
      end

      put_nested(buckets, row, key_fields, bucket)
      table.insert(order, bucket)
    end

    bucket.duration = bucket.duration + row.duration
    bucket.exact_duration = bucket.exact_duration + (row.exact_duration or row.duration)

    if accumulate_source_entry_rows then
      if row.source_entry_rows then
        for _, source_row in ipairs(row.source_entry_rows) do
          table.insert(bucket.source_entry_rows, source_row)
        end
      elseif row.source_entry_row then
        table.insert(bucket.source_entry_rows, row.source_entry_row)
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
