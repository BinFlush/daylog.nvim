return function(t)
  local analyze = require("blotter.analyze")
  local body = require("blotter.body")
  local document = require("blotter.document")
  local blot = require("blotter.blot")

  local function block_from_lines(lines)
    local analysis = analyze.analyze(document.parse(lines))
    return analysis.worklog_blocks[1]
  end

  t.test("body insert index places new blots after equal timestamps", function()
    local block = block_from_lines({
      "--- blots #ProjectOrion @office ---",
      "08:00 first",
      "08:00 second",
      "09:00 done",
    })

    t.eq(body.insert_index(block, 480), 3)
    t.eq(body.insert_index(block, 510), 3)
  end)

  t.test("body state_before includes equal timestamp blots at insertion time", function()
    local block = block_from_lines({
      "--- blots #ProjectOrion @office ---",
      "08:00 first #sales",
      "08:00 second @client",
      "09:00 done",
    })

    t.eq(body.state_before(block, 479), { tag = "ProjectOrion", location = "office" })
    t.eq(body.state_before(block, 480), { tag = "sales", location = "client" })
  end)

  t.test("body normalized lines keep preamble and trim trailing item blanks", function()
    local block = block_from_lines({
      "--- blots #ProjectOrion @office ---",
      "preamble",
      "08:00 first #ProjectOrion @office",
      "note a",
      "",
      "08:30 second @client",
      "09:00 #sales",
      "",
    })

    t.eq(body.normalized_lines(block, blot.format), {
      "preamble",
      "08:00 first",
      "note a",
      "08:30 second @client",
      "09:00 #sales",
    })
  end)

  t.test("body normalized lines preserve !L and canonicalize it after metadata", function()
    local block = block_from_lines({
      "--- blots #ProjectOrion @office ---",
      "08:00 first !L #sales",
      "09:00 done !L",
    })

    t.eq(body.normalized_lines(block, blot.format), {
      "08:00 first #sales !L",
      "09:00 done !L",
    })
  end)

  t.test("body sorted lines reorder items and re-emit sticky metadata changes", function()
    local block = block_from_lines({
      "--- blots #ProjectOrion @office ---",
      "preamble",
      "17:00 later @client",
      "",
      "note later",
      "",
      "16:00 earlier #sales",
    })

    t.eq(body.sorted_lines(block, blot.format), {
      "preamble",
      "16:00 earlier #sales @client",
      "17:00 later #ProjectOrion",
      "",
      "note later",
    })
  end)

  t.test("body sorted lines preserve equal timestamp order", function()
    local block = block_from_lines({
      "--- blots #ProjectOrion @office ---",
      "08:00 first",
      "note a",
      "08:00 second @client",
      "note b",
      "09:00 done",
    })

    t.eq(body.sorted_lines(block, blot.format), {
      "08:00 first",
      "note a",
      "08:00 second @client",
      "note b",
      "09:00 done",
    })
  end)

  t.test("body sorted lines emit clear tokens when needed", function()
    local block = block_from_lines({
      "--- blots ---",
      "09:00 done",
      "08:00 plan #sales @client",
    })

    t.eq(body.sorted_lines(block, blot.format), {
      "08:00 plan #sales @client",
      "09:00 done #- @-",
    })
  end)

  t.test("body normalized lines keep the header offset base and re-emit changes", function()
    -- The base lives on the header, so the first blot inherits it silently and only
    -- the mid-day change re-emits a utc token -- a copy is byte-identical to input.
    local block = block_from_lines({
      "--- blots utc+2 ---",
      "08:00 standup",
      "11:00 resume utc-4",
      "12:00 done",
    })

    t.eq(body.normalized_lines(block, blot.format), {
      "08:00 standup",
      "11:00 resume utc-4",
      "12:00 done",
    })
  end)

  t.test("body sorted lines order by effective UTC time, not the raw clock", function()
    -- a@-4 = 15:00Z, b@+2 = 10:00Z: by the raw clock a (11:00) precedes b (12:00),
    -- but in real time b is earlier, so sorting puts b first and re-emits each offset
    -- on change. The displayed local clock can then read high-to-low because the
    -- blots are ordered by real time, which is what the duration math uses.
    local block = block_from_lines({
      "--- blots utc-4 ---",
      "11:00 a",
      "12:00 b utc+2",
    })

    t.eq(body.sorted_lines(block, blot.format), {
      "12:00 b utc+2",
      "11:00 a utc-4",
    })
  end)

  t.test("body sort_changes_metadata flags an blot whose inherited offset would change", function()
    -- Sorted by effective time the order becomes b, a; a (no explicit offset) would
    -- then inherit a different offset than it did in buffer order, so it is reported
    -- on the same channel as a tag/location change.
    local block = block_from_lines({
      "--- blots utc-4 ---",
      "11:00 a",
      "12:00 b utc+2",
    })

    t.eq(body.sort_changes_metadata(block), { { minutes = 660, text = "a" } })
  end)
end
