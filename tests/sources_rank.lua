return function(t)
  local rank = require("daylog.sources.rank")

  local function ids(items)
    local out = {}
    for i, item in ipairs(items) do
      out[i] = item.id
    end
    return out
  end

  t.test("build_usage counts entries across days and tracks the latest date", function()
    local usage = rank.build_usage({
      {
        date = 200,
        lines = { "--- log ---", "08:00 review", "09:00 1234 Fix login", "10:00 done" },
      },
      {
        date = 100,
        lines = { "--- log ---", "08:00 review", "08:30 1234 Fix login", "09:00 done" },
      },
    })

    t.eq(usage["review"], { count = 2, latest = 200 })
    t.eq(usage["1234 Fix login"], { count = 2, latest = 200 })
    t.eq(usage["done"], { count = 2, latest = 200 })
  end)

  t.test("build_usage keys on the activity text with trailing metadata peeled", function()
    local usage = rank.build_usage({
      {
        date = 50,
        lines = { "--- log #ProjectX ---", "08:00 review #ProjectX @office", "09:00 done" },
      },
    })

    t.eq(usage["review"], { count = 1, latest = 50 })
    t.eq(usage["review #ProjectX @office"], nil)
  end)

  t.test("build_usage on a prose-only or empty day yields nothing", function()
    local usage = rank.build_usage({
      { date = 1, lines = { "Holiday -- no work" } },
      { date = 2, lines = {} },
    })

    t.eq(next(usage), nil)
  end)

  t.test("order leads with the most recently logged item", function()
    local items =
      { { id = "a", title = "A" }, { id = "b", title = "B" }, { id = "c", title = "C" } }

    local out = rank.order(items, {
      usage = { B = { count = 1, latest = 100 }, C = { count = 5, latest = 200 } },
      key_of = function(item)
        return item.title
      end,
    })

    -- C (latest 200) then B (latest 100) then A (never logged).
    t.eq(ids(out), { "c", "b", "a" })
  end)

  t.test("order breaks recency ties by worklog count", function()
    local items = { { id = "few", title = "Few" }, { id = "many", title = "Many" } }

    local out = rank.order(items, {
      usage = { Few = { count = 1, latest = 100 }, Many = { count = 9, latest = 100 } },
      key_of = function(item)
        return item.title
      end,
    })

    t.eq(ids(out), { "many", "few" })
  end)

  t.test("with no worklog signal, active leads done and newer-updated leads", function()
    local items = {
      { id = "done", active = false, updated = "2026-06-01" },
      { id = "open_old", active = true, updated = "2026-01-01" },
      { id = "open_new", active = true, updated = "2026-06-01" },
    }

    local out = rank.order(items, {
      usage = {},
      key_of = function()
        return nil
      end,
    })

    t.eq(ids(out), { "open_new", "open_old", "done" })
  end)

  t.test("items that tie on every signal keep their input order (stable)", function()
    local items = { { id = "x" }, { id = "y" }, { id = "z" } }

    local out = rank.order(items, {
      usage = {},
      key_of = function()
        return nil
      end,
    })

    t.eq(ids(out), { "x", "y", "z" })
  end)
end
