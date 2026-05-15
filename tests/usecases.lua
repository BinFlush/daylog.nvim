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
      "--- worklog @office ---",
      "08:00 plan",
      "08:30 call #sales @client",
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
            "0.50h plan @office",
            "0.50h call #sales @client",
            "",
            "--- tags exact ---",
            "0.50h (untagged)",
            "0.50h #sales",
            "",
            "--- locations exact ---",
            "0.50h @office",
            "0.50h @client",
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
      "--- worklog #ProjectOrion ---",
      "08:30 later",
      "08:00 earlier #sales",
      "09:00 done #ProjectOrion",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 1,
          end_index = 4,
          lines = {
            "08:00 earlier #sales",
            "08:30 later #ProjectOrion",
            "09:00 done",
          },
        },
      },
    })
  end)
end
