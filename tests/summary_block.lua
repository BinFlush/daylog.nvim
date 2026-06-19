return function(t)
  local analyze = require("blotter.analyze")
  local document = require("blotter.document")
  local render = require("blotter.render")
  local summary = require("blotter.summary")
  local summary_block = require("blotter.summary_block")

  local function analyze_lines(lines)
    return analyze.analyze(document.parse(lines))
  end

  -- The expected summary `find` aligns against: exactly what the plugin renders for a
  -- block (no leading blank, matching an in-buffer summary).
  local function expected_for(block)
    return render.summary_lines(summary.summarize_block(block), block.duration_format, {
      leading_blank = false,
      quantize_minutes = block.quantize_minutes,
    })
  end

  local function locate(lines)
    local analysis = analyze_lines(lines)
    local block = analyze.get_active_worklog(analysis)
    return summary_block.find(analysis, block, expected_for(block))
  end

  -- Direct tests of the Needleman-Wunsch fitting alignment that find() is built on.
  local fit_align = summary_block.fit_align

  t.test("fit_align matches a contiguous span with free leading/trailing gaps", function()
    t.eq(
      fit_align({ "a", "b", "c" }, { "x", "a", "b", "c", "y" }),
      { start = 2, stop = 4, matches = 3 }
    )
  end)

  t.test("fit_align folds a substituted line into the span", function()
    t.eq(fit_align({ "a", "b", "c" }, { "a", "X", "c" }), { start = 1, stop = 3, matches = 2 })
  end)

  t.test("fit_align prefers substitution over deletion at the leading boundary", function()
    -- A mangled first line (X vs A) is kept inside the span as a substitution, so the
    -- span starts at A rather than dropping it into the free prefix.
    t.eq(fit_align({ "X", "b", "c" }, { "A", "b", "c" }), { start = 1, stop = 3, matches = 2 })
  end)

  t.test("fit_align spans across a deleted expected line", function()
    t.eq(fit_align({ "a", "b", "c" }, { "a", "c" }), { start = 1, stop = 2, matches = 2 })
  end)

  t.test("fit_align keeps an inserted actual line inside the span", function()
    t.eq(fit_align({ "a", "b" }, { "a", "X", "b" }), { start = 1, stop = 3, matches = 2 })
  end)

  t.test("fit_align keeps a stale trailing line inside the span", function()
    -- The last expected line (Z) substitutes a stale W rather than being deleted, so W
    -- is inside the span and gets rewritten instead of orphaned.
    t.eq(fit_align({ "a", "b", "Z" }, { "a", "b", "W" }), { start = 1, stop = 3, matches = 2 })
  end)

  t.test("fit_align does not count blank-line matches", function()
    t.eq(fit_align({ "a", "", "b" }, { "a", "", "b" }), { start = 1, stop = 3, matches = 2 })
  end)

  t.test("fit_align reports zero matches for unrelated content", function()
    t.eq(fit_align({ "a", "b" }, { "x", "y" }).matches, 0)
  end)

  t.test("fit_align returns nil for empty expected or empty actual", function()
    t.eq(fit_align({}, { "a" }), nil)
    t.eq(fit_align({ "a" }, {}), nil)
  end)

  t.test("fit_align does not let blank matches pull the span over the worklog body", function()
    -- Regression: a fresh worklog's small summary growing after a same-time insert. An
    -- entry-swallowing span must not tie the real summary by matching extra blank lines,
    -- so the span starts at the old summary header (4), not the entry (1).
    local expected = {
      "--- summary q=15 d=dec ---",
      "0.00h (+0m) hey",
      "",
      "--- tags ---",
      "0.00h (+0m) #sometag",
      "",
      "--- locations ---",
      "0.00h (+0m) @location",
      "",
      "--- totals ---",
      "0.00h (+0m) workday",
    }
    local actual = {
      "08:00 hey",
      "08:00 ",
      "",
      "--- summary q=15 d=dec ---",
      "",
      "--- totals ---",
      "0.00h (+0m) workday",
    }
    t.eq(fit_align(expected, actual), { start = 4, stop = 7, matches = 3 })
  end)

  t.test("summary_block locates an intact summary", function()
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

  t.test("summary_block locates a quantized summary", function()
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

  t.test("summary_block locates a summary whose header was edited", function()
    -- A mangled header is folded into the matched span (a substitution), so a refresh
    -- rewrites it rather than orphaning it.
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
  end)

  t.test("summary_block locates a summary whose header was deleted", function()
    -- `dd` on the "--- summary ... ---" line: the rows leak into the body, but the
    -- alignment still finds them; the leading separator blank stays outside the span.
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

  t.test("summary_block keeps an entry flush against a header-less summary", function()
    -- The summary header was deleted AND there is no separator blank, so the rows sit
    -- directly under the final entry (21:00 done). The window starts after the last
    -- entry, so that entry can never be drawn into the span and rewritten away.
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

  t.test("summary_block recognizes a legacy exact/quantized summary", function()
    -- Older files (kind-word headers) still resolve: the rows align and the headers
    -- are substitutions, so a refresh can rewrite them to the current form.
    t.eq(
      locate({
        "--- blots ---",
        "08:00 plan",
        "09:00 done",
        "",
        "--- summary quantized ---",
        "1.00h (+0m) plan",
        "",
        "--- totals quantized ---",
        "1.00h (+0m) workday",
      }),
      { start_row = 5, end_row = 10 }
    )
  end)

  t.test("summary_block locates a summary when the worklog has no completed interval", function()
    -- One entry -> no intervals -> an empty fresh summary that alignment cannot
    -- anchor; structural recognition still locates the stale summary to rewrite, so
    -- a refresh replaces it instead of stacking a second summary below it.
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
    -- Two stacked generated summaries (an earlier bad regeneration) are located as
    -- one region, so a refresh collapses them.
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

  t.test("summary_block leaves a trailing note outside the located region", function()
    -- A note written below the summary is not swallowed into the region.
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
      { start_row = 5, end_row = 10 }
    )
  end)

  t.test("summary_block leaves a summary-shaped note below the summary outside it", function()
    -- A note that merely starts like a summary row (a duration and a (+Nm) marker)
    -- but sits after the summary's blank, with no section header of its own, is a
    -- note -- it must not extend the region, or a refresh would delete it.
    t.eq(
      locate({
        "--- blots #A ---",
        "08:00 a",
        "09:00 done",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- tags ---",
        "1.00h (+0m) #A",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "3.00h (+0m) billed to client X",
      }),
      { start_row = 5, end_row = 13 }
    )
  end)

  t.test("summary_block includes junk left inside a generated section", function()
    -- A summary-shaped line with no blank above it sits *inside* the totals section,
    -- so it is part of the region and a refresh regenerates it away -- unlike the
    -- after-a-blank note above, which is left outside.
    t.eq(
      locate({
        "--- blots #ClientA @office ---",
        "05:40 plan",
        "10:00 build",
        "11:00 review",
        "",
        "--- summary q=15 d=dec ---",
        "4.25h (+5m) plan",
        "1.00h (+0m) build",
        "",
        "--- tags ---",
        "5.25h (+5m) #ClientA",
        "",
        "--- locations ---",
        "5.25h (+5m) @office",
        "",
        "--- totals ---",
        "5.25h (+5m) workday",
        "3.55h junk",
      }),
      { start_row = 6, end_row = 19 }
    )
  end)

  t.test("summary_block returns nil when there is no summary", function()
    t.eq(locate({ "--- blots ---", "08:00 plan", "09:00 done" }), nil)
  end)

  t.test("summary_block returns nil for unrelated tail content", function()
    -- A stray note that is not the summary must not be grabbed as one.
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

  t.test("summary_block bounds a region to its worklog and ignores others", function()
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
    local first, second = analysis.worklog_blocks[1], analysis.worklog_blocks[2]
    t.eq(summary_block.find(analysis, first, expected_for(first)), { start_row = 5, end_row = 10 })
    t.eq(summary_block.find(analysis, second, expected_for(second)), nil)
  end)
end
