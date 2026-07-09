-- Pure tests for CSV/JSON export as a full projection of the generated summary block: one row per
-- (day, level) with the level's minutes, residual (unrounded + rounding error), logged state and
-- recipients. Covers RFC-4180 quoting, the formula-injection guard (text only), the partial-log split,
-- and that a negative error_minutes stays a bare number. (The command / file-write path is in
-- tests/daybook_commands.lua.)
return function(t)
  local week = require("daylog.week")
  local export = require("daylog.export")

  local function report(lines)
    return week.build_report({ { date_label = "2026-06-29", path = "a", lines = lines } })
  end

  -- A hand-built report for escaping/injection edge cases a real `.day` line can't hold (newlines etc.).
  -- Only activity_rows are supplied, so the export emits activity-level rows alone.
  local function synthetic(activity_rows)
    return { days = { { date_label = "2026-01-01", activity_rows = activity_rows } } }
  end

  local HEADER =
    "date,level,activity,tag,location,minutes,hours,unrounded_minutes,error_minutes,logged,logged_to"

  -- One day exercising: a partial log (build feature 120m, only 60m reported to ado+jira), an unlogged
  -- activity, the tag total reported to client, the workday reported, and a blank break (excluded).
  local RICH = {
    "--- log #ClientA @office q=30 ---",
    "09:00 standup !S[jira]30 !T[client]180 !W[]180",
    "09:30 build feature !S[jira,ado]60 !T[client]180 !W[]180",
    "10:30 build feature !T[client]180 !W[]180",
    "11:30",
    "12:00 email !T[client]180 !W[]180",
    "12:30 done",
  }

  t.test("export projects every summary-block level as a row, tagged by `level`", function()
    t.eq(
      export.csv(report(RICH)),
      table.concat({
        HEADER,
        "2026-06-29,activity,build feature,ClientA,office,60,1.00,60,0,false,",
        '2026-06-29,activity,build feature,ClientA,office,60,1.00,60,0,true,"ado,jira"',
        "2026-06-29,activity,email,ClientA,office,30,0.50,30,0,false,",
        "2026-06-29,activity,standup,ClientA,office,30,0.50,30,0,true,jira",
        "2026-06-29,tag,,ClientA,,180,3.00,180,0,true,client",
        "2026-06-29,location,,,office,180,3.00,180,0,false,",
        "2026-06-29,workday,,,,180,3.00,180,0,true,",
        "",
      }, "\n")
    )
  end)

  t.test(
    "the partial log is two rows (reported slice + unlogged remainder) and each level foots",
    function()
      local by = { activity = {}, tag = 0, location = 0, workday = 0 }
      for _, row in ipairs(vim.json.decode(export.json(report(RICH)))) do
        if row.level == "activity" then
          by.activity[#by.activity + 1] = row
        else
          by[row.level] = by[row.level] + row.minutes
        end
      end
      -- build feature split: 60m reported to ado+jira, 60m not.
      local logged, remainder
      for _, r in ipairs(by.activity) do
        if r.activity == "build feature" then
          if r.logged then
            logged = r
          else
            remainder = r
          end
        end
      end
      t.eq(logged.minutes, 60)
      t.eq(logged.logged_to, { "ado", "jira" })
      t.eq(remainder.minutes, 60)
      t.eq(remainder.logged_to, {})
      -- each level totals the same 180m counted day (the 30m break is excluded).
      t.eq(by.tag, 180)
      t.eq(by.location, 180)
      t.eq(by.workday, 180)
    end
  )

  t.test("residual columns carry real elapsed minutes and a signed rounding error", function()
    local resid =
      { "--- log #ClientA @office q=30 ---", "09:00 plan", "09:20 review", "09:55 done" }
    t.eq(
      export.csv(report(resid)),
      table.concat({
        HEADER,
        "2026-06-29,activity,plan,ClientA,office,30,0.50,20,-10,false,",
        "2026-06-29,activity,review,ClientA,office,30,0.50,35,5,false,",
        "2026-06-29,tag,,ClientA,,60,1.00,55,-5,false,",
        "2026-06-29,location,,,office,60,1.00,55,-5,false,",
        "2026-06-29,workday,,,,60,1.00,55,-5,false,",
        "",
      }, "\n")
    )
    -- The negative error_minutes stays a bare JSON number, not a quoted/guarded string.
    local plan = vim.json.decode(export.json(report(resid)))[1]
    t.eq(plan.minutes, 30)
    t.eq(plan.unrounded_minutes, 20)
    t.eq(plan.error_minutes, -10)
    t.eq(type(plan.error_minutes), "number")
  end)

  t.test("an activity at two locations is one activity row per location", function()
    local r =
      report({ "--- log q=15 ---", "08:00 coding @office", "09:00 coding @home", "10:00 done" })
    t.eq(
      export.csv(r),
      table.concat({
        HEADER,
        "2026-06-29,activity,coding,,home,60,1.00,60,0,false,",
        "2026-06-29,activity,coding,,office,60,1.00,60,0,false,",
        "2026-06-29,tag,,,,120,2.00,120,0,false,",
        "2026-06-29,location,,,home,60,1.00,60,0,false,",
        "2026-06-29,location,,,office,60,1.00,60,0,false,",
        "2026-06-29,workday,,,,120,2.00,120,0,false,",
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

  t.test("CSV neutralizes spreadsheet formula prefixes in text, but not in numbers", function()
    local csv = export.csv(synthetic({
      { text = "=cmd", tag = "", location = "", duration = 15, logged = false },
      { text = "-2h round", tag = "", location = "", duration = 15, logged = false },
      { text = "@ref", tag = "", location = "", duration = 15, logged = false },
      { text = "safe", tag = "", location = "", duration = 15, logged = false },
    }))
    for _, guarded in ipairs({ "'=cmd", "'-2h round", "'@ref" }) do
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

  t.test("rows are sorted by (date, level, activity, tag, location)", function()
    local rows = vim.json.decode(export.json({
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
    }))
    local order = {}
    for _, row in ipairs(rows) do
      order[#order + 1] = row.date .. "/" .. row.activity .. "/" .. row.tag
    end
    t.eq(order, { "2026-01-01/a/", "2026-01-01/b/x", "2026-01-01/b/y", "2026-01-02/z/" })
  end)

  t.test("export of an empty report is a header-only CSV and an empty JSON array", function()
    t.eq(export.csv({ days = {} }), HEADER .. "\n")
    t.eq(export.json({ days = {} }), "[]\n")
  end)
end
