return function(t)
  local rank = require("daylog.sources.rank")

  local function ids(items)
    local out = {}
    for i, item in ipairs(items) do
      out[i] = item.id
    end
    return out
  end

  -- A date of 0 is one half-life (7 days) before `now`, so its weight is exactly 0.5.
  local NOW = 7 * 86400

  t.test("build_usage decays frequency and duration by recency", function()
    local usage = rank.build_usage({
      { date = NOW, lines = { "--- log ---", "08:00 review", "08:30 done" } }, -- w=1, 30 min
      { date = 0, lines = { "--- log ---", "08:00 review", "09:30 done" } }, -- w=0.5, 90 min
    }, NOW, 7)

    -- freq = 1 + 0.5 ; time = 1*30 + 0.5*90
    t.eq(usage["review"].freq, 1.5)
    t.eq(usage["review"].time, 75)
    t.eq(usage["review"].count, 2)
    t.eq(usage["review"].latest, NOW)
  end)

  t.test("build_usage measures duration in effective UTC across an offset change", function()
    local usage = rank.build_usage({
      { date = 0, lines = { "--- log ---", "08:00 review utc+2", "10:00 done utc+0" } },
    }, 0, 7)

    -- (10:00 - utc0) - (08:00 - utc+2) = 600 - 360 = 240 effective minutes, not the raw 120.
    t.eq(usage["review"].time, 240)
  end)

  t.test("build_usage counts the in-progress last entry but gives it no time", function()
    local usage = rank.build_usage({
      { date = 0, lines = { "--- log ---", "08:00 review" } },
    }, 0, 7)

    t.eq(usage["review"].freq, 1)
    t.eq(usage["review"].time, 0)
    t.eq(usage["review"].count, 1)
  end)

  t.test("build_usage keys on the activity text with trailing metadata peeled", function()
    local usage = rank.build_usage({
      {
        date = 0,
        lines = { "--- log #ProjectX ---", "08:00 review #ProjectX @office", "09:00 done" },
      },
    }, 0, 7)

    t.ok(usage["review"] ~= nil)
    t.eq(usage["review #ProjectX @office"], nil)
  end)

  t.test("build_usage on a prose-only or empty day yields nothing", function()
    local usage = rank.build_usage({
      { date = 1, lines = { "Holiday -- no work" } },
      { date = 2, lines = {} },
    }, 2, 7)

    t.eq(next(usage), nil)
  end)

  t.test("order leads with the higher worklog score (time outweighs a bare count)", function()
    local items = { { id = "a", title = "A" }, { id = "b", title = "B" } }

    local out = rank.order(items, {
      usage = { A = { freq = 1, time = 10 }, B = { freq = 1, time = 200 } },
      key_of = function(item)
        return item.title
      end,
      base = 30,
    })

    -- A = 30*1 + 10 = 40 ; B = 30*1 + 200 = 230.
    t.eq(ids(out), { "b", "a" })
  end)

  t.test("order rewards frequency through base", function()
    local items = { { id = "rare", title = "Rare" }, { id = "often", title = "Often" } }

    local out = rank.order(items, {
      usage = { Rare = { freq = 1, time = 0 }, Often = { freq = 5, time = 0 } },
      key_of = function(item)
        return item.title
      end,
      base = 30,
    })

    -- Rare = 30 ; Often = 150.
    t.eq(ids(out), { "often", "rare" })
  end)

  t.test("order puts a logged item above an unlogged but active/recent one", function()
    local items = {
      { id = "fresh", active = true, updated = "2026-12-01" },
      { id = "logged", title = "X" },
    }

    local out = rank.order(items, {
      usage = { X = { freq = 1, time = 5 } },
      key_of = function(item)
        return item.title
      end,
      base = 30,
    })

    -- logged = 35 > fresh = 0, despite fresh being active and newer.
    t.eq(ids(out), { "logged", "fresh" })
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
      base = 30,
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
      base = 30,
    })

    t.eq(ids(out), { "x", "y", "z" })
  end)
end
