local cache = require("daylog.sources.cache")
local registry = require("daylog.sources.registry")

local M = {}

-- Source cache IO and the lazy-TTL / manual-sync policy. This is shell code: it
-- reads and writes the on-disk cache and drives the (only) networked path via the
-- source's fetch. Pick-time stays offline by reading the cache here.

local in_flight = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

local function warn(message)
  vim.notify(message, vim.log.levels.WARN)
end

function M.cache_path(name)
  return vim.fn.stdpath("cache") .. "/daylog/sources/" .. name .. ".json"
end

-- Read and validate the on-disk cache for a source, or nil when it is missing or
-- corrupt (a corrupt cache is reported and treated as absent so it self-heals on
-- the next sync).
function M.read_cache(name)
  local path = M.cache_path(name)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  local content = table.concat(vim.fn.readfile(path), "\n")
  local decoded, err = cache.decode(content, vim.json.decode)
  if not decoded then
    warn(err .. ": " .. name)
    return nil
  end

  return decoded
end

function M.read_items(name)
  local decoded = M.read_cache(name)
  return decoded and decoded.items or {}
end

function M.write_cache(name, items, now)
  local path = M.cache_path(name)
  local ok = pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    -- Write to a temp file then rename, so a reader in another Neovim never sees a
    -- half-written cache.
    local tmp = path .. ".tmp"
    vim.fn.writefile({ vim.json.encode(cache.encode(items, now)) }, tmp)
    os.rename(tmp, path)
  end)

  if not ok then
    warn("daylog: failed to write source cache: " .. name)
  end

  return ok
end

function M.is_in_flight(name)
  return in_flight[name] == true
end

-- Fetch fresh items for a source and write them to the cache. opts.silent
-- suppresses the success message (used by background refreshes). A per-source
-- guard keeps a manual sync and a background refresh from overlapping.
function M.sync(name, opts, cb)
  opts = opts or {}
  cb = cb or function() end

  if in_flight[name] then
    return cb(false)
  end

  local source = registry.get(name)
  if not source then
    warn("daylog: unknown source '" .. name .. "'")
    return cb(false)
  end

  in_flight[name] = true

  local ok, err = pcall(function()
    source.fetch(function(items, fetch_err)
      in_flight[name] = false

      if not items then
        warn(fetch_err or ("daylog: sync failed: " .. name))
        return cb(false, fetch_err)
      end

      -- write_cache already warns on failure; don't also report success when the
      -- items never reached disk.
      if not M.write_cache(name, items, os.time()) then
        return cb(false)
      end

      if not opts.silent then
        notify(string.format("daylog: synced %d items from %s", #items, name))
      end
      cb(true)
    end)
  end)

  if not ok then
    in_flight[name] = false
    warn("daylog: sync failed: " .. tostring(err))
    cb(false)
  end
end

-- The picker data path: hand the current cached items to on_ready immediately
-- (offline, instant), then refresh in the background when stale. The first-ever
-- use with no cache fetches once before opening. `on_unavailable` (optional) is called
-- when there is no cache and that initial fetch fails -- callers that have a local
-- fallback (e.g. :DaylogRename's merge candidates) use it to open anyway.
function M.ensure_fresh(name, ttl, on_ready, on_unavailable)
  local decoded = M.read_cache(name)

  if decoded then
    on_ready(decoded.items or {})
    if cache.is_stale(decoded, os.time(), ttl) and not in_flight[name] then
      M.sync(name, { silent = true })
    end
    return
  end

  notify("daylog: syncing " .. name .. "…")
  M.sync(name, { silent = true }, function(ok)
    -- Hand over the items when the initial fetch succeeded (a successful empty result
    -- still opens). On failure sync has already warned, so the source items are simply
    -- absent; let a caller with a local fallback open without them.
    if ok then
      on_ready(M.read_items(name))
    elseif on_unavailable then
      on_unavailable()
    end
  end)
end

return M
