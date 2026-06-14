local M = {}

-- Pure helpers for the live-search picker. No Telescope and no Neovim API, so the
-- pooling/loop-guard logic stays unit-testable; worklog.telescope wires these into
-- the actual finder/refresh glue.

-- Union of the cached/default items and freshly fetched server results, deduped by
-- id with the cached items first. Live search grows the pool without ever dropping
-- cached items or emptying it.
function M.merge(initial, extra)
  local seen, out = {}, {}
  for _, list in ipairs({ initial or {}, extra or {} }) do
    for _, item in ipairs(list) do
      local key = tostring(item.id)
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = item
      end
    end
  end
  return out
end

-- Whether a prompt change should trigger a fresh server search: at least min_len
-- characters and different from the last query we issued. min_len gates the
-- network so short, broad prompts only filter the cached pool client-side; it
-- defaults to 1 and is clamped to >= 1 so an empty prompt never searches. A picker
-- refresh re-fires the input hook with the same prompt, so the last_query check
-- breaks that loop.
function M.should_query(prompt, last_query, min_len)
  min_len = min_len or 1
  if min_len < 1 then
    min_len = 1
  end
  return #prompt >= min_len and prompt ~= last_query
end

return M
