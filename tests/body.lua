return function(t)
  local analyze = require("worklog.analyze")
  local body = require("worklog.body")
  local document = require("worklog.document")
  local entry = require("worklog.entry")

  local function block_from_lines(lines)
    local analysis = analyze.analyze(document.parse(lines))
    return analysis.worklog_blocks[1]
  end

  t.test("body insert index places new entries after equal timestamps", function()
    local block = block_from_lines({
      "--- worklog default=#ProjectOrion ---",
      "08:00 first",
      "08:00 second",
      "09:00 done",
    })

    t.eq(body.insert_index(block, 480), 3)
    t.eq(body.insert_index(block, 510), 3)
  end)

  t.test("body normalized lines keep preamble and trim trailing item blanks", function()
    local block = block_from_lines({
      "--- worklog default=#ProjectOrion ---",
      "preamble",
      "08:00 first #ProjectOrion",
      "note a",
      "",
      "08:30 second #sales",
      "09:00",
      "",
    })

    t.eq(body.normalized_lines(block, "ProjectOrion", entry.format), {
      "preamble",
      "08:00 first",
      "note a",
      "08:30 second #sales",
      "09:00",
    })
  end)

  t.test("body sorted lines reorder items but preserve attached note lines", function()
    local block = block_from_lines({
      "--- worklog default=#ProjectOrion ---",
      "preamble",
      "17:00 later #ProjectOrion",
      "",
      "note later",
      "",
      "16:00 earlier #sales",
    })

    t.eq(body.sorted_lines(block, "ProjectOrion", entry.format), {
      "preamble",
      "16:00 earlier #sales",
      "17:00 later",
      "",
      "note later",
    })
  end)

  t.test("body sorted lines preserve equal timestamp order", function()
    local block = block_from_lines({
      "--- worklog default=#ProjectOrion ---",
      "08:00 first",
      "note a",
      "08:00 second #sales",
      "note b",
      "09:00 done",
    })

    t.eq(body.sorted_lines(block, "ProjectOrion", entry.format), {
      "08:00 first",
      "note a",
      "08:00 second #sales",
      "note b",
      "09:00 done",
    })
  end)
end
