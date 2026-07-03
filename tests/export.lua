-- Pure tests for CSV/JSON export of a multi-day report: the same per-day summary items the report
-- shows, flattened to one row per (day, activity, tag), with RFC-4180 CSV quoting and a JSON encoding
-- whose numbers stay numbers. (The :Daylog export command path is exercised by hand.)
return function(t)
  local week = require("daylog.week")
  local export = require("daylog.export")

  -- Two days: a comma in an activity (quoting), a `!S` logged row, an ordinary `#ooo` tag row (now
  -- counted like any tag), and a second day at a different q=, so quantized minutes flow straight
  -- through.
  local function sample_report()
    return week.build_report({
      {
        date_label = "2026-06-29",
        path = "a",
        lines = {
          "--- log #ClientA q=30 ---",
          "08:00 plan, design",
          "09:30 review !S",
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

  t.test("export.csv renders one quantized row per activity, RFC-4180 quoted", function()
    t.eq(
      export.csv(sample_report()),
      table.concat({
        "date,activity,tag,minutes,hours,logged",
        '2026-06-29,"plan, design",ClientA,90,1.50,false',
        "2026-06-29,review,ClientA,60,1.00,true",
        "2026-06-29,lunch,ooo,30,0.50,false",
        "2026-06-30,standup,ClientB,30,0.50,false",
        "",
      }, "\n")
    )
  end)

  t.test("export.json decodes to the same rows, with numbers and booleans (not strings)", function()
    local rows = vim.json.decode(export.json(sample_report()))
    t.eq(rows, {
      {
        date = "2026-06-29",
        activity = "plan, design",
        tag = "ClientA",
        minutes = 90,
        hours = 1.5,
        logged = false,
      },
      {
        date = "2026-06-29",
        activity = "review",
        tag = "ClientA",
        minutes = 60,
        hours = 1.0,
        logged = true,
      },
      {
        date = "2026-06-29",
        activity = "lunch",
        tag = "ooo",
        minutes = 30,
        hours = 0.5,
        logged = false,
      },
      {
        date = "2026-06-30",
        activity = "standup",
        tag = "ClientB",
        minutes = 30,
        hours = 0.5,
        logged = false,
      },
    })
    t.eq(type(rows[1].minutes), "number")
    t.eq(type(rows[1].hours), "number")
    t.eq(type(rows[2].logged), "boolean")
  end)

  t.test("export of an empty report is a header-only CSV and an empty JSON array", function()
    t.eq(export.csv({ days = {} }), "date,activity,tag,minutes,hours,logged\n")
    t.eq(export.json({ days = {} }), "[]\n")
  end)
end
