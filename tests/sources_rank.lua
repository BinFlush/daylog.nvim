return function(t)
  local rank = require("daylog.sources.rank")

  local function ids(items)
    local out = {}
    for i, item in ipairs(items) do
      out[i] = item.id
    end
    return out
  end

  local DAY = 86400
  -- Well past the last recency bucket (90 days) so a visit can be placed in any bucket.
  local NOW = 100 * DAY

  t.test("build_usage scores by Mozilla frecency: visit count x recency weight", function()
    local usage = rank.build_usage({
      { date = NOW, lines = { "--- log ---", "08:00 review", "08:30 done" } }, -- age 0 -> 100
      { date = NOW - 3 * DAY, lines = { "--- log ---", "08:00 review", "09:30 done" } }, -- age 3 -> 100
    }, NOW)

    -- "review" visited twice, both in the first (<=4 days) bucket: count 2, sampled 2,
    -- points 200 -> ceil(2 * 200 / 2) = 200.
    t.eq(usage["review"].count, 2)
    t.eq(usage["review"].latest, NOW)
    t.eq(usage["review"].score, 200)
  end)

  t.test("build_usage weights a more recent visit above an older one", function()
    local usage = rank.build_usage({
      { date = NOW - 2 * DAY, lines = { "--- log ---", "08:00 fresh", "08:30 done" } }, -- age 2 -> 100
      { date = NOW - 20 * DAY, lines = { "--- log ---", "08:00 stale", "08:30 done" } }, -- age 20 -> 50
    }, NOW)

    t.eq(usage["fresh"].score, 100)
    t.eq(usage["stale"].score, 50)
  end)

  t.test("build_usage scales the score by how often an activity is logged", function()
    local days = {}
    for i = 1, 3 do
      days[i] = { date = NOW - i * DAY, lines = { "--- log ---", "08:00 standup", "08:15 done" } }
    end
    local usage = rank.build_usage(days, NOW)

    -- 3 visits, all in the first bucket (ages 1/2/3 -> 100): ceil(3 * 300 / 3) = 300.
    t.eq(usage["standup"].count, 3)
    t.eq(usage["standup"].score, 300)
  end)

  t.test("build_usage ignores duration -- only recency and count matter", function()
    local usage = rank.build_usage({
      { date = NOW, lines = { "--- log ---", "08:00 short", "08:05 long", "12:00 done" } },
    }, NOW)

    -- "short" tracks 5 minutes and "long" 235, but each is one visit today -> equal scores,
    -- and the usage map no longer carries a duration field at all.
    t.eq(usage["short"].score, usage["long"].score)
    t.eq(usage["short"].time, nil)
  end)

  t.test("build_usage samples only the most recent visits but scales by the full count", function()
    local days = {}
    for i = 1, 10 do
      days[i] = { date = NOW, lines = { "--- log ---", "08:00 daily", "08:15 done" } } -- age 0 -> 100
    end
    for i = 1, 5 do
      days[10 + i] =
        { date = NOW - 200 * DAY, lines = { "--- log ---", "08:00 daily", "08:15 done" } } -- age 200 -> 10
    end
    local usage = rank.build_usage(days, NOW)

    -- 15 visits; only the 10 most recent (weight 100) are sampled, so the 5 stale ones drop out
    -- of the average yet still scale the count: ceil(15 * (10 * 100) / 10) = 1500.
    t.eq(usage["daily"].count, 15)
    t.eq(usage["daily"].score, 1500)
  end)

  t.test("build_usage counts the in-progress last entry as a visit", function()
    local usage = rank.build_usage({
      { date = NOW, lines = { "--- log ---", "08:00 review" } },
    }, NOW)

    t.eq(usage["review"].count, 1)
    t.eq(usage["review"].score, 100)
  end)

  t.test("build_usage keys on the activity text with trailing metadata peeled", function()
    local usage = rank.build_usage({
      {
        date = NOW,
        lines = { "--- log #ProjectX ---", "08:00 review #ProjectX @office", "09:00 done" },
      },
    }, NOW)

    t.ok(usage["review"] ~= nil)
    t.eq(usage["review #ProjectX @office"], nil)
  end)

  t.test("build_usage keys a mapped entry on its alias, not its description", function()
    -- A mapped entry reports under its `=> alias`, and so does a source item's key, so the
    -- visit must credit the alias. Otherwise a mapped log neither boosts the item it maps to
    -- nor counts as the same activity a bare entry would -- bare and mapped are equivalent.
    local usage = rank.build_usage({
      {
        date = NOW,
        lines = { "--- log ---", "08:00 fix login => 1234 Title", "09:00 done" },
      },
    }, NOW)

    t.ok(usage["1234 Title"] ~= nil)
    t.eq(usage["fix login"], nil)
  end)

  t.test("build_usage on a prose-only or empty day yields nothing", function()
    local usage = rank.build_usage({
      { date = NOW, lines = { "Holiday -- no work" } },
      { date = NOW, lines = {} },
    }, NOW)

    t.eq(next(usage), nil)
  end)

  t.test("build_name_usage buckets each marker's names by its level, independently", function()
    local usage = rank.build_name_usage({
      { date = NOW, lines = { "--- log ---", "08:00 hi !T[boss]60L[home]60", "09:00 done" } },
    }, NOW)

    t.ok(usage.t["boss"] ~= nil)
    t.ok(usage.l["home"] ~= nil)
    -- The levels never leak into each other, and the unused levels stay empty.
    t.eq(usage.t["home"], nil)
    t.eq(usage.l["boss"], nil)
    t.eq(next(usage.s), nil)
    t.eq(next(usage.w), nil)
  end)

  t.test("build_name_usage scores a name like an activity would across the same days", function()
    local name_days, act_days = {}, {}
    for i = 1, 3 do
      name_days[i] =
        { date = NOW - i * DAY, lines = { "--- log ---", "08:00 hi !T[boss]60", "09:00 done" } }
      act_days[i] = { date = NOW - i * DAY, lines = { "--- log ---", "08:00 boss", "09:00 done" } }
    end

    local nu = rank.build_name_usage(name_days, NOW)
    local au = rank.build_usage(act_days, NOW)

    -- 3 visits, ages 1/2/3 all in the first bucket: count 3, ceil(3 * 300 / 3) = 300 -- exactly the
    -- frecency the same-cadence activity earns.
    t.eq(nu.t["boss"].count, 3)
    t.eq(nu.t["boss"].latest, NOW - DAY)
    t.eq(nu.t["boss"].score, au["boss"].score)
    t.eq(nu.t["boss"].score, 300)
  end)

  t.test("build_name_usage dates each visit by its day, bucketed per level", function()
    local usage = rank.build_name_usage({
      { date = NOW - 20 * DAY, lines = { "--- log ---", "08:00 hi !S[proj]60", "09:00 done" } },
      {
        date = NOW,
        lines = { "--- log ---", "08:00 hi !S[proj]60", "09:00 hey !W[proj]60", "10:00 done" },
      },
    }, NOW)

    -- proj at the summary level: two visits (ages 20 -> 50 and 0 -> 100): ceil(2 * 150 / 2) = 150.
    t.eq(usage.s["proj"].count, 2)
    t.eq(usage.s["proj"].latest, NOW)
    t.eq(usage.s["proj"].score, 150)
    -- proj at the workday level is one visit today, tracked in its own bucket.
    t.eq(usage.w["proj"].count, 1)
    t.eq(usage.w["proj"].score, 100)
  end)

  t.test("build_name_usage ignores entries whose markers carry no names", function()
    local usage = rank.build_name_usage({
      { date = NOW, lines = { "--- log ---", "08:00 hi !T[]60", "09:00 plain", "10:00 done" } },
    }, NOW)

    t.eq(next(usage.s), nil)
    t.eq(next(usage.t), nil)
    t.eq(next(usage.l), nil)
    t.eq(next(usage.w), nil)
  end)

  t.test("order leads with the higher frecency score", function()
    local items = { { id = "a", title = "A" }, { id = "b", title = "B" } }

    local out = rank.order(items, {
      usage = { A = { score = 40 }, B = { score = 230 } },
      key_of = function(item)
        return item.title
      end,
    })

    t.eq(ids(out), { "b", "a" })
  end)

  t.test("order puts a logged item above an unlogged but active/recent one", function()
    local items = {
      { id = "fresh", active = true, updated = "2026-12-01" },
      { id = "logged", title = "X" },
    }

    local out = rank.order(items, {
      usage = { X = { score = 35 } },
      key_of = function(item)
        return item.title
      end,
    })

    -- logged = 35 > fresh = 0, despite fresh being active and newer.
    t.eq(ids(out), { "logged", "fresh" })
  end)

  t.test("with no daylog signal, active leads done and newer-updated leads", function()
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

  t.test("a non-string `updated` from a custom source ranks as missing, never crashes", function()
    -- Sources are arbitrary tables; a decoded JSON null (truthy sentinel) or a number
    -- must not reach the string comparator.
    local items = {
      { id = "weird", updated = {} },
      { id = "num", updated = 20260101 },
      { id = "real", updated = "2026-06-01" },
    }

    local out = rank.order(items, {
      usage = {},
      key_of = function()
        return nil
      end,
    })

    t.eq(ids(out), { "real", "weird", "num" })
  end)

  t.test("build_insert_pool merges, dedups, and ranks items and activities", function()
    local sources = {
      {
        name = "FAKE",
        items = { { id = "1", title = "One" }, { id = "2", title = "Two" } },
        key_of = function(item)
          return item.id .. " " .. item.title
        end,
        display_for = function(item)
          return "#" .. item.id .. " " .. item.title
        end,
        text_of = function(item)
          return item.id .. " " .. item.title
        end,
      },
    }
    local usage = {
      ["1 One"] = { score = 250 }, -- also a tracker item -> folds into the item row
      ["standup"] = { score = 90 }, -- a logged activity with no matching item
    }

    local rows = rank.build_insert_pool(sources, { usage = usage })

    -- One (item, 250) > standup (activity, 90) > Two (item, 0); "1 One" appears once.
    t.eq(#rows, 3)
    t.eq({ rows[1].kind, rows[1].key, rows[1].text }, { "item", "1 One", "1 One" })
    t.eq(rows[1].display, "#1 One")
    t.eq({ rows[2].kind, rows[2].text }, { "activity", "standup" })
    t.eq({ rows[3].kind, rows[3].key, rows[3].text }, { "item", "2 Two", "2 Two" })
  end)

  t.test("build_insert_pool keeps the first source on a cross-source key clash", function()
    local function src(name)
      return {
        name = name,
        items = { { id = "X" } },
        key_of = function(item)
          return item.id
        end,
        display_for = function(item)
          return name .. ":" .. item.id
        end,
        text_of = function(item)
          return item.id
        end,
      }
    end

    local rows = rank.build_insert_pool({ src("A"), src("B") }, { usage = {} })

    t.eq(#rows, 1)
    t.eq(rows[1].source, "A")
  end)

  t.test("build_insert_pool orders tied activities deterministically by key", function()
    -- Activities come out of a hash map; on a full score tie they must sort by key,
    -- not by whatever order pairs() happened to walk the table in.
    local usage = {}
    for _, key in ipairs({ "zeta", "mike", "alpha", "tango", "echo", "quebec" }) do
      usage[key] = { score = 50 }
    end

    local rows = rank.build_insert_pool({}, { usage = usage })

    local keys = {}
    for i, row in ipairs(rows) do
      keys[i] = row.key
    end
    t.eq(keys, { "alpha", "echo", "mike", "quebec", "tango", "zeta" })
  end)

  t.test("build_insert_pool puts an item before an activity on a score tie", function()
    local sources = {
      {
        name = "S",
        items = { { id = "i" } },
        key_of = function(item)
          return item.id
        end,
        display_for = function(item)
          return item.id
        end,
        text_of = function(item)
          return item.id
        end,
      },
    }
    -- "a" scores 0, same as the never-logged item -> the item leads.
    local rows = rank.build_insert_pool(sources, { usage = { a = { score = 0 } } })

    t.eq(#rows, 2)
    t.eq(rows[1].kind, "item")
    t.eq(rows[2].kind, "activity")
  end)
end
