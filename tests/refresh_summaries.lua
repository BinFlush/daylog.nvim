return function(t)
  local refresh_summaries = require("worklog.usecases.refresh_summaries")

  t.test("refresh rewrites a stale summary in place", function()
    local result = refresh_summaries.run({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary exact ---",
      "0.50h plan",
      "",
      "--- totals exact ---",
      "0.50h workday",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 4,
          end_index = 9,
          lines = {
            "--- summary exact ---",
            "1.00h plan",
            "",
            "--- totals exact ---",
            "1.00h workday",
          },
        },
      },
    })
  end)

  t.test("refresh is a no-op when the summary is already current", function()
    local result = refresh_summaries.run({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h plan",
      "",
      "--- totals exact ---",
      "1.00h workday",
    })

    t.eq(result, { edits = {} })
  end)

  t.test("refresh updates only the changed worklog among several", function()
    local result = refresh_summaries.run({
      "--- worklog ---",
      "08:00 a",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h a",
      "",
      "--- totals exact ---",
      "1.00h workday",
      "",
      "--- worklog ---",
      "10:00 b",
      "11:30 done",
      "",
      "--- summary exact ---",
      "0.50h b",
      "",
      "--- totals exact ---",
      "0.50h workday",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 14,
          end_index = 19,
          lines = {
            "--- summary exact ---",
            "1.50h b",
            "",
            "--- totals exact ---",
            "1.50h workday",
          },
        },
      },
    })
  end)

  t.test("refresh preserves the summary kind", function()
    local result = refresh_summaries.run({
      "--- worklog quantize=30 ---",
      "08:00 plan",
      "08:34 done",
      "",
      "--- summary quantized ---",
      "1.00h (+0m) plan",
      "",
      "--- totals quantized ---",
      "1.00h (+0m) workday",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 4,
          end_index = 9,
          lines = {
            "--- summary quantized ---",
            "0.50h (+4m) plan",
            "",
            "--- totals quantized ---",
            "0.50h (+4m) workday",
          },
        },
      },
    })
  end)

  t.test("refresh skips a worklog with no summary", function()
    local result = refresh_summaries.run({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
    })

    t.eq(result, { edits = {} })
  end)

  t.test("refresh skips an invalid worklog rather than churn", function()
    local result = refresh_summaries.run({
      "--- worklog ---",
      "09:00 later",
      "08:00 earlier",
      "10:00 done",
      "",
      "--- summary exact ---",
      "0.50h later",
      "",
      "--- totals exact ---",
      "0.50h workday",
    })

    t.eq(result, { edits = {} })
  end)

  t.test("refresh leaves a structurally broken document alone", function()
    local result = refresh_summaries.run({
      "--- summary exact ---",
      "1.00h x",
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
    })

    t.eq(result, { edits = {} })
  end)
end
