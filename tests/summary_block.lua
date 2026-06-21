return function(t)
  local analyze = require("blotter.analyze")
  local document = require("blotter.document")
  local render = require("blotter.render")
  local summary = require("blotter.summary")
  local summary_block = require("blotter.summary_block")

  local function analyze_lines(lines)
    return analyze.analyze(document.parse(lines))
  end

  -- The expected summary `find` is given (kept for the caller's signature; the blast
  -- design does not align against it). Content-only, matching an in-buffer summary.
  local function expected_for(block)
    return render.summary_lines(summary.summarize_block(block), block.duration_format, {
      leading_blank = false,
      quantize_minutes = block.quantize_minutes,
    })
  end

  local function locate(lines)
    local analysis = analyze_lines(lines)
    local block = analyze.get_active_blotter(analysis)
    return summary_block.find(analysis, block, expected_for(block))
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

  -- The summary zone is the banner-delimited blast: [banner .. next blotter/EOF).
  -- `find` returns that whole zone so a refresh regenerates it wholesale; trailing
  -- prose and stale/duplicate sections inside it are deliberately swept in.

  t.test("summary_block spans an intact summary to EOF", function()
    t.eq(
      locate({
        "--- blots ---",
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
        "--- blots q=30 ---",
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
        "--- blots ---",
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
        "--- blots ---",
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
        "--- blots ---",
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
        "--- blots ---",
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

  t.test("summary_block keeps a blot flush against a header-less summary", function()
    -- The banner was deleted AND there is no separator blank, so the rows sit directly
    -- under the final blot. The zone starts after the last blot (its first generated
    -- row), so that blot can never be drawn into the zone.
    t.eq(
      locate({
        "--- blots #sometag @location q=15 d=dec ---",
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
    -- One blot -> no intervals -> the banner still survives and anchors the zone, so a
    -- refresh rewrites it instead of stacking a second summary below.
    t.eq(
      locate({
        "--- blots ---",
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
        "--- blots ---",
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
        "--- blots ---",
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
    t.eq(locate({ "--- blots ---", "08:00 plan", "09:00 done" }), nil)
  end)

  t.test("summary_block returns nil for unrelated tail content", function()
    -- A stray note that is not the banner and is not generated-shaped is not a summary.
    t.eq(
      locate({
        "--- blots ---",
        "08:00 plan",
        "09:00 done",
        "",
        "just a stray note",
        "another stray note",
      }),
      nil
    )
  end)

  t.test("summary_block bounds the zone to the next blotter", function()
    local analysis = analyze_lines({
      "--- blots ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
      "",
      "--- blots ---",
      "10:00 tea",
      "11:00 done",
    })
    local first, second = analysis.blotter_blocks[1], analysis.blotter_blocks[2]
    -- The first blotter's zone stops at the second blotter's header (row 11).
    t.eq(summary_block.find(analysis, first, expected_for(first)), { start_row = 5, end_row = 11 })
    t.eq(summary_block.find(analysis, second, expected_for(second)), nil)
  end)
end
