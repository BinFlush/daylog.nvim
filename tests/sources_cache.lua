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
end
