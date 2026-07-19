-- The facts model, asserted from the spec: a logged marker `!X[names]V` records that V minutes of a
-- slice were logged externally, and the summary reports that fact verbatim against the clock. Every
-- counted entry holds ONE displayed share -- its honest quantized split unless a claim pins it -- so
-- all four sections always foot alike, in displayed time and in residuals. Claims pin
-- finest-to-coarsest (S -> T -> L -> W); one the pass cannot realize is a block diagnostic.
return function(t)
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")
  local insert_entry = require("daylog.usecases.insert_entry")
  local log_current = require("daylog.usecases.log_current")
  local refresh_summaries = require("daylog.usecases.refresh_summaries")
  local render = require("daylog.render")
  local repeat_current = require("daylog.usecases.repeat_current")
  local summary = require("daylog.summary")
  local support = require("daylog.usecases.support")

  local function active(lines)
    local analysis = analyze.analyze(document.parse(lines))
    return analysis, analyze.get_active_log(analysis)
  end

  -- The block diagnostic stopping a log from being summarized, or nil.
  local function blocked(lines)
    local analysis, block = active(lines)
    local diagnostic = block and analyze.find_block_diagnostic(analysis, block)
    return diagnostic and diagnostic.message or nil
  end

  -- Every rendered summary row of a log, blanks dropped, so an assertion reads as the report does.
  local function report(lines)
    local _, block = active(lines)
    local out = {}
    for _, line in
      ipairs(
        render.summary_lines(
          summary.summarize_block(block),
          block.duration_format,
          { quantize_minutes = block.quantize_minutes }
        )
      )
    do
      if line ~= "" then
        out[#out + 1] = line
      end
    end
    return out
  end

  -- The invariant behind every example: each row reconciles to the clock, and all four sections
  -- total identically in displayed time AND in summed residuals.
  local function assert_sections_agree(lines)
    local _, block = active(lines)
    local s = summary.summarize_block(block)
    local sections = {
      items = s.summary_items,
      tags = s.tag_totals,
      locations = s.location_totals,
      totals = s.total_rows,
    }

    for name, rows in pairs(sections) do
      local displayed, residual = 0, 0
      for _, row in ipairs(rows) do
        t.eq(
          row.duration + row.error_minutes,
          row.unrounded_duration,
          name .. ": displayed + delta = measured"
        )
        displayed = displayed + row.duration
        residual = residual + row.error_minutes
      end
      t.eq(displayed, s.activity_total, name .. " foots to the same displayed total")
      t.eq(residual, s.activity_error_minutes, name .. " foots to the same residual")
    end
  end

  local function applied(lines, result)
    return support.apply_edits(lines, result.edits)
  end

  -- The last row carrying `needle`: a claim row and the plain row it grew from share a prefix, and
  -- the later one is the more specific match.
  local function row_of(lines, needle)
    local found
    for index, line in ipairs(lines) do
      if line:find(needle, 1, true) then
        found = index
      end
    end
    return found or error("no row matching " .. needle)
  end

  local function refreshed(lines)
    return support.apply_edits(lines, refresh_summaries.run(lines).edits)
  end

  --- GR -- grammar -------------------------------------------------------------------------------

  t.test("GR: a marker must carry its minutes; a bare or malformed one is activity text", function()
    t.eq(
      blocked({ "--- log q=15 ---", "08:00 foo !S[]", "09:00" }),
      "a logged !S marker must carry its minutes"
    )
    t.eq(
      blocked({ "--- log q=15 ---", "08:00 foo !S[]60 !S[]60", "09:00" }),
      "duplicate trailing !S markers are not allowed"
    )
    t.eq(
      blocked({ "--- log q=15 ---", "08:00 foo !S[]1441", "09:00" }),
      "a logged !S value can't exceed 1440 minutes"
    )

    -- Neither of these is a marker at all, so both are ordinary entries whose text happens to end
    -- in one: a bare `!S` has no brackets, and a name with a space breaks the alphabet.
    t.eq(blocked({ "--- log q=15 ---", "08:00 read about !S", "09:00" }), nil)
    t.eq(blocked({ "--- log q=15 ---", "08:00 note !S[foo bar]60", "09:00" }), nil)
  end)

  --- PL -- where a marker may sit -----------------------------------------------------------------

  t.test("PL: a marked closing entry still displays its claim, backed by no clock", function()
    -- The block's only entry closes it and starts no interval, so it measures nothing -- but the
    -- claim is a fact and gets a row, its delta showing the whole gap.
    local lines = { "--- log q=15 ---", "08:00 meet !S[]30" }
    t.eq(report(lines), {
      "--- summary q=15 d=dec ---",
      "0.50h (-30m) meet !S[]",
      "--- totals ---",
      "0.50h (-30m) workday",
    })
    assert_sections_agree(lines)

    -- Append a timestamp and the same claim gains measured backing: the role changed, not the fact.
    local grown = { "--- log q=15 ---", "08:00 meet !S[]30", "09:00" }
    t.ok(report(grown)[2] == "0.50h (+30m) meet !S[]", "the delta tracked reality")
  end)

  t.test("PL: an unmarked closing entry adds no row, and a blank carries no marker", function()
    t.eq(report({ "--- log q=15 ---", "08:00 foo", "09:00 done" }), {
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) foo",
      "--- totals ---",
      "1.00h (+0m) workday",
    })
    t.eq(
      blocked({ "--- log q=15 ---", "08:00 foo", "12:00 !S[]60" }),
      "a blank entry cannot carry a tag, location, marker, alias, or round nudge"
    )
  end)

  --- SL -- the states a claim can be in ------------------------------------------------------------

  t.test("SL: equilibrium, underreport, and overreport are all legal facts", function()
    for value, row in pairs({
      [60] = "1.00h (+0m) foo !S[]",
      [30] = "0.50h (+30m) foo !S[]",
      [90] = "1.50h (-30m) foo !S[]",
    }) do
      local lines = { "--- log q=15 ---", "08:00 foo !S[]" .. value, "09:00" }
      t.eq(blocked(lines), nil, "a claim is never an error by itself")
      t.eq(report(lines)[2], row)
      assert_sections_agree(lines)
    end
  end)

  t.test("SL: a marked and an unmarked run of one activity are two rows", function()
    local lines = { "--- log q=15 ---", "08:00 foo !S[]60", "09:00 foo", "10:00" }
    t.eq(report(lines), {
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) foo !S[]",
      "1.00h (+0m) foo",
      "--- totals ---",
      "2.00h (+0m) workday",
    })
    assert_sections_agree(lines)
  end)

  t.test("SL: the same activity in two places is two claims, free to differ", function()
    local lines =
      { "--- log q=15 ---", "08:00 foo @home !S[]60", "09:00 foo @office !S[]45", "10:00" }
    t.eq(report(lines), {
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) foo @home !S[]",
      "0.75h (+15m) foo @office !S[]",
      "--- locations ---",
      "1.00h (+0m) @home",
      "0.75h (+15m) @office",
      "--- totals ---",
      "1.75h (+15m) workday",
    })
    assert_sections_agree(lines)
  end)

  t.test("SL: different name-sets never mix; each claim gets its own row", function()
    local lines = {
      "--- log q=15 ---",
      "08:00 foo !S[]60",
      "09:00 foo !S[jira]60",
      "10:00 foo !S[,jira]60",
      "11:00 foo",
      "12:00",
    }
    t.eq(blocked(lines), nil)
    t.eq(report(lines), {
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) foo !S[]",
      "1.00h (+0m) foo !S[jira]",
      "1.00h (+0m) foo !S[,jira]",
      "1.00h (+0m) foo",
      "--- totals ---",
      "4.00h (+0m) workday",
    })
    assert_sections_agree(lines)
  end)

  t.test("SL: entries of one slice stating different values is the mixed-times error", function()
    t.eq(
      blocked({ "--- log q=15 ---", "08:00 foo !S[]60", "09:00 foo !S[]120", "10:00" }),
      "logged entries for this activity disagree on their !S value"
    )
  end)

  t.test("SL: claims covering the same minutes must state the same number", function()
    t.eq(
      blocked({ "--- log q=15 ---", "08:00 foo !S[jira]30 !T[boss]150", "09:00" }),
      "this !T claim of 150m contradicts the finer claims on its entries, which hold 30m"
    )
    -- The same half hour recorded in two ledgers is fine.
    t.eq(blocked({ "--- log q=15 ---", "08:00 foo !S[jira]30 !T[boss]30", "09:00" }), nil)
  end)

  t.test("SL: a coarser claim smaller than the claims nested inside it is an error", function()
    t.eq(
      blocked({
        "--- log q=15 ---",
        "08:00 foo !S[jira]300 !W[ts]240",
        "12:00 bar !W[ts]240",
        "13:00",
      }),
      "this !W claim of 240m contradicts the finer claims on its entries, which hold 300m"
    )
  end)

  t.test("SL: a claim whose entries are all pinned must state their sum", function()
    local base = { "--- log q=15 ---", "08:00 foo #ClientA !S[a]60", "09:00 bar !S[b]60", "10:00" }
    local conflicting = vim.deepcopy(base)
    conflicting[2] = conflicting[2] .. " !T[boss]150"
    conflicting[3] = conflicting[3] .. " !T[boss]150"
    t.eq(
      blocked(conflicting),
      "this !T claim of 150m contradicts the finer claims on its entries, which hold 120m"
    )

    local agreeing = vim.deepcopy(base)
    agreeing[2] = agreeing[2] .. " !T[boss]120"
    agreeing[3] = agreeing[3] .. " !T[boss]120"
    t.eq(blocked(agreeing), nil)
  end)

  t.test("SL: the arithmetic error moves with the clock -- a time edit can raise it", function()
    -- Identical markers throughout: only a timestamp moves. Legal at 60/60, because the S claim's
    -- 120 splits evenly and the W claim's entry lands on exactly its 60.
    local legal = { "--- log q=15 ---", "08:00 foo !S[]120 !W[]60", "09:00 foo !S[]120", "10:00" }
    t.eq(blocked(legal), nil)

    -- Push the second entry half an hour later and the S claim splits 90/30 instead, so the W
    -- claim's entry is pinned at 90 -- a number its own claim contradicts.
    local broken = { "--- log q=15 ---", "08:00 foo !S[]120 !W[]60", "09:30 foo !S[]120", "10:00" }
    t.eq(
      blocked(broken),
      "this !W claim of 60m contradicts the finer claims on its entries, which hold 90m"
    )
  end)

  t.test("SL: a round nudge cannot sit on a logged entry", function()
    t.eq(
      blocked({ "--- log q=30 ---", "08:00 foo round+30 !S[]60", "09:00 bar", "10:00" }),
      "a round nudge cannot sit on a logged entry; drop the nudge or unlog the entry"
    )
  end)

  --- PJ -- what the summary shows ------------------------------------------------------------------

  t.test("PJ: with no claims at all, every section foots to the activity total", function()
    local lines =
      { "--- log q=30 ---", "08:00 plan #ClientA @home", "09:40 build #ClientA @home", "12:00" }
    t.eq(report(lines), {
      "--- summary q=30 d=dec ---",
      "2.50h (-10m) build",
      "1.50h (+10m) plan",
      "--- tags ---",
      "4.00h (+0m) #ClientA",
      "--- locations ---",
      "4.00h (+0m) @home",
      "--- totals ---",
      "4.00h (+0m) workday",
    })
    assert_sections_agree(lines)
  end)

  t.test("PJ: a claimed value shows exactly as written, even off the rounding grid", function()
    local lines = { "--- log q=15 ---", "08:00 foo !S[]37", "09:00 bar", "10:00" }
    t.eq(blocked(lines), nil, "an off-grid claim is a fact, not a problem")
    t.eq(report(lines)[3], "0.62h (+23m) foo !S[]")
    assert_sections_agree(lines)
  end)

  t.test("PJ: a claim of zero is meaningful and preserved", function()
    local lines = { "--- log q=15 ---", "08:58 quick fix !S[]0", "09:00 foo", "10:00" }
    t.eq(report(lines)[3], "0.00h (+2m) quick fix !S[]")
    assert_sections_agree(lines)
  end)

  t.test("PJ: a row names its tag or location only when needed to tell rows apart", function()
    local lines =
      { "--- log q=15 ---", "08:00 foo @home", "09:00 bar @home", "10:00 foo @office", "11:00" }
    t.eq(report(lines), {
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) foo @home",
      "1.00h (+0m) foo @office",
      "1.00h (+0m) bar",
      "--- locations ---",
      "2.00h (+0m) @home",
      "1.00h (+0m) @office",
      "--- totals ---",
      "3.00h (+0m) workday",
    })
  end)

  t.test("PJ: a !T claim splits the tags section, and its value shows everywhere", function()
    local lines =
      { "--- log q=15 ---", "08:00 foo #ClientA", "09:00 bar #ClientA !T[boss]60", "10:30" }
    t.eq(report(lines), {
      "--- summary q=15 d=dec ---",
      "1.00h (+30m) bar",
      "1.00h (+0m) foo",
      "--- tags ---",
      "1.00h (+30m) #ClientA !T[boss]",
      "1.00h (+0m) #ClientA",
      "--- totals ---",
      "2.00h (+30m) workday",
    })
    assert_sections_agree(lines)
  end)

  t.test("PJ: a !W claim splits the totals into reported and remaining", function()
    local claimed = {
      "--- log q=15 ---",
      "08:00 foo !W[ts]450",
      "12:00",
      "12:30 bar !W[ts]450",
      "16:00",
    }
    t.eq(report(claimed), {
      "--- summary q=15 d=dec ---",
      "4.00h (+0m) foo",
      "3.50h (+0m) bar",
      "--- totals ---",
      "7.50h (+0m) workday !W[ts]",
    })
    assert_sections_agree(claimed)

    -- Working longer redistributes the claim's 450 over its entries; the day still foots to it.
    local grown = vim.deepcopy(claimed)
    grown[5] = "16:30"
    t.eq(report(grown), {
      "--- summary q=15 d=dec ---",
      "3.75h (+15m) foo",
      "3.75h (+15m) bar",
      "--- totals ---",
      "7.50h (+30m) workday !W[ts]",
    })
    assert_sections_agree(grown)
  end)

  t.test("PJ: an overmarked claim redistributes over its rows, deterministically", function()
    local lines =
      { "--- log q=15 ---", "08:00 foo #ClientA !W[]180", "09:00 bar #ClientA !W[]180", "10:30" }
    t.eq(report(lines), {
      "--- summary q=15 d=dec ---",
      "1.75h (-15m) bar",
      "1.25h (-15m) foo",
      "--- tags ---",
      "3.00h (-30m) #ClientA",
      "--- totals ---",
      "3.00h (-30m) workday !W[]",
    })
    assert_sections_agree(lines)

    -- With a single surplus bucket the tie-break shows: the earlier row takes it.
    local one_bucket = vim.deepcopy(lines)
    one_bucket[2] = "08:00 foo #ClientA !W[]165"
    one_bucket[3] = "09:00 bar #ClientA !W[]165"
    t.eq(report(one_bucket)[2], "1.50h (+0m) bar")
    t.eq(report(one_bucket)[3], "1.25h (-15m) foo")
    assert_sections_agree(one_bucket)
  end)

  t.test("PJ: claims that overlap without nesting resolve in the pinning order", function()
    -- The tag claim distributes first (60/60 over foo and bar, pinning bar), so the location claim's
    -- 90 leaves 30 for baz. Were the location claim first the same file would foot 3.00h, which is
    -- why the order is spec, not an implementation detail.
    local lines = {
      "--- log q=30 ---",
      "08:00 foo #ClientA @office !T[boss]120",
      "09:00 bar #ClientA @site !T[boss]120 !L[fac]90",
      "10:00 baz #internal @site !L[fac]90",
      "11:00",
    }
    t.eq(report(lines), {
      "--- summary q=30 d=dec ---",
      "1.00h (+0m) foo",
      "1.00h (+0m) bar",
      "0.50h (+30m) baz",
      "--- tags ---",
      "2.00h (+0m) #ClientA !T[boss]",
      "0.50h (+30m) #internal",
      "--- locations ---",
      "1.50h (+30m) @site !L[fac]",
      "1.00h (+0m) @office",
      "--- totals ---",
      "2.50h (+30m) workday",
    })
    assert_sections_agree(lines)
  end)

  t.test("PJ: a claim may cover part of a row; the row sums pinned and honest entries", function()
    local lines =
      { "--- log q=15 ---", "08:00 foo #ClientA !T[boss]90", "09:00 foo #ClientA", "10:00" }
    t.eq(report(lines), {
      "--- summary q=15 d=dec ---",
      "2.50h (-30m) foo",
      "--- tags ---",
      "1.50h (-30m) #ClientA !T[boss]",
      "1.00h (+0m) #ClientA",
      "--- totals ---",
      "2.50h (-30m) workday",
    })
    assert_sections_agree(lines)
  end)

  t.test("PJ: untagged and unlocated time lives in ordinary, claimable cells", function()
    local lines = { "--- log q=15 ---", "08:00 foo #ClientA", "09:00 bar #- !T[boss]60", "10:00" }
    t.eq(report(lines), {
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) foo",
      "1.00h (+0m) bar",
      "--- tags ---",
      "1.00h (+0m) #ClientA",
      "1.00h (+0m) (untagged) !T[boss]",
      "--- totals ---",
      "2.00h (+0m) workday",
    })
    assert_sections_agree(lines)
  end)

  t.test("PJ: time after a blank entry is counted nowhere", function()
    local lines = { "--- log q=15 ---", "08:00 foo", "12:00", "13:00 foo", "14:00" }
    t.eq(report(lines), {
      "--- summary q=15 d=dec ---",
      "5.00h (+0m) foo",
      "--- totals ---",
      "5.00h (+0m) workday",
    })
    assert_sections_agree(lines)
  end)

  --- CB -- combining levels -------------------------------------------------------------------------

  t.test("CB: one entry may claim at several levels; each states its own slice's total", function()
    local lines = {
      "--- log q=15 ---",
      "08:00 foo #ClientA !S[jira]240 !T[boss]240 !W[ts]450",
      "12:00",
      "12:30 bar #ClientA !W[ts]450",
      "16:00",
    }
    t.eq(report(lines), {
      "--- summary q=15 d=dec ---",
      "4.00h (+0m) foo !S[jira]",
      "3.50h (+0m) bar",
      "--- tags ---",
      "4.00h (+0m) #ClientA !T[boss]",
      "3.50h (+0m) #ClientA",
      "--- totals ---",
      "7.50h (+0m) workday !W[ts]",
    })
    assert_sections_agree(lines)
  end)

  t.test("CB: a claim's drift flows into every section identically", function()
    local lines = {
      "--- log q=15 ---",
      "08:00 foo #ClientA !S[jira]30 !T[boss]30",
      "09:00 bar #ClientA",
      "10:30",
    }
    t.eq(report(lines), {
      "--- summary q=15 d=dec ---",
      "1.50h (+0m) bar",
      "0.50h (+30m) foo !S[jira]",
      "--- tags ---",
      "1.50h (+0m) #ClientA",
      "0.50h (+30m) #ClientA !T[boss]",
      "--- totals ---",
      "2.00h (+30m) workday",
    })
    assert_sections_agree(lines)
  end)

  --- CM -- commands ---------------------------------------------------------------------------------

  t.test("CM: logging freezes the number the row shows and never stamps the closer", function()
    local lines = refreshed({ "--- log q=15 ---", "08:00 foo", "09:00 foo" })
    local out = applied(lines, log_current.run(lines, row_of(lines, "1.00h (+0m) foo"), {}))
    t.eq(out[2], "08:00 foo !S[]60")
    t.eq(out[3], "09:00 foo", "the closing entry contributes no time and is left alone")
  end)

  t.test("CM: logging the plain sibling merges it into the existing claim", function()
    local lines = refreshed({ "--- log q=15 ---", "08:00 foo !S[jira]60", "09:00 foo", "10:00" })
    local plain = row_of(lines, "1.00h (+0m) foo")
    local out = applied(lines, log_current.run(lines, plain, { "jira" }))
    t.eq(out[2], "08:00 foo !S[jira]120")
    t.eq(out[3], "09:00 foo !S[jira]120")
    t.eq(report(out)[2], "2.00h (+0m) foo !S[jira]", "one row results, at the same displayed total")
  end)

  t.test("CM: logging a claim row with a new name keeps its value", function()
    local lines = refreshed({ "--- log q=15 ---", "08:00 foo !S[jira]60", "09:00" })
    local out = applied(lines, log_current.run(lines, row_of(lines, "foo !S[jira]"), { "boss" }))
    t.eq(out[2], "08:00 foo !S[boss,jira]60")
  end)

  t.test("CM: unlog drops names, and colliding claims merge by summing", function()
    local lines =
      refreshed({ "--- log q=15 ---", "08:00 foo !S[a,b]60", "09:00 foo !S[b]90", "10:00" })
    local out = applied(lines, log_current.run_unlog(lines, row_of(lines, "foo !S[a,b]"), { "a" }))
    t.eq(out[2], "08:00 foo !S[b]150", "the surviving ledger received both amounts")
    t.eq(out[3], "09:00 foo !S[b]150")
    t.eq(report(out)[2], "2.50h (-30m) foo !S[b]", "displayed total and residual are preserved")
  end)

  t.test("CM: no command writes a value above a day", function()
    local lines = refreshed({ "--- log q=15 ---", "06:00 ops !S[jira]1200", "07:00 ops", "14:00" })
    local result, err = log_current.run(lines, row_of(lines, "7.00h (+0m) ops"), { "jira" })
    t.eq(result, nil)
    t.ok(
      err:find("can't exceed 1440", 1, true) ~= nil,
      "the refusal names the cap: " .. tostring(err)
    )
  end)

  t.test("CM: a rename refuses on entries logged at a level it rewrites", function()
    local rename_summary = require("daylog.usecases.rename_summary")
    local lines = refreshed({
      "--- log q=15 ---",
      "08:00 foo @home !S[]60",
      "09:00 foo @office !S[]45",
      "10:00",
    })

    local _, err = rename_summary.run(lines, row_of(lines, "@office"), "site")
    t.eq(err, rename_summary.REFUSE_LOGGED)

    -- A `!W`-only day records neither tag nor location, so its renames ride through.
    local workday =
      refreshed({ "--- log q=15 ---", "08:00 foo @office !W[ts]60", "09:00 bar", "10:00" })
    local result = rename_summary.run(workday, row_of(workday, "@office"), "site")
    t.ok(result ~= nil, "a workday claim never blocks a location rename")
  end)

  t.test("CM: auto-mark joins a claim an insert fits, at every level", function()
    -- A repeat splitting a claimed interval keeps the claim whole.
    local split = { "--- log q=15 ---", "08:00 foo !S[]60", "09:00" }
    t.eq(applied(split, repeat_current.run(split, 2, "08:30"))[3], "08:30 foo !S[]60")

    -- An insert that closes a claim's gap joins it.
    local drifted = { "--- log q=15 ---", "08:30 foo !S[]60", "09:00 bar", "11:00" }
    t.eq(applied(drifted, insert_entry.run(drifted, 2, "10:30", "foo"))[4], "10:30 foo !S[]60")

    -- The same rule at the workday level: the day is claimed, and the insert joins that claim.
    local day =
      { "--- log q=15 ---", "08:00 foo !W[ts]450", "12:00", "12:30 bar !W[ts]450", "16:00" }
    t.eq(applied(day, insert_entry.run(day, 2, "14:00", "meet"))[5], "14:00 meet !W[ts]450")
  end)

  t.test("CM: auto-mark stays its hand in every doubtful case", function()
    -- The claim already fits, so adding to it would only make it worse.
    local fits = { "--- log q=15 ---", "08:00 foo !S[]60", "09:00 bar", "11:00" }
    t.eq(applied(fits, insert_entry.run(fits, 2, "10:00", "foo"))[4], "10:00 foo")

    -- Two claims on the cell: joining either would be a guess.
    local ambiguous = { "--- log q=15 ---", "08:00 foo !S[]30", "09:00 foo !S[jira]30", "10:00" }
    t.eq(applied(ambiguous, insert_entry.run(ambiguous, 2, "09:30", "foo"))[4], "09:30 foo")

    -- The insert becomes the closing entry, so it has no duration to judge a fit by.
    local closing = { "--- log q=15 ---", "08:00 foo !S[]60", "09:00" }
    t.eq(applied(closing, repeat_current.run(closing, 2, "09:30"))[4], "09:30 foo")
  end)

  t.test("CM: auto-mark never writes a conflict", function()
    -- Both levels fit on their own: the S claim is hours short, and the insert exactly restores the
    -- claimed W hour. Together they cannot hold -- the new entry's S share alone (120) exceeds the
    -- whole W claim -- so the W mark is dropped and the file stays valid.
    local lines = { "--- log q=15 ---", "08:00 meet !S[]240", "08:30", "09:00 bar !W[]60", "10:00" }
    local out = applied(lines, insert_entry.run(lines, 2, "09:30", "meet"))
    t.eq(out[5], "09:30 meet !S[]240")
    t.eq(blocked(out), nil)
  end)

  t.test("CM: a fresh mark round-trips; refresh never edits entries", function()
    local base = refreshed({ "--- log q=15 ---", "08:00 foo", "09:00 foo", "10:00" })
    local logged = applied(base, log_current.run(base, row_of(base, "2.00h (+0m) foo"), {}))
    local back = applied(logged, log_current.run_unlog(logged, row_of(logged, "foo !S[]"), nil))
    t.eq(back, base, "unlog reverses a fresh log byte for byte")

    t.eq(#refresh_summaries.run(logged).edits, 0, "an already-current summary yields no edit")
  end)
end
