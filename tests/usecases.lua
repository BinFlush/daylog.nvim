return function(t)
  local append_summary = require("worklog.usecases.append_summary")
  local insert_now = require("worklog.usecases.insert_now")
  local order_worklogs = require("worklog.usecases.order_worklogs")

  t.test("insert_now usecase returns an edit script and cursor action", function()
    local result = insert_now.run({
      "--- worklog ---",
      "08:00 first",
      "09:00 done",
    }, 1, "08:30")

    t.eq(result, {
      edits = {
        {
          start_index = 2,
          end_index = 2,
          lines = { "08:30 " },
        },
      },
      cursor = { 3, 6 },
      startinsert = true,
    })
  end)

  t.test("append_summary usecase returns appended summary lines", function()
    local result = append_summary.run({
      "--- worklog ---",
      "08:00 plan",
      "08:30 call #sales",
      "09:00 done",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 4,
          end_index = 4,
          lines = {
            "",
            "--- summary exact ---",
            "0.50h plan",
            "0.50h call #sales",
            "",
            "--- labels exact ---",
            "0.50h (unlabeled)",
            "0.50h #sales",
            "",
            "--- totals exact ---",
            "1.00h activity",
            "1.00h workday",
          },
        },
      },
    })
  end)

  t.test("order_worklogs usecase returns replace edits for worklog bodies", function()
    local result = order_worklogs.run({
      "--- worklog default=#ProjectOrion ---",
      "08:30 later",
      "08:00 earlier",
      "09:00 done",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 1,
          end_index = 4,
          lines = {
            "08:00 earlier",
            "08:30 later",
            "09:00 done",
          },
        },
      },
    })
  end)
end
