return function(t)
  local refresh_summaries = require("worklog.usecases.refresh_summaries")

  t.test("refresh rewrites a stale summary in place", function()
    local result = refresh_summaries.run({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary ---",
      "0.50h (+0m) plan",
      "",
      "--- totals ---",
      "0.50h (+0m) workday",
    })

    t.eq(result, {
      warnings = {},
      edits = {
        {
          start_index = 4,
          end_index = 9,
          lines = {
            "--- summary ---",
            "1.00h (+0m) plan",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
      },
    })
  end)

  t.test("refresh migrates a legacy quantized-header summary to the kind-less form", function()
    local result = refresh_summaries.run({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary quantized ---",
      "1.00h (+0m) plan",
      "",
      "--- totals quantized ---",
      "1.00h (+0m) workday",
    })

    t.eq(result, {
      warnings = {},
      edits = {
        {
          start_index = 4,
          end_index = 9,
          lines = {
            "--- summary ---",
            "1.00h (+0m) plan",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
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
      "--- summary ---",
      "1.00h (+0m) plan",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })

    t.eq(result, { edits = {}, warnings = {} })
  end)

  t.test("refresh updates only the changed worklog among several", function()
    local result = refresh_summaries.run({
      "--- worklog ---",
      "08:00 a",
      "09:00 done",
      "",
      "--- summary ---",
      "1.00h (+0m) a",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
      "",
      "--- worklog ---",
      "10:00 b",
      "11:30 done",
      "",
      "--- summary ---",
      "0.50h (+0m) b",
      "",
      "--- totals ---",
      "0.50h (+0m) workday",
    })

    t.eq(result, {
      warnings = {},
      edits = {
        {
          start_index = 14,
          end_index = 19,
          lines = {
            "--- summary ---",
            "1.50h (+0m) b",
            "",
            "--- totals ---",
            "1.50h (+0m) workday",
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
      "--- summary ---",
      "1.00h (+0m) plan",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })

    t.eq(result, {
      warnings = {},
      edits = {
        {
          start_index = 4,
          end_index = 9,
          lines = {
            "--- summary ---",
            "0.50h (+4m) plan",
            "",
            "--- totals ---",
            "0.50h (+4m) workday",
          },
        },
      },
    })
  end)

  t.test("refresh creates a summary for a worklog that has none", function()
    local result = refresh_summaries.run({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
    })

    -- The summary is inserted after the last entry; re-running on the result is a
    -- no-op (covered by "refresh is a no-op when the summary is already current").
    t.eq(result, {
      warnings = {},
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = {
            "",
            "--- summary ---",
            "1.00h (+0m) plan",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
      },
    })
  end)

  t.test("refresh creates a summary for a non-last worklog in the right place", function()
    local result = refresh_summaries.run({
      "--- worklog ---",
      "08:00 a",
      "09:00 done",
      "",
      "--- worklog ---",
      "10:00 b",
      "11:00 done",
      "",
      "--- summary ---",
      "1.00h (+0m) b",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })

    -- The first worklog's summary lands after its last entry (row 3); the blank
    -- before the second worklog stays as the separator. The second worklog's
    -- summary is already current, so it is left untouched.
    t.eq(result, {
      warnings = {},
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = {
            "",
            "--- summary ---",
            "1.00h (+0m) a",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
      },
    })
  end)

  t.test("refresh warns instead of churning an invalid worklog with a summary", function()
    local result = refresh_summaries.run({
      "--- worklog ---",
      "09:00 later",
      "08:00 earlier",
      "10:00 done",
      "",
      "--- summary ---",
      "0.50h (+0m) later",
      "",
      "--- totals ---",
      "0.50h (+0m) workday",
    })

    t.eq(result, {
      edits = {},
      warnings = {
        {
          row = 2,
          message = "worklog: unordered timestamps near lines 2 and 3; fix manually or run :WorklogOrder",
        },
      },
    })
  end)

  t.test("refresh warns about an invalid worklog even with no summary", function()
    local result = refresh_summaries.run({
      "--- worklog ---",
      "09:00 later",
      "08:00 earlier",
      "10:00 done",
    })

    t.eq(result, {
      edits = {},
      warnings = {
        {
          row = 2,
          message = "worklog: unordered timestamps near lines 2 and 3; fix manually or run :WorklogOrder",
        },
      },
    })
  end)

  t.test("refresh warns about timestamps with no worklog header at all", function()
    local result = refresh_summaries.run({
      "08:00 a",
      "07:00 b",
    })

    t.eq(result, {
      edits = {},
      warnings = {
        {
          row = 1,
          message = "worklog: no worklog block found; first line must be a worklog header "
            .. "such as --- worklog --- or --- worklog #ClientA @office quantize=30 ---",
        },
      },
    })
  end)

  t.test("refresh does not warn about a blank, header-less buffer", function()
    t.eq(refresh_summaries.run({}), { edits = {}, warnings = {} })
    t.eq(refresh_summaries.run({ "", "" }), { edits = {}, warnings = {} })
    t.eq(refresh_summaries.run({ "just some prose" }), { edits = {}, warnings = {} })
  end)

  t.test("refresh warns but does not edit a structurally broken document", function()
    -- A blank first line pushes the header off row 1: the document is structurally
    -- broken, so nothing is rewritten, but the out-of-order entries below still
    -- warn rather than going silent.
    local result = refresh_summaries.run({
      "",
      "--- worklog ---",
      "09:00 later",
      "08:00 earlier",
    })

    t.eq(result, {
      edits = {},
      warnings = {
        {
          row = 2,
          message = "worklog: first line must be a worklog header such as --- worklog --- or "
            .. "--- worklog #ClientA @office quantize=30 ---",
        },
        {
          row = 3,
          message = "worklog: unordered timestamps near lines 3 and 4; fix manually or run :WorklogOrder",
        },
      },
    })
  end)
end
