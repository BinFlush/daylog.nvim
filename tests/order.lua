return function(t)
  local order = require("worklog.order")
  local parse = require("worklog.parse")

  local function parse_default(line)
    return parse.parse_time_line(line, "ProjectOrion")
  end

  t.test("parse items keeps preamble and normalizes trailing blank lines", function()
    local parsed = order.parse_items({
      "preamble",
      "17:00 later",
      "",
      "note later",
      "",
      "16:00 earlier",
      "",
      "",
      "",
    }, 10, parse_default)

    t.eq(parsed.preamble_lines, { "preamble" })
    t.eq(#parsed.items, 2)
    t.eq(parsed.items[1].minutes, 1020)
    t.eq(parsed.items[1].row, 11)
    t.eq(parsed.items[1].text, "later")
    t.eq(parsed.items[1].label, "ProjectOrion")
    t.eq(parsed.items[1].lines, {
      "17:00 later",
      "",
      "note later",
    })
    t.eq(parsed.items[2].lines, {
      "16:00 earlier",
    })
  end)

  t.test("parse items reports invalid worklog entries", function()
    local parsed = order.parse_items({
      "08:00 first",
      "08:30 second #sales #meeting",
    }, 20, parse_default)

    t.eq(parsed.error.row, 21)
    t.eq(parsed.error.message, "multiple trailing labels are not allowed")
  end)

  t.test("find unordered rows reports first decreasing pair", function()
    local parsed = order.parse_items({
      "08:30 later",
      "08:00 earlier",
      "09:00 done",
    }, 20, parse_default)

    t.eq({ order.find_unordered_rows(parsed.items) }, { 20, 21 })
  end)

  t.test("normalized lines preserve order while stripping item trailing blanks", function()
    local parsed = order.parse_items({
      "preamble",
      "08:00 first #ProjectOrion",
      "note a",
      "",
      "08:30 second #sales",
      "09:00",
      "",
    }, 1, parse_default)

    t.eq(order.normalized_lines(parsed, "ProjectOrion", parse.format_time_line), {
      "preamble",
      "08:00 first",
      "note a",
      "08:30 second #sales",
      "09:00",
    })
  end)

  t.test("sorted lines reorder items but keep attached lines", function()
    local parsed = order.parse_items({
      "preamble",
      "17:00 later #ProjectOrion",
      "",
      "note later",
      "",
      "16:00 earlier #sales",
    }, 1, parse_default)

    t.eq(order.sorted_lines(parsed, "ProjectOrion", parse.format_time_line), {
      "preamble",
      "16:00 earlier #sales",
      "17:00 later",
      "",
      "note later",
    })
  end)

  t.test("sorted lines preserve equal timestamp order", function()
    local parsed = order.parse_items({
      "08:00 first",
      "note a",
      "08:00 second #sales",
      "note b",
      "09:00 done",
    }, 1, parse_default)

    t.eq(order.sorted_lines(parsed, "ProjectOrion", parse.format_time_line), {
      "08:00 first",
      "note a",
      "08:00 second #sales",
      "note b",
      "09:00 done",
    })
  end)
end
