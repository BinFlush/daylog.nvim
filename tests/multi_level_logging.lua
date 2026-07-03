-- Multi-tier logging: the four level markers (!S summary, !T tag, !L location, !W workday) parse --
-- compact (!S60T120L90W480) or separated (!S60 !T120 ...) -- round-trip to the compact form, and each
-- acts on its own report section. Plus the one-time v0.1.x !L->!S migration.
return function(t)
  local document = require("daylog.document")
  local analyze = require("daylog.analyze")
  local entry = require("daylog.entry")
  local syntax = require("daylog.syntax")
  local summary = require("daylog.summary")
  local render = require("daylog.render")
  local migrate = require("daylog.usecases.migrate_logging")
  local refresh_summaries = require("daylog.usecases.refresh_summaries")
  local support = require("daylog.usecases.support")

  local function first_entry(lines)
    return analyze.get_active_log(analyze.analyze(document.parse(lines))).entries[1]
  end
  local function diagnostics(lines)
    return #analyze.analyze(document.parse(lines)).diagnostics
  end
  local function has(lines, needle)
    for _, line in ipairs(lines) do
      if line:find(needle, 1, true) then
        return true
      end
    end
    return false
  end

  t.test("every level parses into the one logged table, keyed by level", function()
    local e = first_entry({ "--- log ---", "08:00 fix #c @o !S60 !T120 !L90 !W480", "09:00 done" })
    t.eq(e.logged, { s = 60, t = 120, l = 90, w = 480 })
  end)

  t.test(
    "a bare marker stores true; the writer emits one compact token in S/T/L/W order",
    function()
      local e = first_entry({ "--- log ---", "08:00 task !W !L !T", "09:00 done" })
      t.eq(e.logged, { t = true, l = true, w = true })
      t.eq(entry.format(e, nil, nil, nil), "08:00 task !TLW")
    end
  )

  t.test("frozen values round-trip on every level, in one compact token", function()
    -- The separated form parses; the writer emits it compact.
    local e = first_entry({ "--- log ---", "08:00 x !S60 !T120 !L90 !W480", "09:00 done" })
    t.eq(entry.format(e, nil, nil, nil), "08:00 x !S60T120L90W480")
  end)

  t.test("parse_logged_token returns level+value pairs, or nil for a non-marker", function()
    t.eq(syntax.parse_logged_token("!T30"), { { level = "t", minutes = 30 } })
    t.eq(syntax.parse_logged_token("!L"), { { level = "l" } }) -- bare: minutes absent
    t.eq(syntax.parse_logged_token("!S225T525W525"), {
      { level = "s", minutes = 225 },
      { level = "t", minutes = 525 },
      { level = "w", minutes = 525 },
    })
    t.eq(syntax.parse_logged_token("!X"), nil)
    t.eq(syntax.parse_logged_token("!Slamas"), nil) -- lowercase after the level is not a marker
    t.eq(syntax.parse_logged_token("!5"), nil) -- a value with no preceding level is not a marker
    t.eq(syntax.parse_logged_token("!S1234567890"), nil) -- an overlong value (would overflow) is not a marker
  end)

  t.test("the compact and separated forms parse identically, and write back compact", function()
    local compact = first_entry({ "--- log ---", "08:00 x !S225T525W525", "09:00 done" })
    local separated = first_entry({ "--- log ---", "08:00 x !S225 !T525 !W525", "09:00 done" })
    t.eq(compact.logged, { s = 225, t = 525, w = 525 })
    t.eq(separated.logged, compact.logged)
    t.eq(entry.format(compact, nil, nil, nil), "08:00 x !S225T525W525")
    t.eq(entry.format(separated, nil, nil, nil), "08:00 x !S225T525W525")
  end)

  t.test("two markers of the same level are the error; different levels are fine", function()
    t.eq(diagnostics({ "--- log ---", "08:00 t !T !T", "09:00 done" }), 1)
    t.eq(diagnostics({ "--- log ---", "08:00 t !TT", "09:00 done" }), 1) -- a compact repeat too
    t.eq(diagnostics({ "--- log ---", "08:00 t !S !T !L !W", "09:00 done" }), 0)
  end)

  t.test(":Daylog migrate rewrites the old summary !L to !S, leaving other markers", function()
    local old = {
      "--- log ---",
      "08:00 a @office !L60",
      "09:00 b !L",
      "10:00 c !L45 !T30",
      "10:30 done",
    }
    local out = support.apply_edits(old, migrate.run(old).edits)
    t.eq(out[2], "08:00 a @office !S60") -- frozen value preserved
    t.eq(out[3], "09:00 b !S") -- bare marker preserved
    t.eq(out[4], "10:00 c !S45T30") -- only !L moves; a co-located !T is left alone (emitted compact)
  end)

  t.test("a frozen-zero marker (`!S0`) round-trips and stays frozen", function()
    local e = first_entry({ "--- log ---", "08:00 x !S0 !T0", "09:00 done" })
    t.eq(e.logged, { s = 0, t = 0 })
    t.eq(entry.format(e, nil, nil, nil), "08:00 x !S0T0")
  end)

  t.test("leading zeros in a frozen value normalize (`!S007` -> `!S7`)", function()
    local e = first_entry({ "--- log ---", "08:00 x !S007", "09:00 done" })
    t.eq(e.logged, { s = 7 })
    t.eq(entry.format(e, nil, nil, nil), "08:00 x !S7")
  end)

  t.test("markers are case-sensitive; lowercase letters are plain text", function()
    t.eq(syntax.parse_logged_token("!s"), nil)
    t.eq(syntax.parse_logged_token("!l60"), nil)
    -- `!s` never parses, so it stays in the activity text rather than becoming metadata.
    t.eq(first_entry({ "--- log ---", "08:00 ship it !s", "09:00 done" }).text, "ship it !s")
  end)

  t.test("sanitize_text neutralizes every level marker so a title cannot inject one", function()
    for _, marker in ipairs({ "!S", "!T", "!L", "!W", "!S45" }) do
      t.eq(entry.sanitize_text("title " .. marker), "title (" .. marker .. ")")
    end
  end)

  t.test("an entry logged only at a non-summary level has no summary state", function()
    local e = first_entry({ "--- log ---", "08:00 task !T", "09:00 done" })
    t.eq(e.logged, { t = true })
    t.eq(e.logged.s, nil)
    t.eq(entry.format(e, nil, nil, nil), "08:00 task !T")
  end)

  t.test(":Daylog migrate is idempotent -- a second run finds nothing to change", function()
    local old = { "--- log ---", "08:00 a !L60", "09:00 done" }
    local once = support.apply_edits(old, migrate.run(old).edits)
    t.eq(once[2], "08:00 a !S60")
    t.eq(#migrate.run(once).edits, 0) -- already !S: no location marker remains to migrate
  end)

  t.test(":Daylog migrate rewrites every log block in the buffer", function()
    local old = {
      "--- log ---",
      "08:00 a !L30",
      "09:00 done",
      "",
      "--- log ---",
      "10:00 b !L",
      "11:00 done",
    }
    local out = support.apply_edits(old, migrate.run(old).edits)
    t.eq(out[2], "08:00 a !S30")
    t.eq(out[6], "10:00 b !S")
  end)

  t.test(":Daylog migrate never clobbers a genuine !S value", function()
    -- A hand-mixed / re-run file with both markers: the summary value wins, the location is dropped
    -- only if it were migrated -- but the guard skips the entry entirely, leaving it untouched.
    local mixed = { "--- log ---", "08:00 a !S60 !L30", "09:00 done" }
    t.eq(#migrate.run(mixed).edits, 0)
  end)

  t.test("migrate then refresh rebuilds the summary with the recovered !S logging", function()
    local old = { "--- log q=15 d=dec ---", "08:00 a !L120", "10:00 done" }
    local migrated = support.apply_edits(old, migrate.run(old).edits)
    local refreshed = support.apply_edits(migrated, refresh_summaries.run(migrated).edits)
    t.ok(has(refreshed, "08:00 a !S120"), "the entry is migrated to a frozen !S")
    t.ok(has(refreshed, "2.00h (+0m) a !S"), "the rebuilt summary marks the row logged")
  end)

  t.test("a fully multi-level log renders each section split by its own level", function()
    local block = analyze.get_active_log(analyze.analyze(document.parse({
      "--- log q=15 ---",
      "08:00 build #Client @office !S120 !T120",
      "10:00 build #Client @office",
      "10:30",
      "11:00 email #Internal @home !L30",
      "11:30 done",
    })))

    t.eq(
      render.summary_lines(summary.summarize_block(block), block.duration_format, {
        leading_blank = false,
        quantize_minutes = 15,
      }),
      {
        "--- summary q=15 d=dec ---",
        "2.00h (+0m) build !S", -- summary level: the !S slice held at 120
        "0.50h (+0m) build",
        "0.50h (+0m) email",
        "",
        "--- tags ---",
        "2.00h (+0m) #Client !T", -- tag level: the !T slice, independent of !S
        "0.50h (+0m) #Client",
        "0.50h (+0m) #Internal",
        "",
        "--- locations ---",
        "2.50h (+0m) @office", -- the blank interval is uncounted, so @office loses that slice
        "0.50h (+0m) @home !L", -- location level: the !L slice
        "",
        "--- totals ---",
        "3.00h (+0m) workday", -- the blank interval is excluded from every total
      }
    )
  end)

  t.test("refresh reclaims a stale --- logged --- section left by an older version", function()
    local old = {
      "--- log @office ---",
      "08:00 work !S60",
      "09:00 more",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) work !S",
      "1.00h (+0m) more",
      "",
      "--- logged ---",
      "1.00h (+0m) logged",
      "1.00h (+0m) unlogged",
      "",
      "--- totals ---",
      "2.00h (+0m) workday",
    }
    local out = support.apply_edits(old, refresh_summaries.run(old).edits)
    t.ok(not has(out, "logged ---"), "the stale --- logged --- section is removed")
    t.ok(has(out, "1.00h (+0m) work !S"), "the summary is rebuilt with the main !S split")
  end)

  t.test("a balance nudge on an activity flows into its tag and location totals", function()
    local function summ(lines)
      return summary.summarize_block(analyze.get_active_log(analyze.analyze(document.parse(lines))))
    end

    -- q=30: 'a' is 40 min (floors to 30). Without a nudge every section foots to 60.
    local base =
      summ({ "--- log q=30 ---", "08:00 a #X @office", "08:40 b #Y @office", "09:00 done" })
    t.eq(base.tag_total, 60)
    t.eq(base.location_total, 60)

    -- round+1 lifts 'a' one bucket; its tag (#X) and location (@office) inherit the shift and stay
    -- footed with the balanced activity total.
    local nudged =
      summ({ "--- log q=30 ---", "08:00 a #X @office round+1", "08:40 b #Y @office", "09:00 done" })
    t.eq(nudged.activity_total, 90)
    t.eq(nudged.tag_total, 90)
    t.eq(nudged.location_total, 90)

    -- The !T30 commitment splits the #X tag row for display (a logged 30 slice plus its unlogged
    -- remainder), but every section is a projection of the one shared quantization, so the tag total
    -- still foots to the balanced activity total (90), as does the unfrozen location.
    local frozen = summ({
      "--- log q=30 ---",
      "08:00 a #X @office round+1 !T30",
      "08:40 b #Y @office",
      "09:00 done",
    })
    t.eq(frozen.tag_total, 90)
    t.eq(frozen.location_total, 90)
  end)
end
