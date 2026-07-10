return function(t)
  local analyze = require("daylog.analyze")
  local split_summary = require("daylog.usecases.split_summary")
  local document = require("daylog.document")
  local render = require("daylog.render")
  local summary = require("daylog.summary")

  -- A full buffer (log body + its generated summary), so the cursor can sit on a real
  -- summary line exactly as in an open file (mirrors tests/balance_summary.lua). q=1 and
  -- d=hm keep the summary durations exact and minute-formatted for assertions.
  local function buffer_with_summary(log_lines)
    local analysis = analyze.analyze(document.parse(log_lines))
    local block = analyze.get_active_log(analysis)
    local out = {}
    for _, line in ipairs(log_lines) do
      out[#out + 1] = line
    end
    -- The canonical two-blank separator owns the gap between body and summary.
    out[#out + 1] = ""
    out[#out + 1] = ""
    for _, line in
      ipairs(render.summary_lines(summary.summarize_block(block), block.duration_format, {
        leading_blank = false,
        quantize_minutes = block.quantize_minutes,
      }))
    do
      out[#out + 1] = line
    end
    return out
  end

  local function apply(lines, result)
    local out = {}
    for _, line in ipairs(lines) do
      out[#out + 1] = line
    end
    for _, edit in ipairs(result.edits) do
      local next_out = {}
      for i = 1, edit.start_index do
        next_out[#next_out + 1] = out[i]
      end
      for _, line in ipairs(edit.lines) do
        next_out[#next_out + 1] = line
      end
      for i = edit.end_index + 1, #out do
        next_out[#next_out + 1] = out[i]
      end
      out = next_out
    end
    return out
  end

  local function row_of(lines, needle)
    for i, line in ipairs(lines) do
      if line:find(needle, 1, true) then
        return i
      end
    end
    error("line not found: " .. needle)
  end

  local function has(lines, line)
    for _, l in ipairs(lines) do
      if l == line then
        return true
      end
    end
    return false
  end

  local function run(lines, needle, weights)
    local result, err = split_summary.run(lines, row_of(lines, needle), weights)
    if not result then
      return nil, err
    end
    return apply(lines, result)
  end

  t.test("split divides one interval evenly into named parts", function()
    local out = run(
      buffer_with_summary({
        "--- log q=1 d=hm ---",
        "08:00 meeting",
        "10:00 done",
      }),
      "(+0m) meeting",
      { 1, 1 }
    )

    t.eq(out[2], "08:00 meeting (1)")
    t.eq(out[3], "09:00 meeting (2)")
    t.eq(out[4], "10:00 done")
    t.ok(has(out, "1:00 (+0m) meeting (1)"), "part 1 reads one hour")
    t.ok(has(out, "1:00 (+0m) meeting (2)"), "part 2 reads one hour")
  end)

  t.test("split divides one interval by weight", function()
    local out = run(
      buffer_with_summary({
        "--- log q=1 d=hm ---",
        "08:00 meeting",
        "10:00 done",
      }),
      "(+0m) meeting",
      { 3, 1 }
    )

    -- 120 min split 3:1 -> 90 / 30, so part 2 starts at 09:30.
    t.eq(out[2], "08:00 meeting (1)")
    t.eq(out[3], "09:30 meeting (2)")
    t.ok(has(out, "1:30 (+0m) meeting (1)"), "part 1 is 90 minutes")
    t.ok(has(out, "0:30 (+0m) meeting (2)"), "part 2 is 30 minutes")
  end)

  t.test("split sums a multi-interval activity per part", function()
    local out = run(
      buffer_with_summary({
        "--- log q=1 d=hm ---",
        "08:00 work",
        "09:00 other",
        "10:00 work",
        "11:00 done",
      }),
      "(+0m) work",
      { 1, 1 }
    )

    t.eq(out[2], "08:00 work (1)")
    t.eq(out[3], "08:30 work (2)")
    t.eq(out[4], "09:00 other")
    t.eq(out[5], "10:00 work (1)")
    t.eq(out[6], "10:30 work (2)")
    -- Each part totals one hour across its two intervals.
    t.ok(has(out, "1:00 (+0m) work (1)"), "part 1 totals one hour")
    t.ok(has(out, "1:00 (+0m) work (2)"), "part 2 totals one hour")
  end)

  t.test("split compensates a short interval in a longer one", function()
    -- task has a 2-min interval and a 10-min interval; weights 1:5 target 2 / 10. The
    -- short interval cannot afford part 1, so it holds only part 2; part 1 appears in
    -- the long interval and its total lands on its 2-minute target.
    local out = run(
      buffer_with_summary({
        "--- log q=1 d=hm ---",
        "08:00 task",
        "08:02 other",
        "08:04 task",
        "08:14 done",
      }),
      "(+0m) task",
      { 1, 5 }
    )

    t.eq(out[2], "08:00 task (2)")
    t.eq(out[3], "08:02 other")
    t.eq(out[4], "08:04 task (1)")
    t.eq(out[5], "08:06 task (2)")
    t.eq(out[6], "08:14 done")
    t.ok(has(out, "0:02 (+0m) task (1)"), "part 1 lands on its 2-minute target")
    t.ok(has(out, "0:10 (+0m) task (2)"), "part 2 lands on its 10-minute target")
  end)

  t.test("split preserves explicit metadata on the renamed original", function()
    local out = run(
      buffer_with_summary({
        "--- log ---",
        "08:00 meeting #ClientA @office",
        "10:00 done #- @-",
      }),
      "(+0m) meeting",
      { 1, 1 }
    )

    -- The first part keeps the explicit tag/location; the inserted part inherits them;
    -- the follower still clears them, unchanged.
    t.eq(out[2], "08:00 meeting (1) #ClientA @office")
    t.eq(out[3], "09:00 meeting (2)")
    t.eq(out[4], "10:00 done #- @-")
  end)

  t.test("split refuses a logged activity", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "08:00 meeting !S[]120",
      "10:00 done",
    })
    local _, err = split_summary.run(lines, row_of(lines, "(+0m) meeting !S[]"), { 1, 1 })
    t.eq(err, split_summary.REFUSE_LOGGED)
  end)

  t.test("split refuses an activity whose entries carry a non-!S marker (!T/!L/!W)", function()
    -- The `meeting` activity is not !S-logged, but its tag total is committed (`!T[]120`). Splitting
    -- would rewrite the entry without the marker and silently erase the commitment -- refuse instead.
    local lines = buffer_with_summary({
      "--- log #ClientA q=1 d=hm ---",
      "08:00 meeting !T[]120",
      "10:00 done",
    })
    local _, err = split_summary.run(lines, row_of(lines, "(+0m) meeting"), { 1, 1 })
    t.eq(err, split_summary.REFUSE_LOGGED)
  end)

  t.test("split apportions real time across an offset change", function()
    -- The header pins the start at utc+0, so the first entry is explicitly UTC and the log
    -- stays timezone-consistent (offset-free entries before a utc token would be refused).
    -- stand is 2.5h of real time though its local window is only 30 min (the clock jumps to
    -- utc-2 at the next entry). An even split gives each part 1:15 of real time, placed with
    -- no new utc token; stand (2) lands at 10:25, and the next entry is in a new time zone
    -- (utc-2) so its earlier 09:40 reading is fine -- real time keeps increasing.
    local out = run(
      buffer_with_summary({
        "--- log utc+0 q=1 d=hm ---",
        "09:10 stand",
        "09:40 test utc-2",
      }),
      "(+0m) stand",
      { 1, 1 }
    )

    t.eq(out[2], "09:10 stand (1)")
    t.eq(out[3], "10:25 stand (2)")
    t.eq(out[4], "09:40 test utc-2")
    t.ok(has(out, "1:15 (+0m) stand (1)"), "part 1 is 1h15m of real time")
    t.ok(has(out, "1:15 (+0m) stand (2)"), "part 2 is 1h15m of real time")
  end)

  t.test("split works when a later entry is written in a new time zone", function()
    -- The header pins the start at utc+0 (keeping the log timezone-consistent). A at 10:00
    -- then B at 09:00 utc-2: B is written in a new zone (we moved utc-2), so its wall clock
    -- reads an hour earlier though real time advanced an hour (UTC 10:00 -> 11:00). Splitting
    -- A evenly yields two 30-min parts.
    local out = run(
      buffer_with_summary({
        "--- log utc+0 q=1 d=hm ---",
        "10:00 A",
        "09:00 B utc-2",
      }),
      "(+0m) A",
      { 1, 1 }
    )

    t.eq(out[2], "10:00 A (1)")
    t.eq(out[3], "10:30 A (2)")
    t.eq(out[4], "09:00 B utc-2")
    t.ok(has(out, "0:30 (+0m) A (1)"), "part 1 is 30 minutes")
    t.ok(has(out, "0:30 (+0m) A (2)"), "part 2 is 30 minutes")
  end)

  t.test("split refuses when an offset change pushes a cut past the end of the day", function()
    -- The header pins the start at utc+0 (keeping the log timezone-consistent). late is 2h of
    -- real time starting at 23:00; an even split would place the second part at 24:00 on the
    -- local clock, with another entry after it -- not a writable time.
    local lines = buffer_with_summary({
      "--- log utc+0 q=1 d=hm ---",
      "23:00 late",
      "23:00 done utc-2",
    })
    local _, err = split_summary.run(lines, row_of(lines, "(+0m) late"), { 1, 1 })
    t.eq(err, split_summary.REFUSE_OFFSET)
  end)

  t.test("split works with a constant offset across the interval", function()
    -- The whole log is utc-2, so the interval does not cross a change: raw == effective
    -- and the split proceeds normally.
    local out = run(
      buffer_with_summary({
        "--- log utc-2 q=1 d=hm ---",
        "09:10 stand",
        "09:40 done",
      }),
      "(+0m) stand",
      { 1, 1 }
    )

    t.eq(out[2], "09:10 stand (1)")
    t.eq(out[3], "09:25 stand (2)")
    t.ok(has(out, "0:15 (+0m) stand (1)"), "part 1 is 15 minutes")
    t.ok(has(out, "0:15 (+0m) stand (2)"), "part 2 is 15 minutes")
  end)

  t.test("split points a non-activity summary row at the right row", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "08:00 meeting",
      "10:00 done",
    })
    local _, err = split_summary.run(lines, row_of(lines, "(+0m) workday"), { 1, 1 })
    t.eq(err, split_summary.NOT_A_ROW)
  end)

  t.test("split on an entry asks for a summary row instead of reporting STALE", function()
    -- The cursor on a valid entry (not a summary row) must report NOT_A_ROW, not the
    -- misleading STALE "regenerate the summary" reserved for a genuine region mismatch.
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "08:00 meeting",
      "10:00 done",
    })
    local _, err = split_summary.run(lines, row_of(lines, "08:00 meeting"), { 1, 1 })
    t.eq(err, split_summary.NOT_A_ROW)
  end)

  t.test("split rejects bad weight vectors", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "08:00 meeting",
      "10:00 done",
    })
    local row = row_of(lines, "(+0m) meeting")

    local _, one = split_summary.run(lines, row, { 5 })
    t.eq(one, split_summary.NEED_TWO)

    local _, bad = split_summary.run(lines, row, { 2, 0 })
    t.eq(bad, split_summary.BAD_WEIGHT)
  end)

  t.test("split with no weights defaults to an even two-way split", function()
    local out = run(
      buffer_with_summary({
        "--- log q=1 d=hm ---",
        "08:00 meeting",
        "10:00 done",
      }),
      "(+0m) meeting",
      nil
    )
    t.eq(out[2], "08:00 meeting (1)")
    t.eq(out[3], "09:00 meeting (2)")
  end)

  t.test("split suffixes the resolved label: a mapped entry keeps its description", function()
    -- The `(n)` lands on the alias, so parts stay mapped and the description survives --
    -- a bare and a mapped group split identically (the parts still lose !S[] / nudge).
    local out = run(
      buffer_with_summary({
        "--- log q=1 d=hm ---",
        "08:00 meeting => MTG-1",
        "10:00 done",
      }),
      "(+0m) MTG-1",
      { 1, 1 }
    )

    t.eq(out[2], "08:00 meeting => MTG-1 (1)")
    t.eq(out[3], "09:00 meeting => MTG-1 (2)")
    t.ok(has(out, "1:00 (+0m) MTG-1 (1)"), "the part reports under its suffixed label")
  end)

  t.test("splitting a mapped GROUP reports exactly like the equivalent bare group", function()
    -- Two entries mapped to one label: the parts group across entries under `label (n)`,
    -- so the requested proportions land on the report rows (bare ≡ mapped).
    local out = run(
      buffer_with_summary({
        "--- log q=1 d=hm ---",
        "08:00 a => X",
        "09:00 b => X",
        "10:00 done",
      }),
      "(+0m) X",
      { 3, 1 }
    )

    t.eq(out[2], "08:00 a => X (1)")
    t.eq(out[3], "08:45 a => X (2)")
    t.eq(out[4], "09:00 b => X (1)")
    t.eq(out[5], "09:45 b => X (2)")
    t.ok(has(out, "1:30 (+0m) X (1)"), "part 1 carries the 3-share across both entries")
    t.ok(has(out, "0:30 (+0m) X (2)"), "part 2 carries the 1-share across both entries")
  end)
end
