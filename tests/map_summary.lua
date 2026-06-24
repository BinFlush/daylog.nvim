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
end
