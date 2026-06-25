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
    for _, line in
      ipairs(render.summary_lines(summary.summarize_block(block), block.duration_format, {
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
      "09:00 fix login !L30",
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
      "09:30 deploy !L30",
      "10:00 done",
    })

    local _, err = run_range(lines, "09:00 fix login", "09:30 deploy", "BUG-1")

    t.eq(err, map_summary.REFUSE_LOGGED)
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

  t.test("refuses a range that covers no entries", function()
    local lines = buffer_with_summary({
      "--- log q=1 d=hm ---",
      "09:00 alpha",
      "09:30 done",
    })

    -- A range over only the generated summary row touches no entries.
    local _, err = run_range(lines, "(+0m) alpha", "(+0m) alpha", "X")

    t.eq(err, map_summary.NO_RANGE_ENTRIES)
  end)
end
