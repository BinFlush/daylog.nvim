return function(t)
  local refresh_summaries = require("daylog.usecases.refresh_summaries")

  t.test("refresh regenerates a hand-edited summary header from the log params", function()
    -- The log header is the single source of truth; the summary banner is
    -- read-only display, so an edited q=/d= is overwritten on the next refresh.
    local result = refresh_summaries.run({
      "--- log q=30 ---",
      "08:00 plan",
      "08:34 done",
      "",
      "--- summary q=99 d=hm ---",
      "0.50h (+4m) plan",
      "",
      "--- totals ---",
      "0.50h (+4m) workday",
    })

    -- The blast emits two separator blanks before the regenerated banner.
    t.eq(result.edits[1].lines[3], "--- summary q=30 d=dec ---")
  end)

  t.test("refresh restores a summary whose header was deleted (no duplicate)", function()
    -- `dd` on the "--- summary ... ---" line leaks the rows into the body; with no
    -- banner the shape fallback anchors on the surviving rows, and the blast rewrites
    -- the whole zone (separator included) in place, with no second summary.
    local result = refresh_summaries.run({
      "--- log ---",
      "08:00 plan",
      "10:00 done",
      "",
      "2.00h (+0m) plan",
      "",
      "--- totals ---",
      "2.00h (+0m) workday",
    })

    t.eq(result.edits, {
      {
        start_index = 3,
        end_index = 8,
        lines = {
          "",
          "",
          "--- summary q=15 d=dec ---",
          "2.00h (+0m) plan",
          "",
          "--- totals ---",
          "2.00h (+0m) workday",
        },
      },
    })
  end)

  t.test("refresh collapses a stale summary when the log shrinks to empty", function()
    -- Removing the only completed interval leaves one entry (no intervals), so the
    -- fresh summary is empty. The large stale summary is still located
    -- (structurally) and replaced in place, instead of a second summary being added.
    local result = refresh_summaries.run({
      "--- log #ClientA @office ---",
      "08:40 standup",
      "",
      "--- summary q=15 d=dec ---",
      "0.25h (+5m) standup",
      "",
      "--- tags ---",
      "0.25h (+5m) #ClientA",
      "",
      "--- locations ---",
      "0.25h (+5m) @office",
      "",
      "--- totals ---",
      "0.25h (+5m) workday",
    })

    t.eq(result.edits, {
      {
        start_index = 2,
        end_index = 14,
        lines = {
          "",
          "",
          "--- summary q=15 d=dec ---",
          "",
          "--- totals ---",
        },
      },
    })
  end)

  t.test("refresh collapses a jumble of duplicated generated summaries into one", function()
    -- A buffer left jumbled by an earlier bad regeneration (two stacked generated
    -- summaries) is recognized as one summary region and rewritten to a single
    -- summary, removing the junk.
    local result = refresh_summaries.run({
      "--- log #ClientA @office ---",
      "08:40 standup",
      "",
      "--- summary q=15 d=dec ---",
      "",
      "--- totals ---",
      "0.00h (+0m) workday",
      "",
      "--- summary q=15 d=dec ---",
      "0.25h (+5m) standup",
      "",
      "--- tags ---",
      "0.25h (+5m) #ClientA",
      "",
      "--- locations ---",
      "0.25h (+5m) @office",
      "",
      "--- totals ---",
      "0.25h (+5m) workday",
    })

    t.eq(result.edits, {
      {
        start_index = 2,
        end_index = 19,
        lines = {
          "",
          "",
          "--- summary q=15 d=dec ---",
          "",
          "--- totals ---",
        },
      },
    })
  end)

  t.test("refresh regenerates junk left inside a generated summary section away", function()
    -- "3.55h junk" sits inside the totals section (no blank above it), so it is part
    -- of the summary and the regeneration removes it -- the summary is a pure
    -- projection, so non-generated content inside a section cannot survive a refresh.
    local result = refresh_summaries.run({
      "--- log #ClientA @office ---",
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
    })

    t.eq(#result.edits, 1)
    local edit = result.edits[1]
    -- The zone runs from the body end (after the last entry) through the junk line at
    -- EOF; the blast rewrites separator + summary and discards everything below.
    t.eq(edit.start_index, 4)
    t.eq(edit.end_index, 18)
    -- The rewritten summary ends at the workday total; the junk line is gone.
    t.eq(edit.lines[#edit.lines], "5.25h (+5m) workday")
    for _, line in ipairs(edit.lines) do
      t.ok(line ~= "3.55h junk", "the junk line must be regenerated away")
    end
  end)

  t.test("refresh regenerates a summary-shaped note written below the summary", function()
    -- The summary is an edit-free, entirely-generated zone: a summary-shaped line
    -- written below it ("3.00h (+0m) billed ...") sits inside the zone, so the blast
    -- discards it. (Annotations belong on an entry, never in the summary.)
    local result = refresh_summaries.run({
      "--- log #A ---",
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
    })

    t.eq(result.edits, {
      {
        start_index = 3,
        end_index = 14,
        lines = {
          "",
          "",
          "--- summary q=15 d=dec ---",
          "1.00h (+0m) a",
          "",
          "--- tags ---",
          "1.00h (+0m) #A",
          "",
          "--- totals ---",
          "1.00h (+0m) workday",
        },
      },
    })
  end)

  t.test("refresh restores an edited section header (no orphan)", function()
    local result = refresh_summaries.run({
      "--- log ---",
      "08:00 plan",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) plan",
      "",
      "--- totals OOPS ---",
      "2.00h (+0m) workday",
    })

    t.eq(result.edits, {
      {
        start_index = 3,
        end_index = 9,
        lines = {
          "",
          "",
          "--- summary q=15 d=dec ---",
          "2.00h (+0m) plan",
          "",
          "--- totals ---",
          "2.00h (+0m) workday",
        },
      },
    })
  end)

  t.test("refresh of a grown summary keeps the entries", function()
    -- A fresh log's empty summary, after a same-time :Daylog insert added a second
    -- entry, must be replaced in place -- not swallow the entries above it. The blast
    -- starts at the body end (after the second entry), leaving the two entries untouched.
    local result = refresh_summaries.run({
      "--- log #sometag @location q=15 d=dec ---",
      "08:00 hey",
      "08:00 ",
      "",
      "--- summary q=15 d=dec ---",
      "",
      "--- totals ---",
      "0.00h (+0m) workday",
    })

    t.eq(result.edits, {
      {
        start_index = 3,
        end_index = 8,
        lines = {
          "",
          "",
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
        },
      },
    })
  end)

  t.test("refresh restores a deleted summary row without eating an entry", function()
    -- Deleting a summary row is undone in place; the log's entries (here the final
    -- 21:00 close) are never drawn into the rewrite -- the window starts after them.
    local result = refresh_summaries.run({
      "--- log #sometag @location q=15 d=dec ---",
      "20:10 hey",
      "20:33 hey2",
      "21:00 done",
      "--- summary q=15 d=dec ---",
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
    })

    t.eq(result.edits, {
      {
        start_index = 4,
        end_index = 15,
        lines = {
          "",
          "",
          "--- summary q=15 d=dec ---",
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
        },
      },
    })
  end)

  t.test("refresh rewrites a stale summary in place", function()
    local result = refresh_summaries.run({
      "--- log ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "0.50h (+0m) plan",
      "",
      "--- totals ---",
      "0.50h (+0m) workday",
    })

    t.eq(result, {
      warnings = {},
      edits = {
        {
          start_index = 3,
          end_index = 9,
          lines = {
            "",
            "",
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) plan",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
      },
    })
  end)

  t.test("refresh migrates a legacy quantized-header summary to the kind-less form", function()
    local result = refresh_summaries.run({
      "--- log ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary quantized ---",
      "1.00h (+0m) plan",
      "",
      "--- totals quantized ---",
      "1.00h (+0m) workday",
    })

    t.eq(result, {
      warnings = {},
      edits = {
        {
          start_index = 3,
          end_index = 9,
          lines = {
            "",
            "",
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) plan",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
      },
    })
  end)

  t.test("refresh is a no-op when the summary is already current", function()
    -- Already canonical: two blank lines separate the body from the summary.
    local result = refresh_summaries.run({
      "--- log ---",
      "08:00 plan",
      "09:00 done",
      "",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })

    t.eq(result, { edits = {}, warnings = {} })
  end)

  t.test("refresh rewrites each log to the canonical 2-blank layout", function()
    -- Both logs' summaries are stale against the canonical layout (the second's
    -- total also drifted), so both are blasted, highest-row-first.
    local result = refresh_summaries.run({
      "--- log ---",
      "08:00 a",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) a",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
      "",
      "--- log ---",
      "10:00 b",
      "11:30 done",
      "",
      "--- summary q=15 d=dec ---",
      "0.50h (+0m) b",
      "",
      "--- totals ---",
      "0.50h (+0m) workday",
    })

    t.eq(result, {
      warnings = {},
      edits = {
        {
          start_index = 13,
          end_index = 19,
          lines = {
            "",
            "",
            "--- summary q=15 d=dec ---",
            "1.50h (+0m) b",
            "",
            "--- totals ---",
            "1.50h (+0m) workday",
          },
        },
        {
          start_index = 3,
          end_index = 10,
          lines = {
            "",
            "",
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) a",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
            "",
            "",
          },
        },
      },
    })
  end)

  t.test("refresh preserves the summary kind", function()
    local result = refresh_summaries.run({
      "--- log q=30 ---",
      "08:00 plan",
      "08:34 done",
      "",
      "--- summary q=30 d=dec ---",
      "1.00h (+0m) plan",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })

    t.eq(result, {
      warnings = {},
      edits = {
        {
          start_index = 3,
          end_index = 9,
          lines = {
            "",
            "",
            "--- summary q=30 d=dec ---",
            "0.50h (+4m) plan",
            "",
            "--- totals ---",
            "0.50h (+4m) workday",
          },
        },
      },
    })
  end)

  t.test("refresh creates a summary for a log that has none", function()
    local result = refresh_summaries.run({
      "--- log ---",
      "08:00 plan",
      "09:00 done",
    })

    -- The summary is inserted after the last entry with the canonical 2-blank
    -- separator; re-running on the result is a no-op.
    t.eq(result, {
      warnings = {},
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = {
            "",
            "",
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) plan",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
      },
    })
  end)

  t.test("refresh creates a summary for a non-last log in the right place", function()
    local result = refresh_summaries.run({
      "--- log ---",
      "08:00 a",
      "09:00 done",
      "",
      "--- log ---",
      "10:00 b",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) b",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })

    -- The first log's summary is created after its last entry (row 3), blasting up
    -- to the second log header. The second log's summary, stale against the
    -- canonical 2-blank layout, is also rewritten -- edits apply highest-row-first.
    t.eq(result, {
      warnings = {},
      edits = {
        {
          start_index = 7,
          end_index = 13,
          lines = {
            "",
            "",
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) b",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
        {
          start_index = 3,
          end_index = 4,
          lines = {
            "",
            "",
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) a",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
            "",
            "",
          },
        },
      },
    })
  end)

  t.test("refresh warns instead of churning an invalid log with a summary", function()
    local result = refresh_summaries.run({
      "--- log ---",
      "09:00 later",
      "08:00 earlier",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "0.50h (+0m) later",
      "",
      "--- totals ---",
      "0.50h (+0m) workday",
    })

    t.eq(result, {
      edits = {},
      warnings = {
        {
          row = 2,
          message = "daylog: unordered timestamps near lines 2 and 3; fix manually or run :Daylog order",
        },
      },
    })
  end)

  t.test("refresh warns about an invalid log even with no summary", function()
    local result = refresh_summaries.run({
      "--- log ---",
      "09:00 later",
      "08:00 earlier",
      "10:00 done",
    })

    t.eq(result, {
      edits = {},
      warnings = {
        {
          row = 2,
          message = "daylog: unordered timestamps near lines 2 and 3; fix manually or run :Daylog order",
        },
      },
    })
  end)

  t.test("refresh warns about timestamps with no log header at all", function()
    local result = refresh_summaries.run({
      "08:00 a",
      "07:00 b",
    })

    t.eq(result, {
      edits = {},
      warnings = {
        {
          row = 1,
          message = "daylog: no log block found; first line must be a log header "
            .. "such as --- log --- or --- log #ClientA @office q=30 ---",
        },
      },
    })
  end)

  t.test("refresh does not warn about a blank, header-less buffer", function()
    t.eq(refresh_summaries.run({}), { edits = {}, warnings = {} })
    t.eq(refresh_summaries.run({ "", "" }), { edits = {}, warnings = {} })
    t.eq(refresh_summaries.run({ "just some prose" }), { edits = {}, warnings = {} })
  end)

  t.test("refresh warns but does not edit a structurally broken document", function()
    -- A blank first line pushes the header off row 1: the document is structurally
    -- broken, so nothing is rewritten, but the out-of-order entries below still
    -- warn rather than going silent.
    local result = refresh_summaries.run({
      "",
      "--- log ---",
      "09:00 later",
      "08:00 earlier",
    })

    t.eq(result, {
      edits = {},
      warnings = {
        {
          row = 2,
          message = "daylog: first line must be a log header such as --- log --- or "
            .. "--- log #ClientA @office q=30 ---",
        },
        {
          row = 3,
          message = "daylog: unordered timestamps near lines 3 and 4; fix manually or run :Daylog order",
        },
      },
    })
  end)

  t.test("refresh warns about a round nudge that drives an item below zero", function()
    -- A hand-typed round-N too large to absorb (-9999 on a 60-min item at q=15) would round
    -- the row below zero. The quantizer clamps the display to 0.00h and the summary still
    -- regenerates, but refresh surfaces the out-of-range marker as a diagnostic at its entry.
    local result = refresh_summaries.run({
      "--- log #ClientA q=15 ---",
      "08:00 task round-9999",
      "09:00 done",
    })

    t.eq(result.warnings, {
      {
        row = 2,
        message = "daylog: round-9999 rounds this item below zero; clear or reduce the nudge",
      },
    })
    t.ok(#result.edits > 0, "the summary still regenerates around the clamped row")
  end)

  t.test("refresh accepts a round nudge that lands exactly on zero", function()
    -- A 60-min item at q=15 holds four buckets; round-4 takes it to exactly 0.00h, which is
    -- in range, so no diagnostic is raised. Only round-5 and beyond cross below zero.
    local result = refresh_summaries.run({
      "--- log #ClientA q=15 ---",
      "08:00 task round-4",
      "09:00 done",
    })

    t.eq(result.warnings, {})
  end)

  local function has_ooo_warning(warnings)
    for _, w in ipairs(warnings) do
      if w.message:match("out%-of%-office time cannot be logged") then
        return w.row
      end
    end
    return nil
  end

  t.test("refresh warns when out-of-office time is marked logged", function()
    -- :Daylog log refuses #ooo, but a hand-typed `#ooo !S` slips an inert logged marker past it
    -- (nothing in the workday-only logged section can account for it). Refresh must surface that.
    local result = refresh_summaries.run({
      "--- log ---",
      "08:00 lunch #ooo !S30",
      "09:00 done",
    })

    t.eq(has_ooo_warning(result.warnings), 2) -- pointed at the offending entry line

    -- Order-independent: the same contradiction typed the other way (bare !S, then #ooo) still warns.
    local reordered = refresh_summaries.run({
      "--- log ---",
      "08:00 lunch !S #ooo",
      "09:00 done",
    })
    t.eq(has_ooo_warning(reordered.warnings), 2)
  end)

  t.test("refresh does not warn on #ooo without !S, or !S without #ooo", function()
    local ooo_only = refresh_summaries.run({
      "--- log ---",
      "08:00 lunch #ooo",
      "09:00 work #-",
      "10:00 done",
    })
    t.eq(has_ooo_warning(ooo_only.warnings), nil)

    local logged_only = refresh_summaries.run({
      "--- log ---",
      "08:00 work !S60",
      "09:00 done",
    })
    t.eq(has_ooo_warning(logged_only.warnings), nil)
  end)
end
