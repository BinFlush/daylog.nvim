-- Multi-tier logging: the four level markers (!S[] summary, !T[] tag, !L[] location, !W[] workday) parse --
-- compact (!S[]60T[]120L[]90W[]480) or separated (!S[]60 !T[]120 ...) -- round-trip to the compact form, and each
-- acts on its own report section.
return function(t)
  local document = require("daylog.document")
  local analyze = require("daylog.analyze")
  local entry = require("daylog.entry")
  local syntax = require("daylog.syntax")
  local summary = require("daylog.summary")
  local render = require("daylog.render")
  local refresh_summaries = require("daylog.usecases.refresh_summaries")
  local support = require("daylog.usecases.support")
  local log_current = require("daylog.usecases.log_current")

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
    local e =
      first_entry({ "--- log ---", "08:00 fix #c @o !S[]60 !T[]120 !L[]90 !W[]480", "09:00 done" })
    t.eq(e.logged, {
      s = { minutes = 60, names = { "" } },
      t = { minutes = 120, names = { "" } },
      l = { minutes = 90, names = { "" } },
      w = { minutes = 480, names = { "" } },
    })
  end)

  t.test(
    "a valueless marker stores its names; the writer emits one compact token in S/T/L/W order",
    function()
      local e = first_entry({ "--- log ---", "08:00 task !W[]60 !L[]60 !T[]60", "09:00 done" })
      t.eq(e.logged, {
        t = { minutes = 60, names = { "" } },
        l = { minutes = 60, names = { "" } },
        w = { minutes = 60, names = { "" } },
      })
      t.eq(entry.format(e, nil, nil, nil), "08:00 task !T[]60L[]60W[]60")
    end
  )

  t.test("frozen values round-trip on every level, in one compact token", function()
    -- The separated form parses; the writer emits it compact.
    local e = first_entry({ "--- log ---", "08:00 x !S[]60 !T[]120 !L[]90 !W[]480", "09:00 done" })
    t.eq(entry.format(e, nil, nil, nil), "08:00 x !S[]60T[]120L[]90W[]480")
  end)

  t.test("parse_logged_token returns level+value pairs, or nil for a non-marker", function()
    t.eq(syntax.parse_logged_token("!T[]30"), { { level = "t", minutes = 30, names = { "" } } })
    t.eq(syntax.parse_logged_token("!L[]"), { { level = "l", names = { "" } } }) -- the explicit unnamed name
    t.eq(syntax.parse_logged_token("!S[]225T[]525W[]525"), {
      { level = "s", minutes = 225, names = { "" } },
      { level = "t", minutes = 525, names = { "" } },
      { level = "w", minutes = 525, names = { "" } },
    })
    -- A pair carries its bracketed name list, canonicalized (deduped + sorted).
    t.eq(syntax.parse_logged_token("!S[a]60T[a,b]120"), {
      { level = "s", minutes = 60, names = { "a" } },
      { level = "t", minutes = 120, names = { "a", "b" } },
    })
    t.eq(syntax.parse_logged_token("!X"), nil)
    t.eq(syntax.parse_logged_token("!S[]lamas"), nil) -- lowercase after the level is not a marker
    t.eq(syntax.parse_logged_token("!5"), nil) -- a value with no preceding level is not a marker
    t.eq(syntax.parse_logged_token("!S[]1234567890"), nil) -- an overlong value (would overflow) is not a marker
    -- Brackets are mandatory: a bare level (no `[`) is not a marker, at any level, valued or not, and
    -- a fully-bare compact chain is text as well.
    t.eq(syntax.parse_logged_token("!S"), nil)
    t.eq(syntax.parse_logged_token("!S60"), nil)
    t.eq(syntax.parse_logged_token("!W"), nil)
    t.eq(syntax.parse_logged_token("!S60T120"), nil)
  end)

  t.test("a bare marker is demoted to activity text, not parsed as logged", function()
    local e = first_entry({ "--- log ---", "08:00 fix login !S", "09:00 done" })
    t.eq(e.logged, nil)
    t.eq(entry.format(e, nil, nil, nil), "08:00 fix login !S")
  end)

  t.test("the compact and separated forms parse identically, and write back compact", function()
    local compact = first_entry({ "--- log ---", "08:00 x !S[]225T[]525W[]525", "09:00 done" })
    local separated =
      first_entry({ "--- log ---", "08:00 x !S[]225 !T[]525 !W[]525", "09:00 done" })
    t.eq(compact.logged, {
      s = { minutes = 225, names = { "" } },
      t = { minutes = 525, names = { "" } },
      w = { minutes = 525, names = { "" } },
    })
    t.eq(separated.logged, compact.logged)
    t.eq(entry.format(compact, nil, nil, nil), "08:00 x !S[]225T[]525W[]525")
    t.eq(entry.format(separated, nil, nil, nil), "08:00 x !S[]225T[]525W[]525")
  end)

  t.test("two markers of the same level are the error; different levels are fine", function()
    t.eq(diagnostics({ "--- log ---", "08:00 t !T[]60 !T[]60", "09:00 done" }), 1)
    t.eq(diagnostics({ "--- log ---", "08:00 t !T[]60T[]60", "09:00 done" }), 1) -- a compact repeat too
    t.eq(diagnostics({ "--- log ---", "08:00 t !S[]60 !T[]60 !L[]60 !W[]60", "09:00 done" }), 0)
  end)

  t.test("a frozen-zero marker (`!S[]0`) round-trips and stays frozen", function()
    local e = first_entry({ "--- log ---", "08:00 x !S[]0 !T[]0", "09:00 done" })
    t.eq(e.logged, { s = { minutes = 0, names = { "" } }, t = { minutes = 0, names = { "" } } })
    t.eq(entry.format(e, nil, nil, nil), "08:00 x !S[]0T[]0")
  end)

  t.test("leading zeros in a frozen value normalize (`!S[]007` -> `!S[]7`)", function()
    local e = first_entry({ "--- log ---", "08:00 x !S[]007", "09:00 done" })
    t.eq(e.logged, { s = { minutes = 7, names = { "" } } })
    t.eq(entry.format(e, nil, nil, nil), "08:00 x !S[]7")
  end)

  t.test("markers are case-sensitive; lowercase letters are plain text", function()
    t.eq(syntax.parse_logged_token("!s"), nil)
    t.eq(syntax.parse_logged_token("!l60"), nil)
    -- `!s` never parses, so it stays in the activity text rather than becoming metadata.
    t.eq(first_entry({ "--- log ---", "08:00 ship it !s", "09:00 done" }).text, "ship it !s")
  end)

  t.test("sanitize_text neutralizes every level marker so a title cannot inject one", function()
    for _, marker in ipairs({ "!S[]", "!T[]", "!L[]", "!W[]", "!S[]45" }) do
      t.eq(entry.sanitize_text("title " .. marker), "title (" .. marker .. ")")
    end
  end)

  t.test("named markers parse into { minutes, names } and re-emit compact and canonical", function()
    local e = first_entry({ "--- log ---", "08:00 x !S[a]60 !T[a,b]120", "09:00 done" })
    t.eq(e.logged, {
      s = { minutes = 60, names = { "a" } },
      t = { minutes = 120, names = { "a", "b" } },
    })
    t.eq(entry.format(e, nil, nil, nil), "08:00 x !S[a]60T[a,b]120")
  end)

  t.test("a name list is a set: duplicates drop and names sort", function()
    local e = first_entry({ "--- log ---", "08:00 x !T[b,a,a]60", "09:00 done" })
    t.eq(e.logged, { t = { minutes = 60, names = { "a", "b" } } })
    t.eq(entry.format(e, nil, nil, nil), "08:00 x !T[a,b]60")
  end)

  t.test("names are case-sensitive, so two casings are distinct set members", function()
    local e = first_entry({ "--- log ---", "08:00 x !T[Boss,boss]60", "09:00 done" })
    t.eq(e.logged, { t = { minutes = 60, names = { "Boss", "boss" } } })
    t.eq(entry.format(e, nil, nil, nil), "08:00 x !T[Boss,boss]60")
  end)

  t.test(
    "a name element with an illegal character is not a marker; the token stays literal",
    function()
      for _, bad in ipairs({ "!T[a!]", "!T[a#]", "!T[a/b]" }) do
        t.eq(syntax.parse_logged_token(bad), nil)
        local e = first_entry({ "--- log ---", "08:00 meet " .. bad, "09:00 done" })
        t.eq(e.text, "meet " .. bad)
        t.eq(e.logged, nil)
      end
    end
  )

  t.test("an empty name element is the unnamed name, so `[,hey]` is a first-class set", function()
    t.eq(syntax.parse_logged_token("!T[a,]"), { { level = "t", names = { "", "a" } } })
    t.eq(syntax.parse_logged_token("!T[,b]"), { { level = "t", names = { "", "b" } } })
    t.eq(syntax.parse_logged_token("!T[a,,b]"), { { level = "t", names = { "", "a", "b" } } })
    -- The unnamed name sorts first and round-trips in the compact form.
    local e = first_entry({ "--- log ---", "08:00 x !S[,hey]60", "09:00 done" })
    t.eq(e.logged, { s = { minutes = 60, names = { "", "hey" } } })
    t.eq(entry.format(e, nil, nil, nil), "08:00 x !S[,hey]60")
  end)

  t.test("an explicit empty name-set `!T[]` is an unnamed logged marker", function()
    t.eq(syntax.parse_logged_token("!S[]"), { { level = "s", names = { "" } } }) -- the unnamed name
    t.eq(syntax.parse_logged_token("!T[]60"), { { level = "t", minutes = 60, names = { "" } } })
    local e = first_entry({ "--- log ---", "08:00 x !S[]60 !T[]60", "09:00 done" })
    t.eq(e.logged, { s = { minutes = 60, names = { "" } }, t = { minutes = 60, names = { "" } } })
    t.eq(entry.format(e, nil, nil, nil), "08:00 x !S[]60T[]60") -- round-trips, still explicit
  end)

  t.test("sanitize_text neutralizes a named marker like any trailing marker", function()
    t.eq(entry.sanitize_text("meet !T[boss]60"), "meet (!T[boss]60)")
  end)

  t.test("an entry logged only at a non-summary level has no summary state", function()
    local e = first_entry({ "--- log ---", "08:00 task !T[]60", "09:00 done" })
    t.eq(e.logged, { t = { minutes = 60, names = { "" } } })
    t.eq(e.logged.s, nil)
    t.eq(entry.format(e, nil, nil, nil), "08:00 task !T[]60")
  end)

  t.test("a fully multi-level log renders each section split by its own level", function()
    local block = analyze.get_active_log(analyze.analyze(document.parse({
      "--- log q=15 ---",
      "08:00 build #Client @office !S[]120 !T[]120",
      "10:00 build #Client @office",
      "10:30",
      "11:00 email #Internal @home !L[]30",
      "11:30 done",
    })))

    t.eq(
      render.summary_lines(summary.summarize_block(block), block.duration_format, {
        leading_blank = false,
        quantize_minutes = 15,
      }),
      {
        "--- summary q=15 d=dec ---",
        "2.00h (+0m) build !S[]", -- summary level: the !S[] slice held at 120
        "0.50h (+0m) build",
        "0.50h (+0m) email",
        "",
        "--- tags ---",
        "2.00h (+0m) #Client !T[]", -- tag level: the !T[] slice, independent of !S[]
        "0.50h (+0m) #Client",
        "0.50h (+0m) #Internal",
        "",
        "--- locations ---",
        "2.50h (+0m) @office", -- the blank interval is uncounted, so @office loses that slice
        "0.50h (+0m) @home !L[]", -- location level: the !L[] slice
        "",
        "--- totals ---",
        "3.00h (+0m) workday", -- the blank interval is excluded from every total
      }
    )
  end)

  t.test("named !T[] markers split the tags section, each rendering its own name list", function()
    -- The canonical example: two entries under the sticky #obs tag with different !T[] name-sets. Each
    -- name-set is its own tag row, rendering the marker with its names; the sections still foot.
    local src = {
      "--- log q=15 d=dec ---",
      "08:00 hello #obs !T[name1,name2]60",
      "09:00 hello2 !T[name2]90",
      "10:30",
    }
    local out = support.apply_edits(src, refresh_summaries.run(src).edits)
    t.ok(has(out, "1.00h (+0m) #obs !T[name1,name2]"), "the [name1,name2] slice renders under #obs")
    t.ok(has(out, "1.50h (+0m) #obs !T[name2]"), "the [name2] slice renders under #obs")
  end)

  t.test("refresh reclaims a stale --- logged --- section left by an older version", function()
    local old = {
      "--- log @office ---",
      "08:00 work !S[]60",
      "09:00 more",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) work !S[]",
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
    t.ok(has(out, "1.00h (+0m) work !S[]"), "the summary is rebuilt with the main !S[] split")
  end)

  local function section_total(rows)
    local total = 0
    for _, row in ipairs(rows) do
      total = total + row.duration
    end
    return total
  end

  t.test("a balance nudge on an activity flows into its tag and location totals", function()
    local function summ(lines)
      return summary.summarize_block(analyze.get_active_log(analyze.analyze(document.parse(lines))))
    end

    -- q=30: 'a' is 40 min (floors to 30). Without a nudge every section foots to 60.
    local base =
      summ({ "--- log q=30 ---", "08:00 a #X @office", "08:40 b #Y @office", "09:00 done" })
    t.eq(section_total(base.tag_totals), 60)
    t.eq(section_total(base.location_totals), 60)

    -- round+1 lifts 'a' one bucket; its tag (#X) and location (@office) inherit the shift and stay
    -- footed with the balanced activity total.
    local nudged =
      summ({ "--- log q=30 ---", "08:00 a #X @office round+1", "08:40 b #Y @office", "09:00 done" })
    t.eq(nudged.activity_total, 90)
    t.eq(section_total(nudged.tag_totals), 90)
    t.eq(section_total(nudged.location_totals), 90)

    -- A claim on #Y states what b displays, so it changes no number; the nudge on a still flows into
    -- every section, and all of them foot to the same balanced total (90).
    local frozen = summ({
      "--- log q=30 ---",
      "08:00 a #X @office round+1",
      "08:40 b #Y @office !T[]30",
      "09:00 done",
    })
    t.eq(frozen.activity_total, 90)
    t.eq(section_total(frozen.tag_totals), 90)
    t.eq(section_total(frozen.location_totals), 90)
  end)

  -- The row carrying `needle` (but not `exclude`), or nil; last match wins so a header sharing a
  -- substring never shadows a summary row.
  local function row_of(lines, needle, exclude)
    local row
    for i, line in ipairs(lines) do
      if line:find(needle, 1, true) and not (exclude and line:find(exclude, 1, true)) then
        row = i
      end
    end
    return row
  end

  t.test("run_by_value logs a target by value and skips an absent one", function()
    local src = { "--- log #obs q=15 d=dec ---", "08:00 hello", "09:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)

    local result = log_current.run_by_value(
      rendered,
      { level = "s", value = "hello", tag = "obs" },
      { "boss" }
    )
    t.ok(
      has(support.apply_edits(rendered, result.edits), "08:00 hello !S[boss]60"),
      "the activity is logged by value"
    )

    -- An absent value returns nil, nil so a multi-day fan-out skips that day (never an error).
    local none, err = log_current.run_by_value(
      rendered,
      { level = "s", value = "nope", tag = "obs" },
      { "boss" }
    )
    t.eq(none, nil)
    t.eq(err, nil)
  end)

  t.test("run_unlog_by_value skips a day whose slice is not logged", function()
    local src = { "--- log #obs q=15 d=dec ---", "08:00 hello", "09:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)

    local none, err =
      log_current.run_unlog_by_value(rendered, { level = "s", value = "hello", tag = "obs" }, nil)
    t.eq(none, nil)
    t.eq(err, nil)
  end)

  t.test("run_unlog_by_value removes one name of several across a report fan-out", function()
    -- log.lua drives this when an aggregate report row carries >=2 names and the user unpicks some:
    -- run_unlog_by_value with a non-nil subset must remove only those names and keep the slice logged
    -- (difference_names + dispatch), distinct from the nil clear-all path tested above.
    local src = { "--- log #obs q=15 d=dec ---", "08:00 hello !S[boss,jira]60", "09:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    -- names_key is the slice's canonical NUL-joined name-set, as classify_report_row passes it.
    local target =
      { level = "s", value = "hello", tag = "obs", logged = true, names_key = "boss\0jira" }

    local partial = log_current.run_unlog_by_value(rendered, target, { "boss" })
    t.ok(
      has(support.apply_edits(rendered, partial.edits), "08:00 hello !S[jira]60"),
      "removing 'boss' keeps the marker with 'jira' and preserves the frozen value"
    )

    -- An absent value skips that day (nil, nil), so the multi-day fan-out never aborts.
    local none, err = log_current.run_unlog_by_value(
      rendered,
      { level = "s", value = "nope", tag = "obs" },
      { "boss" }
    )
    t.eq(none, nil)
    t.eq(err, nil)
  end)

  t.test(
    "logging an un-frozen row absorbing frozen slack commits its displayed value, no strand",
    function()
      -- Reported bug: a/b/c are committed 8m below their honest rounding (225/150/75; honest 223/154/81),
      -- so "status" (honest 52) displays 1.00h = 60, absorbing the slack. Logging must freeze 60 -- freezing
      -- its own honest 45 would strand a spurious 0.25h status remainder.
      local base = {
        "--- log q=15 d=dec ---",
        "08:00 a !S[x]225",
        "08:39 a !S[x]225",
        "09:00 a !S[x]225",
        "09:17 a !S[x]225",
        "09:26 b !S[x]150",
        "09:42 b !S[x]150",
        "11:31 b !S[x]150",
        "12:00 a !S[x]225",
        "13:19 a !S[x]225",
        "13:56 a !S[x]225",
        "14:10 a !S[x]225",
        "14:17 c !S[x]75",
        "14:32 c !S[x]75",
        "15:38 status",
        "16:30",
      }
      local rendered = support.apply_edits(base, refresh_summaries.run(base).edits)
      local result = log_current.run_by_value(
        rendered,
        { level = "s", value = "status", names_key = "" },
        { "x" }
      )
      local out = support.apply_edits(rendered, result.edits)

      t.ok(has(out, "15:38 status !S[x]60"), "status frozen at its displayed 60, not 45")

      local status_rows = 0
      for _, l in ipairs(out) do
        if l:match("%) status") then
          status_rows = status_rows + 1
        end
      end
      t.eq(status_rows, 1) -- exactly one logged summary row -- no stranded 0.25h remainder
      t.ok(has(out, "1.00h (-8m) status !S[x]"), "status fully logged at 1.00h")
    end
  )

  t.test(":Daylog log marks a tag row with a chosen name-set, and refresh is idempotent", function()
    local src = { "--- log #obs q=15 d=dec ---", "08:00 hello", "09:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    local result = log_current.run(rendered, row_of(rendered, ") #obs"), { "boss", "jira" })
    local out = support.apply_edits(rendered, result.edits)

    t.ok(has(out, "08:00 hello !T[boss,jira]60"), "the entry gains the named frozen marker")
    t.ok(has(out, ") #obs !T[boss,jira]"), "the tag row renders the named slice")
    -- A second refresh finds nothing to change: the named marking round-trips.
    t.eq(support.apply_edits(out, refresh_summaries.run(out).edits), out)
  end)

  t.test(":Daylog! log unmarks exactly the row's name-set slice", function()
    local src = {
      "--- log #x q=15 d=dec ---",
      "08:00 a !T[a]60",
      "09:00 b !T[b]90",
      "10:30",
    }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    local result = log_current.run_unlog(rendered, row_of(rendered, "#x !T[a]"))
    local out = support.apply_edits(rendered, result.edits)

    t.ok(has(out, "08:00 a"), "the [a] entry survives")
    t.ok(not has(out, "!T[a]"), "the [a] slice's marker is cleared everywhere")
    t.ok(has(out, "09:00 b !T[b]90"), "the [b] slice is untouched")
  end)

  t.test("independent !S[a] and !S[b] freezes on one activity never merge", function()
    local src = {
      "--- log q=15 d=dec ---",
      "08:00 task !S[a]60",
      "09:00 task",
      "10:00 done",
    }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    -- Mark the still-unlogged `task` slice (the row with no !S[]) with a different name-set.
    local result = log_current.run(rendered, row_of(rendered, ") task", "!S[]"), { "b" })
    local out = support.apply_edits(rendered, result.edits)

    t.ok(has(out, "08:00 task !S[a]60"), "the [a] freeze is unchanged")
    t.ok(has(out, "09:00 task !S[b]60"), "the [b] slice freezes on its own, not merged into [a]")
  end)

  t.test(":Daylog log canonicalizes an unsorted, duplicated name-set", function()
    local src = { "--- log #x q=15 d=dec ---", "08:00 hi", "09:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    local result = log_current.run(rendered, row_of(rendered, ") #x"), { "b", "a", "b" })
    local out = support.apply_edits(rendered, result.edits)

    t.ok(has(out, "08:00 hi !T[a,b]60"), "the marker names dedupe and sort")
  end)

  t.test("peek reports mark-vs-unmark, level, and names without editing", function()
    local unlogged = { "--- log #x q=15 d=dec ---", "08:00 hi", "09:00 done" }
    local ru = support.apply_edits(unlogged, refresh_summaries.run(unlogged).edits)
    t.eq(log_current.peek(ru, row_of(ru, ") #x")), { level = "t", marking = true })

    local logged = { "--- log #x q=15 d=dec ---", "08:00 hi !T[boss]60", "09:00 done" }
    local rl = support.apply_edits(logged, refresh_summaries.run(logged).edits)
    t.eq(
      log_current.peek(rl, row_of(rl, "#x !T[boss]")),
      { level = "t", marking = false, names = { "boss" } }
    )

    -- The cursor on an entry line is not a summary row: peek propagates run's NOT_LOGGABLE error.
    local _, err = log_current.peek(ru, 2)
    t.eq(err, "daylog: put the cursor on a summary, tag, location, or workday row to log it")
  end)

  t.test("marking an unnamed tag remainder merges into one recommitted !T[]", function()
    -- The everyday flow: mark a tag, log more time, refresh, mark the remainder row -- the whole
    -- cell recommits at the combined displayed total, one merged row, no value conflict.
    local src = { "--- log #x q=15 d=dec ---", "08:00 a !T[]60", "09:00 b", "10:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    local result = log_current.run(rendered, row_of(rendered, ") #x", "!T[]"))
    local out = support.apply_edits(rendered, result.edits)

    t.ok(has(out, "08:00 a !T[]120"), "the already-logged entry recommits at the combined total")
    t.ok(has(out, "09:00 b !T[]120"), "the swept entry freezes at the same combined total")
    t.ok(has(out, "2.00h (+0m) #x !T[]"), "the tag section shows one merged row")
    t.eq(#refresh_summaries.run(out).warnings, 0)
  end)

  t.test("marking a tag remainder with the logged slice's names merges into it", function()
    local src = { "--- log #x q=15 d=dec ---", "08:00 a !T[a]60", "09:00 b", "10:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    local result = log_current.run(rendered, row_of(rendered, ") #x", "!T[]"), { "a" })
    local out = support.apply_edits(rendered, result.edits)

    t.ok(has(out, "08:00 a !T[a]120"), "the [a] slice recommits at the combined total")
    t.ok(has(out, "09:00 b !T[a]120"), "the remainder joins the [a] slice")
    t.ok(has(out, "2.00h (+0m) #x !T[a]"), "one merged [a] row")
    t.eq(#refresh_summaries.run(out).warnings, 0)
  end)

  t.test("marking a tag remainder with different names leaves the other slice alone", function()
    local src = { "--- log #x q=15 d=dec ---", "08:00 a !T[a]60", "09:00 b", "10:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    local result = log_current.run(rendered, row_of(rendered, ") #x", "!T[]"), { "b" })
    local out = support.apply_edits(rendered, result.edits)

    t.ok(has(out, "08:00 a !T[a]60"), "the [a] freeze is untouched")
    t.ok(has(out, "09:00 b !T[b]60"), "the remainder freezes as its own [b] slice")
    t.ok(has(out, "1.00h (+0m) #x !T[a]"), "the [a] row survives")
    t.ok(has(out, "1.00h (+0m) #x !T[b]"), "the [b] row appears beside it")
    t.eq(#refresh_summaries.run(out).warnings, 0)
  end)

  t.test("marking the workday remainder merges with the same-name !W[] slice", function()
    local src = { "--- log q=15 d=dec ---", "08:00 a !W[n]60", "09:00 b", "10:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    local result = log_current.run(rendered, row_of(rendered, ") workday", "!W[]"), { "n" })
    local out = support.apply_edits(rendered, result.edits)

    t.ok(has(out, "08:00 a !W[n]120"), "the [n] slice recommits at the combined day total")
    t.ok(has(out, "09:00 b !W[n]120"), "the unlogged entry joins the [n] slice")
    t.ok(has(out, "2.00h (+0m) workday !W[n]"), "one merged workday row")
    t.eq(#refresh_summaries.run(out).warnings, 0)
  end)

  t.test("marking a partially-logged activity's remainder merges the !S[] commitment", function()
    -- The s level union-merge (frozen_values): the unlogged remainder of a same-name activity
    -- merges with the logged slice, recommitting every entry at the combined total.
    local src = { "--- log q=15 d=dec ---", "08:00 task !S[]60", "09:00 task", "10:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    local result = log_current.run(rendered, row_of(rendered, ") task", "!S[]"))
    local out = support.apply_edits(rendered, result.edits)

    t.ok(has(out, "08:00 task !S[]120"), "the logged entry recommits at the combined total")
    t.ok(has(out, "09:00 task !S[]120"), "the remainder entry joins the commitment")
    t.ok(has(out, "2.00h (+0m) task !S[]"), "one merged summary row")
    t.eq(#refresh_summaries.run(out).warnings, 0)

    -- The named analog rides the same keying: {"a"} merges into the !S[a] slice.
    local named = { "--- log q=15 d=dec ---", "08:00 task !S[a]60", "09:00 task", "10:00 done" }
    local rn = support.apply_edits(named, refresh_summaries.run(named).edits)
    local merged =
      support.apply_edits(rn, log_current.run(rn, row_of(rn, ") task", "!S[]"), { "a" }).edits)
    t.ok(has(merged, "08:00 task !S[a]120"), "the [a] slice recommits at the combined total")
    t.ok(has(merged, "09:00 task !S[a]120"), "the remainder joins the [a] slice")
  end)

  t.test("adding a name to a logged !S[] slice keeps its existing names and value", function()
    -- Names operate independently: `:Daylog log` ADDS the picked name to the slice, it does not
    -- replace the set. `[ado,boss]` is one slice reported to both, counted once.
    local src = { "--- log q=15 d=dec ---", "08:00 work !S[ado]60", "09:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    local row = row_of(rendered, "work !S[ado]")

    local out = support.apply_edits(rendered, log_current.run(rendered, row, { "boss" }).edits)
    t.ok(has(out, "08:00 work !S[ado,boss]60"), "boss joins ado; the 60m value is preserved")
    t.ok(has(out, "1.00h (+0m) work !S[ado,boss]"), "the summary reports the two-name slice")
    t.eq(#refresh_summaries.run(out).warnings, 0)

    -- Adding a name already present changes nothing, so it is refused with the remedy: re-freezing a
    -- claim at a new value is the deliberate unlog -> refresh -> log.
    local same, err = log_current.run(rendered, row, { "ado" })
    t.eq(same, nil)
    t.ok(err:find("already logged", 1, true) ~= nil, "the hint names the remedy: " .. tostring(err))
  end)

  t.test("adding a name to a tag slice unions onto its marker", function()
    local src = { "--- log #obs q=15 d=dec ---", "08:00 hello !T[team]60", "09:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    local out = support.apply_edits(
      rendered,
      log_current.run(rendered, row_of(rendered, "#obs !T[team]"), { "boss" }).edits
    )
    t.ok(has(out, "1.00h (+0m) #obs !T[boss,team]"), "the tag row reports both names")
    t.eq(#refresh_summaries.run(out).warnings, 0)
  end)

  t.test("run_unlog removes one name of several, keeping the rest", function()
    local src = { "--- log q=15 d=dec ---", "08:00 work !S[ado,boss]60", "09:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)

    local out = support.apply_edits(
      rendered,
      log_current.run_unlog(rendered, row_of(rendered, "work !S"), { "boss" }).edits
    )
    t.ok(has(out, "08:00 work !S[ado]60"), "boss is removed; ado and the 60m value remain")
    t.eq(#refresh_summaries.run(out).warnings, 0)
  end)

  t.test("run_unlog clears the marker when its last name goes or when given none", function()
    local src = { "--- log q=15 d=dec ---", "08:00 work !S[ado]60", "09:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    local row = row_of(rendered, "work !S[ado]")

    local one = support.apply_edits(rendered, log_current.run_unlog(rendered, row, { "ado" }).edits)
    t.ok(not has(one, "!S[]"), "removing the only name clears the marker")

    local all = support.apply_edits(rendered, log_current.run_unlog(rendered, row).edits)
    t.ok(not has(all, "!S[]"), "run_unlog with no names clears the marker")

    -- Adding a name never unlogs; the row stays logged.
    local added = support.apply_edits(rendered, log_current.run(rendered, row, { "boss" }).edits)
    t.ok(has(added, "!S[ado,boss]"), "run only ever adds")

    -- Unlogging an unlogged row refuses.
    local _, err = log_current.run_unlog(one, row_of(one, "(+0m) work", "workday"))
    t.eq(err, "daylog: this row is not logged; nothing to unlog")
  end)

  t.test("marking a remainder with a new name does not over-commit the day", function()
    -- Regression: an unnamed committed !T[] slice + an unlogged remainder in the same cell. Marking the
    -- remainder with a NEW name must commit only the remainder's own time, not sum in the other slice
    -- (which silently inflated the workday total).
    local src = { "--- log #x q=15 d=dec ---", "08:00 a !T[]60", "09:00 b", "10:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    local out = support.apply_edits(
      rendered,
      log_current.run(rendered, row_of(rendered, ") #x", "!T[]"), { "proj" }).edits
    )
    t.ok(has(out, "09:00 b !T[proj]60"), "the remainder commits its own 60m, not 120m")
    t.ok(has(out, "1.00h (+0m) #x !T[proj]"), "the proj slice reports 1.00h")
    t.ok(has(out, "1.00h (+0m) #x !T[]"), "the unnamed slice is untouched at 1.00h")
    t.ok(has(out, "2.00h (+0m) workday"), "the day still foots to 2.00h -- no phantom hour")
    t.eq(#refresh_summaries.run(out).warnings, 0)
  end)

  t.test("logging a section level never marks the block's closing entry", function()
    -- Regression: the last entry starts no interval, so marking it would silently under-log once a
    -- later entry is appended beneath it.
    local src = { "--- log #x q=15 d=dec ---", "08:00 a", "09:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)
    local out =
      support.apply_edits(rendered, log_current.run(rendered, row_of(rendered, ") #x"), {}).edits)
    t.ok(has(out, "08:00 a !T[]60"), "the interval-starting entry is marked")
    t.ok(not has(out, "09:00 done !T[]60"), "the closing entry is not marked")
  end)

  t.test("logging the unnamed name is additive, and names join the unnamed slice", function()
    -- The unnamed name ("") is a first-class member: adding it to !S[hey] yields !S[,hey], and adding
    -- a real name to the unnamed !S[] slice keeps the unnamed name (an add, never a replace).
    local src =
      { "--- log q=15 d=dec ---", "08:00 task !S[]45", "09:00 task !S[hey]60", "10:00 done" }
    local rendered = support.apply_edits(src, refresh_summaries.run(src).edits)

    local a = support.apply_edits(
      rendered,
      log_current.run(rendered, row_of(rendered, "task !S[hey]"), { "" }).edits
    )
    t.ok(has(a, "09:00 task !S[,hey]60"), "the unnamed name joins the hey slice")
    t.ok(has(a, "1.00h (+0m) task !S[,hey]"), "the slice reports as {unnamed, hey}")
    t.ok(has(a, "0.75h (+15m) task !S[]"), "the separate unnamed slice is untouched")
    t.eq(#refresh_summaries.run(a).warnings, 0)

    local b = support.apply_edits(
      rendered,
      log_current.run(rendered, row_of(rendered, "task !S[]"), { "hey" }).edits
    )
    t.ok(has(b, "08:00 task !S[,hey]45"), "a name joins the unnamed slice at its preserved value")
    t.eq(#refresh_summaries.run(b).warnings, 0)
  end)
end
