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
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "08:00 second",
      "09:00 done",
    })

    t.eq(body.insert_index(block, 480), 3)
    t.eq(body.insert_index(block, 510), 3)
  end)

  t.test("body state_before includes equal timestamp entries at insertion time", function()
    local block = block_from_lines({
      "--- worklog #ProjectOrion @office ---",
      "08:00 first #sales",
      "08:00 second @client",
      "09:00 done",
    })

    t.eq(body.state_before(block, 479), { tag = "ProjectOrion", location = "office" })
    t.eq(body.state_before(block, 480), { tag = "sales", location = "client" })
  end)

  t.test("body normalized lines keep preamble and trim trailing item blanks", function()
    local block = block_from_lines({
      "--- worklog #ProjectOrion @office ---",
      "preamble",
      "08:00 first #ProjectOrion @office",
      "note a",
      "",
      "08:30 second @client",
      "09:00 #sales",
      "",
    })

    t.eq(body.normalized_lines(block, entry.format), {
      "preamble",
      "08:00 first",
      "note a",
      "08:30 second @client",
      "09:00 #sales",
    })
  end)

  t.test("body sorted lines reorder items and re-emit sticky metadata changes", function()
    local block = block_from_lines({
      "--- worklog #ProjectOrion @office ---",
      "preamble",
      "17:00 later @client",
      "",
      "note later",
      "",
      "16:00 earlier #sales",
    })

    t.eq(body.sorted_lines(block, entry.format), {
      "preamble",
      "16:00 earlier #sales @client",
      "17:00 later #ProjectOrion",
      "",
      "note later",
    })
  end)

  t.test("body sorted lines preserve equal timestamp order", function()
    local block = block_from_lines({
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "note a",
      "08:00 second @client",
      "note b",
      "09:00 done",
    })

    t.eq(body.sorted_lines(block, entry.format), {
      "08:00 first",
      "note a",
      "08:00 second @client",
      "note b",
      "09:00 done",
    })
  end)

  t.test("body sorted lines emit clear tokens when needed", function()
    local block = block_from_lines({
      "--- worklog ---",
      "09:00 done",
      "08:00 plan #sales @client",
    })

    t.eq(body.sorted_lines(block, entry.format), {
      "08:00 plan #sales @client",
      "09:00 done #- @-",
    })
  end)
end
