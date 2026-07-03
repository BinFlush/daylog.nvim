return function(t)
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")
  local map_summary = require("daylog.usecases.map_summary")
  local render = require("daylog.render")
  local summary = require("daylog.summary")

  -- A full buffer (log body + its generated summary), so the cursor can sit on a real
  -- summary line or an entry exactly as in an open file (mirrors tests/split_summary.lua).
  local function buffer_with_summary(log_lines)
    local block = analyze.get_active_log(analyze.analyze(document.parse(log_lines)))
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

  local function run(lines, needle, alias)
    local result, err = map_summary.run(lines, row_of(lines, needle), alias)
    if not result then
      return nil, err
    end
    return apply(lines, result)
  end

  -- Map over the [needle1, needle2] line range -- what a visual selection sends.
  local function run_range(lines, needle1, needle2, alias)
    local result, err =
      map_summary.run_range(lines, row_of(lines, needle1), row_of(lines, needle2), alias)
    if not result then
      return nil, err
    end
    return apply(lines, result)
  end

  t.test("maps a single entry, regrouping just it", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 fix login",
      "09:30 more work",
      "10:00 done",
    })

    local out = run(lines, "09:00 fix login", "BUG-1")

    t.ok(has(out, "09:00 fix login => BUG-1"), "entry carries the alias")
    t.ok(has(out, "09:30 more work"), "the other entry is untouched")
    t.ok(has(out, "0:30 (+0m) BUG-1"), "the summary labels it by the alias")
    t.ok(has(out, "0:30 (+0m) more work"), "the other activity is unchanged")
  end)

  t.test("maps every entry of a summary row in bulk", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 standup",
      "09:15 standup",
      "09:30 done",
    })

    local out = run(lines, "(+0m) standup", "MEETING-1")

    t.ok(has(out, "09:00 standup => MEETING-1"), "first entry mapped")
    t.ok(has(out, "09:15 standup => MEETING-1"), "second entry mapped")
    t.ok(has(out, "0:30 (+0m) MEETING-1"), "the row merges under the alias")
  end)

  t.test("maps some entries of an activity and not others", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 review",
      "09:30 review",
      "10:00 done",
    })

    -- Map only the first of the two `review` entries.
    local out = run(lines, "09:00 review", "PR-1")

    t.ok(has(out, "09:00 review => PR-1"), "the first entry is mapped")
    t.ok(has(out, "09:30 review"), "the second keeps its plain description")
    t.ok(has(out, "0:30 (+0m) PR-1"), "the mapped half counts toward the alias")
    t.ok(has(out, "0:30 (+0m) review"), "the unmapped half stays under the description")
  end)

  t.test("merges different descriptions under one alias", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 fix login",
      "09:30 chase timeout",
      "10:00 done",
    })

    local mapped = run(lines, "09:00 fix login", "TICKET-1")
    mapped = run(mapped, "09:30 chase timeout", "TICKET-1")

    t.ok(has(mapped, "09:00 fix login => TICKET-1"), "first description kept, mapped")
    t.ok(has(mapped, "09:30 chase timeout => TICKET-1"), "second description kept, mapped")
    t.ok(has(mapped, "1:00 (+0m) TICKET-1"), "both sum into one alias row")
  end)

  t.test("mapping keeps the entry's trailing metadata", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 fix login #ClientA",
      "09:30 done",
    })

    local out = run(lines, "09:00 fix login", "BUG-1 Login")

    -- The alias sits before the tag, which still attaches to the entry (and its row).
    t.ok(has(out, "09:00 fix login => BUG-1 Login #ClientA"), "alias precedes the tag")
    t.ok(has(out, "0:30 (+0m) BUG-1 Login"), "the row is labeled by the alias")
  end)

  t.test("clears a mapping with an empty value", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 fix login => BUG-1",
      "09:30 done",
    })

    local out = run(lines, "09:00 fix login", "")

    t.ok(has(out, "09:00 fix login"), "the alias is removed from the entry")
    t.ok(not has(out, "09:00 fix login => BUG-1"), "the alias token is gone")
    t.ok(has(out, "0:30 (+0m) fix login"), "the summary falls back to the description")
  end)

  t.test("refuses to map a logged entry", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 fix login !S30",
      "09:30 done",
    })

    local _, err = run(lines, "09:00 fix login", "BUG-1")

    t.eq(err, map_summary.REFUSE_LOGGED)
  end)

  t.test("rejects a cursor that is not on an entry or summary row", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 fix login",
      "09:30 done",
    })

    local _, err = map_summary.run(lines, 1, "BUG-1")

    t.eq(err, map_summary.NOT_MAPPABLE)
  end)

  t.test("maps the closing entry when it shares the row's activity", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 standup",
      "09:15 standup",
      "09:30 standup", -- the closing entry: starts no interval, but is still "standup"
    })

    local out = run(lines, "(+0m) standup", "MEETING-1")

    t.ok(has(out, "09:00 standup => MEETING-1"), "first entry mapped")
    t.ok(has(out, "09:15 standup => MEETING-1"), "second entry mapped")
    t.ok(has(out, "09:30 standup => MEETING-1"), "the closing entry is mapped too")
  end)

  t.test("leaves a closing entry that belongs to a different row unmapped", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "08:00 sync #teamA",
      "09:00 sync",
      "10:00 sync #teamB", -- closing: same text, different tag -> a different row
    })

    local out = run(lines, "(+0m) sync", "SYNC-1")

    t.ok(has(out, "08:00 sync => SYNC-1 #teamA"), "the teamA entries are mapped")
    t.ok(has(out, "09:00 sync => SYNC-1"), "the inheriting teamA entry is mapped")
    t.ok(has(out, "10:00 sync #teamB"), "the differently-tagged closing entry is untouched")
  end)

  t.test("maps every entry in a visual range, folding them under one alias", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 fix login",
      "09:30 chase timeout",
      "10:00 write tests",
      "10:30 done",
    })

    -- Three working entries with different descriptions, mapped in one selection.
    local out = run_range(lines, "09:00 fix login", "10:00 write tests", "TICKET-1")

    t.ok(has(out, "09:00 fix login => TICKET-1"), "first entry mapped")
    t.ok(has(out, "09:30 chase timeout => TICKET-1"), "second entry mapped")
    t.ok(has(out, "10:00 write tests => TICKET-1"), "third entry mapped")
    t.ok(has(out, "1:30 (+0m) TICKET-1"), "all three fold into one alias row")
    t.ok(has(out, "10:30 done"), "the closing entry below the range is untouched")
  end)

  t.test("clears every mapping in a visual range", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 fix login => BUG-1",
      "09:30 chase timeout => BUG-1",
      "10:00 done",
    })

    local out = run_range(lines, "09:00 fix login", "09:30 chase timeout", "")

    t.ok(has(out, "09:00 fix login"), "first alias cleared")
    t.ok(has(out, "09:30 chase timeout"), "second alias cleared")
    t.ok(not has(out, "09:00 fix login => BUG-1"), "no alias token remains")
  end)

  t.test("refuses the whole range when any selected entry is logged", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 fix login",
      "09:30 deploy !S30",
      "10:00 done",
    })

    local _, err = run_range(lines, "09:00 fix login", "09:30 deploy", "BUG-1")

    t.eq(err, map_summary.REFUSE_LOGGED)
  end)

  t.test("a ranged map leaves an entry mapped onto its own description bare", function()
    -- The visual-selection case: map a span of items onto one of them (=> c); that one is a no-op
    -- (a bare row and `c => c` resolve identically), so it stays bare while the rest carry the alias.
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "08:00 a",
      "09:00 b",
      "10:00 c",
      "11:00 d",
      "12:00 done",
    })

    local out = run_range(lines, "08:00 a", "11:00 d", "c")

    t.ok(has(out, "08:00 a => c"), "a mapped")
    t.ok(has(out, "09:00 b => c"), "b mapped")
    t.ok(has(out, "10:00 c"), "c stays bare")
    t.ok(not has(out, "10:00 c => c"), "no redundant self-mapping alias is written")
    t.ok(has(out, "11:00 d => c"), "d mapped")
  end)

  t.test("mapping an aliased entry onto its own description clears the alias", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 x => y",
      "09:30 done",
    })

    local out = run(lines, "09:00 x", "x")

    t.ok(has(out, "09:00 x"), "the alias is cleared, leaving the entry bare")
    t.ok(not has(out, "09:00 x => y"), "the old alias is gone")
    t.ok(not has(out, "09:00 x => x"), "no redundant self-mapping alias is written")
  end)

  t.test("mapping a bare entry onto its own description makes no edit", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 c",
      "09:30 done",
    })

    local result = map_summary.run(lines, row_of(lines, "09:00 c"), "c")
    t.eq(#result.edits, 0)
  end)

  t.test("ignores non-entry lines in a range, mapping only the entries", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 alpha",
      "09:30 beta",
      "10:00 gamma",
      "10:30 done",
    })

    -- From the header line down through gamma: the header is ignored, the three working
    -- entries map, and the closing "done" below the range is left alone.
    local out = run_range(lines, "--- log q=1", "10:00 gamma", "WORK-1")

    t.ok(has(out, "09:00 alpha => WORK-1"), "alpha mapped")
    t.ok(has(out, "09:30 beta => WORK-1"), "beta mapped")
    t.ok(has(out, "10:00 gamma => WORK-1"), "gamma mapped")
    t.ok(has(out, "10:30 done"), "the closing entry below the range is untouched")
    t.ok(has(out, "1:30 (+0m) WORK-1"), "the three fold under the alias")
  end)

  t.test("maps a range of summary rows, folding them under one alias", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 fix login",
      "09:30 chase timeout",
      "10:00 write tests",
      "10:30 done",
    })

    -- Select from the first summary item row through the third -- a selection in the summary,
    -- not the body. Each row expands to its entry, and they all collapse to the new label.
    local out = run_range(lines, "(+0m) fix login", "(+0m) write tests", "TICKET-1")

    t.ok(has(out, "09:00 fix login => TICKET-1"), "first activity's entry mapped")
    t.ok(has(out, "09:30 chase timeout => TICKET-1"), "second activity's entry mapped")
    t.ok(has(out, "10:00 write tests => TICKET-1"), "third activity's entry mapped")
    t.ok(has(out, "1:30 (+0m) TICKET-1"), "the three summary rows fold into one")
  end)

  t.test("maps a range of summary rows with several entries each", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 standup",
      "09:15 standup",
      "09:30 review",
      "09:45 review",
      "10:00 done",
    })

    -- Two summary rows, each fed by two entries; selecting both folds all four contributors.
    local out = run_range(lines, "(+0m) standup", "(+0m) review", "SPRINT-7")

    t.ok(has(out, "09:00 standup => SPRINT-7"), "first standup mapped")
    t.ok(has(out, "09:15 standup => SPRINT-7"), "second standup mapped")
    t.ok(has(out, "09:30 review => SPRINT-7"), "first review mapped")
    t.ok(has(out, "09:45 review => SPRINT-7"), "second review mapped")
    t.ok(has(out, "1:00 (+0m) SPRINT-7"), "all four fold into one row")
  end)

  t.test("skips blanks, headers and totals inside a summary-row selection", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 alpha",
      "09:30 beta",
      "10:00 done",
    })

    -- Select from the first summary item line clear through the workday total: the blank, the
    -- "--- totals ---" header and the total line in between are skipped, not a STALE refusal.
    local out = run_range(lines, "(+0m) alpha", "workday", "WORK-1")

    t.ok(has(out, "09:00 alpha => WORK-1"), "alpha mapped")
    t.ok(has(out, "09:30 beta => WORK-1"), "beta mapped")
    t.ok(has(out, "1:00 (+0m) WORK-1"), "the items fold under the alias")
  end)

  t.test("maps cross-tag summary rows under one label without merging the tags", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 alpha #teamA",
      "09:30 beta #teamB",
      "10:00 done",
    })

    -- Both rows take the alias, but the tag is an independent grouping dimension, so they
    -- stay two rows that share the label rather than collapsing into one.
    local out = run_range(lines, "(+0m) alpha", "(+0m) beta", "Z")

    t.ok(has(out, "09:00 alpha => Z #teamA"), "first entry mapped, tag kept")
    t.ok(has(out, "09:30 beta => Z #teamB"), "second entry mapped, tag kept")
    t.ok(has(out, "0:30 (+0m) Z #teamA"), "one row for the teamA tag")
    t.ok(has(out, "0:30 (+0m) Z #teamB"), "a separate row for the teamB tag")
  end)

  t.test("clears every mapping across a range of summary rows", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 fix login => BUG-1",
      "09:30 chase timeout => BUG-2",
      "10:00 done",
    })

    -- Two distinct alias rows; selecting both and clearing drops both aliases.
    local out = run_range(lines, "(+0m) BUG-1", "(+0m) BUG-2", "")

    t.ok(has(out, "09:00 fix login"), "first alias cleared")
    t.ok(has(out, "09:30 chase timeout"), "second alias cleared")
    t.ok(not has(out, "09:00 fix login => BUG-1"), "no alias token remains")
  end)

  t.test("refuses a summary-row range when a contributing entry is logged", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 fix login !S30",
      "09:30 done",
    })

    -- The summary row's only contributor is logged, so the whole map is refused.
    local _, err = run_range(lines, "(+0m) fix login", "(+0m) fix login", "BUG-1")

    t.eq(err, map_summary.REFUSE_LOGGED)
  end)

  t.test("refuses a range that covers no mappable rows", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 alpha",
      "09:30 done",
    })

    -- A range over only the totals section -- its header and the workday total -- has no
    -- entry and no main summary row to map.
    local _, err = run_range(lines, "--- total", "workday", "X")

    t.eq(err, map_summary.NO_RANGE_ENTRIES)
  end)

  t.test("map refuses a blank entry (uncounted, no report identity)", function()
    local lines = { "--- log ---", "08:00 a", "11:00", "13:00 b", "14:00 done" }
    local _, err = map_summary.run(lines, 3, "label") -- cursor on the 11:00 blank
    t.eq(err, map_summary.REFUSE_BLANK)
  end)

  t.test("a ranged map skips a blank entry instead of refusing the selection", function()
    local lines = { "--- log ---", "08:00 a", "12:00", "13:00 b", "14:00 done" }
    local result = map_summary.run_range(lines, 2, 4, "TICKET") -- selection spans the lunch blank
    local out = apply(lines, result)
    t.eq(out[2], "08:00 a => TICKET")
    t.eq(out[3], "12:00") -- the blank is untouched
    t.eq(out[4], "13:00 b => TICKET")
  end)
end
