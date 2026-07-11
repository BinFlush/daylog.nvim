return function(t)
  local cache = require("daylog.sources.cache")

  t.test("cache encode/decode round-trips items", function()
    local items = { { id = "1", title = "A" }, { id = "2", title = "B" } }
    local envelope = cache.encode(items, 1000)
    t.eq(envelope.version, cache.VERSION)
    t.eq(envelope.fetched_at, 1000)

    local decoded = cache.decode(vim.json.encode(envelope), vim.json.decode)
    t.eq(decoded.fetched_at, 1000)
    t.eq(decoded.items, items)
  end)

  t.test("cache decode rejects garbage and unsupported versions", function()
    t.eq(cache.decode("not json", vim.json.decode), nil)

    local wrong = vim.json.encode({ version = 999, fetched_at = 0, items = {} })
    local decoded, err = cache.decode(wrong, vim.json.decode)
    t.eq(decoded, nil)
    t.ok(err:match("version") ~= nil)
  end)

  t.test("cache is_stale uses the ttl window", function()
    t.eq(cache.is_stale(nil, 100, 60), true)
    t.eq(cache.is_stale({ fetched_at = 100 }, 130, 60), false)
    t.eq(cache.is_stale({ fetched_at = 100 }, 160, 60), true)
  end)

  t.test("cache decode drops structurally-corrupt items instead of crashing later", function()
    -- Valid JSON + envelope, but the items aren't all tables with an id (hand-edited / on-disk
    -- corruption). The bad elements are dropped so the picker can't crash at to_entry_text.
    local envelope = vim.json.encode({
      version = cache.VERSION,
      fetched_at = 1000,
      items = { { id = "1", title = "A" }, 42, { title = "no id" }, { id = "2", title = "B" } },
    })
    local decoded = cache.decode(envelope, vim.json.decode)
    t.eq(decoded.items, { { id = "1", title = "A" }, { id = "2", title = "B" } })
  end)

  t.test("cache is_stale treats a future fetched_at as stale, not forever-fresh", function()
    t.eq(cache.is_stale({ fetched_at = 500 }, 100, 60), true)
  end)
end
