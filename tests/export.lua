-- Pure tests for CSV/JSON export of a multi-day report: one row per (day, activity, tag, location),
-- sorted deterministically, with RFC-4180 CSV quoting + formula-injection guarding and a JSON encoding
-- whose numbers stay numbers. (The :Daylog export command / file-write path is exercised in
-- tests/daybook_commands.lua.)
return function(t)
  local week = require("daylog.week")
  local export = require("daylog.export")

  -- Two days: a comma in an activity (quoting), a `!S[]` logged row, an ordinary `#ooo` tag row, and a
  -- second day at a different q=, so quantized minutes flow straight through. No locations here.
  local function sample_report()
    return week.build_report({
      {
        date_label = "2026-06-29",
        path = "a",
        lines = {
          "--- log #ClientA q=30 ---",
          "08:00 plan, design",
          "09:30 review !S[]",
          "10:30 lunch #ooo",
          "11:00 done",
        },
      },
      {
        date_label = "2026-06-30",
        path = "b",
        lines = { "--- log #ClientB q=15 ---", "09:00 standup", "09:30 done" },
      },
    })
  end

  -- A hand-built report for escaping/injection edge cases a real `.day` line can't hold (newlines etc.).
  local function synthetic(activity_rows)
    return { days = { { date_label = "2026-01-01", activity_rows = activity_rows } } }
  end

  t.test("export.csv renders one sorted, quantized row per activity, RFC-4180 quoted", function()
    t.eq(
      export.csv(sample_report()),
      table.concat({
        "date,activity,tag,location,minutes,hours,logged",
        "2026-06-29,lunch,ooo,,30,0.50,false",
        '2026-06-29,"plan, design",ClientA,,90,1.50,false',
        "2026-06-29,review,ClientA,,60,1.00,true",
        "2026-06-30,standup,ClientB,,30,0.50,false",
        "",
      }, "\n")
    )
  end)

  t.test("export.json decodes to the same rows, with numbers and booleans (not strings)", function()
    local rows = vim.json.decode(export.json(sample_report()))
    t.eq(rows, {
      {
        date = "2026-06-29",
        activity = "lunch",
        tag = "ooo",
        location = "",
        minutes = 30,
        hours = 0.5,
        logged = false,
      },
      {
        date = "2026-06-29",
        activity = "plan, design",
        tag = "ClientA",
        location = "",
        minutes = 90,
        hours = 1.5,
        logged = false,
      },
      {
        date = "2026-06-29",
        activity = "review",
        tag = "ClientA",
        location = "",
        minutes = 60,
        hours = 1.0,
        logged = true,
      },
      {
        date = "2026-06-30",
        activity = "standup",
        tag = "ClientB",
        location = "",
        minutes = 30,
        hours = 0.5,
        logged = false,
      },
    })
    t.eq(type(rows[1].minutes), "number")
    t.eq(type(rows[1].hours), "number")
    t.eq(type(rows[3].logged), "boolean")
  end)

  t.test("an activity at two locations exports one row per location", function()
    local report = week.build_report({
      {
        date_label = "2026-06-29",
        path = "a",
        lines = { "--- log q=15 ---", "08:00 coding @office", "09:00 coding @home", "10:00 done" },
      },
    })
    t.eq(
      export.csv(report),
      table.concat({
        "date,activity,tag,location,minutes,hours,logged",
        "2026-06-29,coding,,home,60,1.00,false",
        "2026-06-29,coding,,office,60,1.00,false",
        "",
      }, "\n")
    )
  end)

  t.test("CSV quotes commas, quotes, newlines and CRs (RFC 4180)", function()
    local csv = export.csv(synthetic({
      { text = 'a, "b"', tag = "t", location = "l", duration = 15, logged = false },
      { text = "line1\nline2", tag = "u", location = "m", duration = 15, logged = false },
      { text = "cr\rhere", tag = "v", location = "n", duration = 15, logged = false },
    }))
    t.ok(csv:find('"a, ""b"""', 1, true) ~= nil, "comma + doubled quotes")
    t.ok(csv:find('"line1\nline2"', 1, true) ~= nil, "embedded newline is quoted")
    t.ok(csv:find('"cr\rhere"', 1, true) ~= nil, "embedded CR is quoted")
  end)

  t.test("CSV neutralizes spreadsheet formula prefixes", function()
    local csv = export.csv(synthetic({
      { text = "=cmd", tag = "", location = "", duration = 15, logged = false },
      { text = "+1", tag = "", location = "", duration = 15, logged = false },
      { text = "-2h round", tag = "", location = "", duration = 15, logged = false },
      { text = "@ref", tag = "", location = "", duration = 15, logged = false },
      { text = "safe", tag = "", location = "", duration = 15, logged = false },
    }))
    for _, guarded in ipairs({ "'=cmd", "'+1", "'-2h round", "'@ref" }) do
      t.ok(csv:find(guarded, 1, true) ~= nil, "formula prefix guarded: " .. guarded)
    end
    t.ok(csv:find(",safe,", 1, true) ~= nil, "ordinary text is untouched")
  end)

  t.test("JSON escapes quotes, backslashes, and control characters", function()
    local rows = vim.json.decode(export.json(synthetic({
      { text = 'q"\\b\tt\nn', tag = "", location = "", duration = 15, logged = false },
    })))
    t.eq(rows[1].activity, 'q"\\b\tt\nn') -- round-trips through the hand-rolled escaper
  end)

  t.test("rows are sorted by (date, activity, tag, location)", function()
    local csv = export.csv({
      days = {
        {
          date_label = "2026-01-02",
          activity_rows = { { text = "z", tag = "", location = "", duration = 15, logged = false } },
        },
        {
          date_label = "2026-01-01",
          activity_rows = {
            { text = "b", tag = "y", location = "q", duration = 15, logged = false },
            { text = "a", tag = "", location = "", duration = 15, logged = false },
            { text = "b", tag = "x", location = "q", duration = 15, logged = false },
          },
        },
      },
    })
    local order = {}
    for line in csv:gmatch("[^\n]+") do
      local d, a, tag = line:match("^(%d[%d%-]+),([^,]*),([^,]*)")
      if d then
        order[#order + 1] = d .. "/" .. a .. "/" .. tag
      end
    end
    t.eq(order, { "2026-01-01/a/", "2026-01-01/b/x", "2026-01-01/b/y", "2026-01-02/z/" })
  end)

  t.test("export of an empty report is a header-only CSV and an empty JSON array", function()
    t.eq(export.csv({ days = {} }), "date,activity,tag,location,minutes,hours,logged\n")
    t.eq(export.json({ days = {} }), "[]\n")
  end)
end
