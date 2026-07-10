return function(t)
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")
  local summary_block = require("daylog.summary_block")

  local function analyze_lines(lines)
    return analyze.analyze(document.parse(lines))
  end

  t.test(
    "tail_bounds backs the zone up over a corrupted --- ... --- header, sparing its entries",
    function()
      -- A summary followed by a mangled header that no longer parses as a log/summary, plus entries.
      -- Scanning only for the next LOG would run the blast to EOF; tail_bounds must stop AT the header.
      local lines = {
        "--- log ---", -- 1
        "08:00 plan", -- 2
        "09:00 done", -- 3
        "", -- 4
        "--- summary q=15 d=dec ---", -- 5
        "1.00h (+0m) plan", -- 6
        "", -- 7
        "--- corrupted ---", -- 8  (matches ---...--- but is not a log/summary header)
        "10:00 review", -- 9
        "11:00 done", -- 10
      }
      local analysis = analyze_lines(lines)
      local tail_start, stop_row = summary_block.tail_bounds(analysis, analysis.log_blocks[1])
      t.eq(tail_start, 4)
      t.eq(stop_row, 8) -- stops at, not past, the corrupted header (rows 8-10 preserved)
    end
  )

  t.test("edit_distance returns nil when the DP grid would exceed the cell cap", function()
    local long = string.rep("x", 1001) -- (1001+1)^2 = 1004004 > 1e6
    t.eq(summary_block.edit_distance(long, long), nil)
    t.eq(summary_block.edit_distance("abc", "abd"), 1) -- the ordinary case still measures
  end)

  local function locate(lines)
    local analysis = analyze_lines(lines)
    local block = analyze.get_active_log(analysis)
    return summary_block.find(analysis, block)
  end

  -- Direct tests of the character-level edit distance the mangled-banner search uses.
  local edit_distance = summary_block.edit_distance

  t.test("edit_distance is zero for identical strings", function()
    t.eq(edit_distance("--- summary q=15 d=dec ---", "--- summary q=15 d=dec ---"), 0)
  end)

  t.test("edit_distance counts a single substitution", function()
    t.eq(edit_distance("dec", "dex"), 1)
  end)

  t.test("edit_distance counts a deletion and an insertion", function()
    t.eq(edit_distance("summary", "sumary"), 1) -- one deleted char
    t.eq(edit_distance("dec", "decX"), 1) -- one inserted char
  end)

  t.test("edit_distance handles an empty operand", function()
    t.eq(edit_distance("", "abc"), 3)
    t.eq(edit_distance("abc", ""), 3)
    t.eq(edit_distance("", ""), 0)
  end)

  -- The summary zone is the banner-delimited blast: [banner .. next log/EOF).
  -- `find` returns that whole zone so a refresh regenerates it wholesale; trailing
  -- prose and stale/duplicate sections inside it are deliberately swept in.

  t.test("summary_block spans an intact summary to EOF", function()
    t.eq(
      locate({
        "--- log ---",
        "08:00 plan",
        "09:00 done",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) plan",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      { start_row = 5, end_row = 10 }
    )
  end)

  t.test("summary_block spans a quantized summary", function()
    t.eq(
      locate({
        "--- log q=30 ---",
        "08:00 plan",
        "08:34 done",
        "",
        "--- summary q=30 d=dec ---",
        "0.50h (+4m) plan",
        "",
        "--- totals ---",
        "0.50h (+4m) workday",
      }),
      { start_row = 5, end_row = 10 }
    )
  end)

  t.test("summary_block reclaims a banner with edited parameters", function()
    -- A banner whose q=/d= drifted from the header is still the banner (matched by
    -- shape), so the zone anchors on it and a refresh rewrites it.
    t.eq(
      locate({
        "--- log ---",
        "08:00 plan",
        "09:00 done",
        "",
        "--- summary q=99 d=hm ---",
        "1.00h (+0m) plan",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      { start_row = 5, end_row = 10 }
    )
  end)

  t.test("summary_block reclaims a mangled banner by edit distance", function()
    -- A typo'd / annotated banner is the nearest tail line to the canonical banner,
    -- so the zone anchors on it rather than treating it as a body note.
    t.eq(
      locate({
        "--- log ---",
        "08:00 plan",
        "09:00 done",
        "",
        "--- summary q=15 d=dec EDITED ---",
        "1.00h (+0m) plan",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      { start_row = 5, end_row = 10 }
    )
    t.eq(
      locate({
        "--- log ---",
        "08:00 plan",
        "09:00 done",
        "",
        "--- sumary q=15 d=dec ---",
        "1.00h (+0m) plan",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      { start_row = 5, end_row = 10 }
    )
  end)

  t.test("summary_block recovers a deleted banner from the surviving rows", function()
    -- `dd` on the banner: no banner survives, so the shape fallback anchors on the
    -- first surviving generated row and the zone runs to EOF.
    t.eq(
      locate({
        "--- log ---",
        "08:00 plan",
        "09:00 done",
        "",
        "1.00h (+0m) plan",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      { start_row = 5, end_row = 9 }
    )
  end)

  t.test("summary_block keeps an entry flush against a header-less summary", function()
    -- The banner was deleted AND there is no separator blank, so the rows sit directly
    -- under the final entry. The zone starts after the last entry (its first generated
    -- row), so that entry can never be drawn into the zone.
    t.eq(
      locate({
        "--- log #sometag @location q=15 d=dec ---",
        "20:10 hey",
        "20:33 hey2",
        "21:00 done",
        "0.50h (-3m) hey2",
        "0.25h (+8m) hey",
        "",
        "--- tags ---",
        "0.75h (+5m) #sometag",
        "",
        "--- locations ---",
        "0.75h (+5m) @location",
        "",
        "--- totals ---",
        "0.75h (+5m) workday",
      }),
      { start_row = 5, end_row = 16 }
    )
  end)

  t.test("summary_block spans an empty summary (no completed interval)", function()
    -- One entry -> no intervals -> the banner still survives and anchors the zone, so a
    -- refresh rewrites it instead of stacking a second summary below.
    t.eq(
      locate({
        "--- log ---",
        "08:00 plan",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) plan",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      { start_row = 4, end_row = 9 }
    )
  end)

  t.test("summary_block spans a jumble of duplicated generated summaries", function()
    -- Two stacked generated summaries (an earlier bad regeneration) are one zone, from
    -- the first banner to EOF, so a refresh collapses them.
    t.eq(
      locate({
        "--- log ---",
        "08:00 plan",
        "",
        "--- summary q=15 d=dec ---",
        "",
        "--- totals ---",
        "0.00h (+0m) workday",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) plan",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }),
      { start_row = 4, end_row = 14 }
    )
  end)

  t.test("summary_block sweeps a trailing note into the zone", function()
    -- The summary is edit-free: a note written below it is inside the zone and is
    -- regenerated away, so the zone runs to EOF.
    t.eq(
      locate({
        "--- log ---",
        "08:00 plan",
        "09:00 done",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) plan",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "a note after the summary",
      }),
      { start_row = 5, end_row = 12 }
    )
  end)

  t.test("summary_block returns nil when there is no summary", function()
    t.eq(locate({ "--- log ---", "08:00 plan", "09:00 done" }), nil)
  end)

  t.test("summary_block returns nil for unrelated tail content", function()
    -- A stray note that is not the banner and is not generated-shaped is not a summary.
    t.eq(
      locate({
        "--- log ---",
        "08:00 plan",
        "09:00 done",
        "",
        "just a stray note",
        "another stray note",
      }),
      nil
    )
  end)

  t.test("summary_block bounds the zone to the next log", function()
    local analysis = analyze_lines({
      "--- log ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
      "",
      "--- log ---",
      "10:00 tea",
      "11:00 done",
    })
    local first, second = analysis.log_blocks[1], analysis.log_blocks[2]
    -- The first log's zone stops at the second log's header (row 11).
    t.eq(summary_block.find(analysis, first), { start_row = 5, end_row = 11 })
    t.eq(summary_block.find(analysis, second), nil)
  end)
end
