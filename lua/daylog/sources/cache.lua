local M = {}

-- Pure cache codec and policy for source items (no IO/Neovim API); the shell injects a JSON
-- decoder, so envelope validation and TTL math stay unit-testable.

local VERSION = 1
M.VERSION = VERSION

-- Build the on-disk envelope for a set of items. The shell JSON-encodes this.
function M.encode(items, fetched_at)
  return {
    version = VERSION,
    fetched_at = fetched_at,
    items = items or {},
  }
end

-- Decode and validate a JSON cache string via the injected decode_fn; a corrupt or
-- wrong-version cache returns nil plus an error so callers re-sync rather than crash.
function M.decode(json, decode_fn)
  local ok, decoded = pcall(decode_fn, json)
  if not ok or type(decoded) ~= "table" then
    return nil, "daylog: source cache is corrupt"
  end

  if decoded.version ~= VERSION then
    return nil, "daylog: source cache version is unsupported"
  end

  if type(decoded.items) ~= "table" then
    return nil, "daylog: source cache is corrupt"
  end

  return {
    version = decoded.version,
    fetched_at = type(decoded.fetched_at) == "number" and decoded.fetched_at or 0,
    items = decoded.items,
  }
end

-- A cache needs a refresh when it is missing or older than ttl seconds.
function M.is_stale(cache, now, ttl)
  if cache == nil then
    return true
  end

  return (now - (cache.fetched_at or 0)) >= ttl
end

return M
