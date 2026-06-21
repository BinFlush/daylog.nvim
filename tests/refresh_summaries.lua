return function(t)
  local refresh_summaries = require("blotter.usecases.refresh_summaries")

  -- Apply refresh's edit script to a line list (the pure mirror of the buffer apply),
  -- for tests that assert the resulting document rather than the raw edits.
  local function regen(lines)
    local out = {}
    for i, line in ipairs(lines) do
      out[i] = line
    end
    for _, edit in ipairs(refresh_summaries.run(lines).edits) do
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
  local function has(lines, want)
    for _, line in ipairs(lines) do
      if line == want then
        return true
      end
    end
    return false
  end
  local function count(lines, pattern)
    local n = 0
    for _, line in ipairs(lines) do
      if line:match(pattern) then
        n = n + 1
      end
    end
    return n
  end
  -- Corrupt the keyword of the Nth `--- blots ... ---` header (blots -> blts).
  local function corrupt_nth_header(lines, nth)
    local out, seen = {}, 0
    for _, line in ipairs(lines) do
      if line:match("^%-%-%- blots") then
        seen = seen + 1
      end
      out[#out + 1] = (seen == nth and line:match("^%-%-%- blots")) and (line:gsub("blots", "blts"))
        or line
    end
    return out
  end
  -- Apply fn to the Nth `--- blots ... ---` header; fn returns the new line, or nil to
  -- delete it.
  local function mutate_nth_header(lines, nth, fn)
    local out, seen = {}, 0
    for _, line in ipairs(lines) do
      local is_header = line:match("^%-%-%- blots") ~= nil
      if is_header then
        seen = seen + 1
      end
      if is_header and seen == nth then
        local replaced = fn(line)
        if replaced ~= nil then
          out[#out + 1] = replaced
        end
      else
        out[#out + 1] = line
      end
    end
    return out
  end

  t.test("refresh regenerates a hand-edited summary header from the blotter params", function()
    -- The blotter header is the single source of truth; the summary banner is
    -- read-only display, so an edited q=/d= is overwritten on the next refresh.
    local result = refresh_summaries.run({
      "--- blots q=30 ---",
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
      "--- blots ---",
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

  t.test("refresh collapses a stale summary when the blotter shrinks to empty", function()
    -- Removing the only completed interval leaves one blot (no intervals), so the
    -- fresh summary is empty. The large stale summary is still located
    -- (structurally) and replaced in place, instead of a second summary being added.
    local result = refresh_summaries.run({
      "--- blots #ClientA @office ---",
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
          "0.00h (+0m) workday",
        },
      },
    })
  end)

  t.test("refresh collapses a jumble of duplicated generated summaries into one", function()
    -- A buffer left jumbled by an earlier bad regeneration (two stacked generated
    -- summaries) is recognized as one summary region and rewritten to a single
    -- summary, removing the junk.
    local result = refresh_summaries.run({
      "--- blots #ClientA @office ---",
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
          "0.00h (+0m) workday",
        },
      },
    })
  end)

  t.test("refresh regenerates junk left inside a generated summary section away", function()
    -- "3.55h junk" sits inside the totals section (no blank above it), so it is part
    -- of the summary and the regeneration removes it -- the summary is a pure
    -- projection, so non-generated content inside a section cannot survive a refresh.
    local result = refresh_summaries.run({
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
    })

    t.eq(#result.edits, 1)
    local edit = result.edits[1]
    -- The zone runs from the body end (after the last blot) through the junk line at
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
    -- discards it. (Annotations belong on a blot, never in the summary.)
    local result = refresh_summaries.run({
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
      "--- blots ---",
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

  t.test("refresh of a grown summary keeps the blots", function()
    -- A fresh blotter's empty summary, after a same-time :BlotInsert added a second
    -- blot, must be replaced in place -- not swallow the blots above it. The blast
    -- starts at the body end (after the second blot), leaving the two blots untouched.
    local result = refresh_summaries.run({
      "--- blots #sometag @location q=15 d=dec ---",
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

  t.test("refresh restores a deleted summary row without eating a blot", function()
    -- Deleting a summary row is undone in place; the blotter's blots (here the final
    -- 21:00 close) are never drawn into the rewrite -- the window starts after them.
    local result = refresh_summaries.run({
      "--- blots #sometag @location q=15 d=dec ---",
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
      "--- blots ---",
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
      "--- blots ---",
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
      "--- blots ---",
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

  t.test("refresh rewrites each blotter to the canonical 2-blank layout", function()
    -- Both blotters' summaries are stale against the canonical layout (the second's
    -- total also drifted), so both are blasted, highest-row-first.
    local result = refresh_summaries.run({
      "--- blots ---",
      "08:00 a",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) a",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
      "",
      "--- blots ---",
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
      "--- blots q=30 ---",
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

  t.test("refresh creates a summary for a blotter that has none", function()
    local result = refresh_summaries.run({
      "--- blots ---",
      "08:00 plan",
      "09:00 done",
    })

    -- The summary is inserted after the last blot with the canonical 2-blank
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

  t.test("refresh creates a summary for a non-last blotter in the right place", function()
    local result = refresh_summaries.run({
      "--- blots ---",
      "08:00 a",
      "09:00 done",
      "",
      "--- blots ---",
      "10:00 b",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) b",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })

    -- The first blotter's summary is created after its last blot (row 3), blasting up
    -- to the second blotter header. The second blotter's summary, stale against the
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

  t.test("refresh warns instead of churning an invalid blotter with a summary", function()
    local result = refresh_summaries.run({
      "--- blots ---",
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
          message = "blotter: unordered timestamps near lines 2 and 3; fix manually or run :BlotterOrder",
        },
      },
    })
  end)

  t.test("refresh warns about an invalid blotter even with no summary", function()
    local result = refresh_summaries.run({
      "--- blots ---",
      "09:00 later",
      "08:00 earlier",
      "10:00 done",
    })

    t.eq(result, {
      edits = {},
      warnings = {
        {
          row = 2,
          message = "blotter: unordered timestamps near lines 2 and 3; fix manually or run :BlotterOrder",
        },
      },
    })
  end)

  t.test("refresh warns about timestamps with no blotter header at all", function()
    local result = refresh_summaries.run({
      "08:00 a",
      "07:00 b",
    })

    t.eq(result, {
      edits = {},
      warnings = {
        {
          row = 1,
          message = "blotter: no blotter block found; first line must be a blotter header "
            .. "such as --- blots --- or --- blots #ClientA @office q=30 ---",
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
    -- broken, so nothing is rewritten, but the out-of-order blots below still
    -- warn rather than going silent.
    local result = refresh_summaries.run({
      "",
      "--- blots ---",
      "09:00 later",
      "08:00 earlier",
    })

    t.eq(result, {
      edits = {},
      warnings = {
        {
          row = 2,
          message = "blotter: first line must be a blotter header such as --- blots --- or "
            .. "--- blots #ClientA @office q=30 ---",
        },
        {
          row = 3,
          message = "blotter: unordered timestamps near lines 3 and 4; fix manually or run :BlotterOrder",
        },
      },
    })
  end)

  t.test("refresh recovers a one-character-corrupted blotter header and summarizes it", function()
    -- A later blotter's `--- blots ---` keyword loses a character, so it no longer parses
    -- as a blotter. Refresh repairs the keyword in place and summarizes the recovered
    -- blotter -- and never lets the previous blotter's blast wipe it.
    local materialized = regen({
      "--- blots q=15 ---",
      "09:00 a",
      "10:00 done",
      "",
      "--- blots q=15 ---",
      "13:00 b",
      "14:00 done",
    })
    local result = regen(corrupt_nth_header(materialized, 2))

    t.ok(count(result, "^%-%-%- blts q=15 %-%-%-$") == 0, "the corrupted keyword is repaired")
    t.ok(count(result, "^%-%-%- blots q=15 %-%-%-$") == 2, "both blotters have a proper header")
    t.ok(
      has(result, "13:00 b") and has(result, "14:00 done"),
      "the corrupted blotter's blots survive"
    )
    t.ok(
      count(result, "^%-%-%- summary q=15 d=dec %-%-%-$") == 2,
      "the recovered blotter is summarized"
    )
    t.ok(#refresh_summaries.run(result).edits == 0, "the recovery is idempotent")
  end)

  t.test("refresh recovers a corrupted header preserving its options verbatim", function()
    local materialized = regen({
      "--- blots q=15 ---",
      "09:00 a",
      "10:00 done",
      "",
      "--- blots #proj @site q=30 d=hm ---",
      "13:00 b",
      "14:00 done",
    })
    local result = regen(corrupt_nth_header(materialized, 2))

    t.ok(
      has(result, "--- blots #proj @site q=30 d=hm ---"),
      "options are kept verbatim on recovery"
    )
    t.ok(has(result, "13:00 b") and has(result, "14:00 done"), "the blots survive")
  end)

  t.test(
    "refresh leaves a non-blots block that contains blots alone (no false recovery)",
    function()
      -- A `--- notes ---` whose body happens to hold blot-shaped lines is far from "blots"
      -- in edit distance, so it is never mistaken for a corrupted blotter header.
      local result = regen({
        "--- blots q=15 ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- notes ---",
        "13:00 b",
        "14:00 done",
      })

      t.ok(has(result, "--- notes ---"), "the notes header is left intact")
      t.ok(count(result, "^%-%-%- blots") == 1, "no spurious blotter header is created")
      t.ok(
        has(result, "13:00 b") and has(result, "14:00 done"),
        "its blot-shaped lines are preserved"
      )
    end
  )

  t.test("refresh recovers a header with a dropped dash, reading its parameters back", function()
    local materialized = regen({
      "--- blots q=15 ---",
      "09:00 a",
      "10:00 done",
      "",
      "--- blots q=45 d=hm ---",
      "13:00 b",
      "14:00 done",
    })
    -- Drop a leading dash from the second header (`--- blots …` -> `-- blots …`).
    local result = regen(mutate_nth_header(materialized, 2, function(line)
      return (line:gsub("^%-%-%-", "--"))
    end))

    t.ok(has(result, "--- blots q=45 d=hm ---"), "the dashes are repaired and q=/d= are read back")
    t.ok(has(result, "13:00 b") and has(result, "14:00 done"), "the blots survive")
  end)

  t.test("refresh synthesizes an obliterated header from the previous blotter", function()
    -- The obliterated header has no parameters to read, so the synthesized one inherits
    -- the previous blotter's distinctive metadata (#team q=20), not the second's own.
    local materialized = regen({
      "--- blots #team q=20 ---",
      "09:00 a",
      "10:00 done",
      "",
      "--- blots q=45 ---",
      "13:00 b",
      "14:00 done",
    })
    local result = regen(mutate_nth_header(materialized, 2, function()
      return "rewrite me later"
    end))

    t.ok(
      has(result, "--- blots #team q=20 ---"),
      "the header inherits the previous blotter's metadata"
    )
    t.ok(not has(result, "rewrite me later"), "the obliterating prose is replaced")
    t.ok(has(result, "13:00 b") and has(result, "14:00 done"), "the blots survive")
  end)

  t.test("refresh synthesizes a deleted header line from the previous blotter", function()
    local materialized = regen({
      "--- blots #team q=20 ---",
      "09:00 a",
      "10:00 done",
      "",
      "--- blots q=45 ---",
      "13:00 b",
      "14:00 done",
    })
    -- Delete the second header line entirely (its blots are left headerless).
    local result = regen(mutate_nth_header(materialized, 2, function()
      return nil
    end))

    t.ok(
      has(result, "--- blots #team q=20 ---"),
      "a header is synthesized from the previous blotter"
    )
    t.ok(count(result, "^%-%-%- blots") == 2, "the headerless blots regain a header")
    t.ok(has(result, "13:00 b") and has(result, "14:00 done"), "the blots survive")
  end)
end
