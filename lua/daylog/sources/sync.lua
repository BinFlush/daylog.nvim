local cache = require("daylog.sources.cache")
local config = require("daylog.config")
local registry = require("daylog.sources.registry")

local M = {}

-- Source cache IO and the lazy-TTL / manual-sync policy (shell); pick-time reads the cache here to stay offline.

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

-- Read and validate the on-disk cache, or nil when missing or corrupt (a corrupt
-- cache is treated as absent so it self-heals on the next sync).
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
  local tmp = path .. ".tmp"
  -- Write to a temp file then atomically rename, so a concurrent reader never sees a half-written
  -- cache; vim.loop.fs_rename overwrites cross-platform (os.rename cannot on native Windows).
  local ok = pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ vim.json.encode(cache.encode(items, now)) }, tmp)
    assert(vim.loop.fs_rename(tmp, path))
  end)

  if not ok then
    -- A failed rename (or a throw mid-write) can strand the temp file; drop it best-effort.
    os.remove(tmp)
    warn("daylog: failed to write source cache: " .. name)
  end

  return ok
end

function M.is_in_flight(name)
  return in_flight[name] == true
end

-- Fetch fresh items into the cache; opts.silent suppresses the success message. A
-- per-source guard stops a manual sync and a background refresh overlapping.
function M.sync(name, opts, cb)
  opts = opts or {}
  cb = cb or function() end

  if in_flight[name] then
    warn("daylog: sync already running for " .. name)
    return cb(false)
  end

  local source = registry.get(name)
  if not source then
    warn("daylog: unknown source '" .. name .. "'")
    return cb(false)
  end

  in_flight[name] = true

  -- The pcall also catches a synchronous throw from inside the fetch callback; `finished`
  -- records the callback ran so the error branch never calls cb twice.
  local finished = false

  local ok, err = pcall(function()
    source.fetch(function(items, fetch_err, total)
      finished = true
      in_flight[name] = false

      if not items then
        warn(fetch_err or ("daylog: sync failed: " .. name))
        return cb(false, fetch_err)
      end

      -- write_cache already warns on failure; don't report success when items never reached disk.
      if not M.write_cache(name, items, os.time()) then
        return cb(false)
      end

      if not opts.silent then
        -- The source caps how many items it hydrates; warn when it truncated so the offline cache is
        -- not silently missing items (the Telescope live path shows the same on its search results).
        if total and total > #items then
          warn(
            string.format(
              "daylog: synced the first %d of %d items from %s; narrow its query to cache the rest",
              #items,
              total,
              name
            )
          )
        else
          notify(string.format("daylog: synced %d items from %s", #items, name))
        end
      end
      cb(true)
    end)
  end)

  if not ok then
    in_flight[name] = false
    warn("daylog: sync failed: " .. tostring(err))
    if not finished then
      cb(false)
    end
  end
end

-- Hand cached items to on_ready immediately (offline), refreshing in the background when
-- stale; the first-ever use with no cache fetches once. `on_unavailable` (optional) fires
-- when there is no cache and the initial fetch fails, so a caller with a local fallback opens anyway.
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
    -- Hand over items on a successful fetch (empty still opens); on failure sync already
    -- warned, so let a caller with a local fallback open without them.
    if ok then
      on_ready(M.read_items(name))
    elseif on_unavailable then
      on_unavailable()
    end
  end)
end

-- Kick a silent background refresh when the cache is stale or absent and no sync is running,
-- so the unified picker reads caches synchronously and stays instant.
function M.refresh_if_stale(name, ttl)
  if cache.is_stale(M.read_cache(name), os.time(), ttl) and not in_flight[name] then
    M.sync(name, { silent = true })
  end
end

-- Read every configured source's cached items (offline), each refreshed in the background
-- when stale; returns { { name, source, items }, ... } for the unified picker.
function M.read_specs()
  local sources_cfg = config.get().sources or {}
  local specs = {}
  for _, name in ipairs(registry.names()) do
    local ttl = sources_cfg[name] and sources_cfg[name].ttl or config.SOURCE_DEFAULT_TTL
    M.refresh_if_stale(name, ttl)
    specs[#specs + 1] = {
      name = name,
      source = registry.get(name),
      items = M.read_items(name),
    }
  end
  return specs
end

return M
