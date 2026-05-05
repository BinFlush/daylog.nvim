return function(t)
  local blocks = require("worklog.blocks")

  t.test("parse explicit worklog blocks and default label", function()
    local parsed = blocks.parse({
      "--- worklog default=#ProjectOrion ---",
      "08:00 raw",
      "09:00",
      "",
      "--- summary exact ---",
      "1.00h raw",
      "",
      "--- worklog ---",
      "10:00 tea",
      "11:00",
      "",
      "--- totals exact ---",
      "1.00h activity",
    })

    t.eq(parsed.default_label, "ProjectOrion")
    t.eq(#parsed, 4)
    t.eq(parsed[1].header, "--- worklog default=#ProjectOrion ---")
    t.eq(parsed[1].body_start_row, 2)
    t.eq(parsed[1].end_row, 5)
    t.eq(parsed[3].header, "--- worklog ---")
    t.eq(parsed[3].body_start_row, 9)
    t.eq(parsed[3].end_row, 12)
  end)

  t.test("worklog helpers identify active and cursor local worklogs", function()
    local parsed = blocks.parse({
      "--- worklog default=#ProjectOrion ---",
      "08:00 raw",
      "09:00",
      "",
      "--- summary exact ---",
      "1.00h raw",
      "",
      "--- worklog ---",
      "10:00 tea",
      "11:00",
    })

    t.ok(blocks.is_worklog(parsed[1]))
    t.ok(blocks.is_worklog(parsed[3]))
    t.ok(not blocks.is_worklog(parsed[2]))
    t.eq(blocks.get_active_worklog(parsed), parsed[3])
    t.eq(blocks.get_worklog_at_row(parsed, 2), parsed[1])
    t.eq(blocks.get_worklog_at_row(parsed, 9), parsed[3])
    t.eq(blocks.get_worklog_at_row(parsed, 5), nil)
  end)

  t.test("body extraction and insert index", function()
    local lines = {
      "--- worklog default=#ProjectOrion ---",
      "08:00 raw",
      "09:00",
      "",
      "--- worklog ---",
      "10:00 tea",
      "11:00",
      "",
      "--- totals exact ---",
      "1.00h activity",
    }
    local parsed = blocks.parse(lines)
    local body = blocks.get_body_lines(lines, parsed[2])

    t.eq(body, {
      "10:00 tea",
      "11:00",
      "",
    })
    t.eq(blocks.get_insert_index(parsed[2]), 8)
  end)

  t.test("invalid first header reports parse error", function()
    local parsed = blocks.parse({
      "--- worklog ---",
      "08:00 raw",
      "09:00",
    })

    t.eq(parsed.error, "worklog: first line must be --- worklog default=#label ---")
  end)

  t.test("later worklog headers may not redeclare default label", function()
    local parsed = blocks.parse({
      "--- worklog default=#ProjectOrion ---",
      "08:00 raw",
      "09:00",
      "--- worklog default=#sales ---",
      "10:00 tea",
      "11:00",
    })

    t.eq(parsed.error, "worklog: only the first worklog header may declare a default label")
  end)

  t.test("trim empty lines removes leading and trailing blanks", function()
    local trimmed = blocks.trim_empty_lines({
      "",
      "",
      "08:00 raw",
      "09:00",
      "",
      "",
    })

    t.eq(trimmed, {
      "08:00 raw",
      "09:00",
    })
  end)
end
