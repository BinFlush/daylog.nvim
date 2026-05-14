return function(t)
  local analyze = require("worklog.analyze")
  local document = require("worklog.document")
  local summary = require("worklog.summary")

  local function block_from_lines(lines)
    local analysis = analyze.analyze(document.parse(lines))
    return analysis.worklog_blocks[1]
  end

  t.test("summary summarizes semantic worklog blocks directly", function()
    local block = block_from_lines({
      "--- worklog default=#ProjectOrion ---",
      "08:00 plan",
      "08:30 call #sales",
      "09:00 break #ooo",
      "09:15 done",
    })

    t.eq(summary.summarize_block(block), {
      items = {
        {
          text = "plan",
          label = "ProjectOrion",
          duration = 30,
          exact_duration = 30,
          excluded = false,
        },
        {
          text = "call",
          label = "sales",
          duration = 30,
          exact_duration = 30,
          excluded = false,
        },
        {
          text = "break",
          label = "ooo",
          duration = 15,
          exact_duration = 15,
          excluded = true,
        },
      },
      label_items = {
        {
          label = "ProjectOrion",
          duration = 30,
          exact_duration = 30,
          excluded = false,
        },
        {
          label = "sales",
          duration = 30,
          exact_duration = 30,
          excluded = false,
        },
        {
          label = "ooo",
          duration = 15,
          exact_duration = 15,
          excluded = true,
        },
      },
      default_label = "ProjectOrion",
      activity_total = 75,
      workday_total = 60,
    })
  end)

  t.test("quantized summary summarizes semantic worklog blocks directly", function()
    local block = block_from_lines({
      "--- worklog quantize=30 ---",
      "08:00 plan",
      "08:12 call #sales",
      "08:30 done",
    })

    t.eq(summary.quantized_summarize_block(block), {
      items = {
        {
          text = "call",
          label = "sales",
          duration = 30,
          exact_duration = 18,
          error_minutes = -12,
          excluded = false,
        },
        {
          text = "plan",
          label = nil,
          duration = 0,
          exact_duration = 12,
          error_minutes = 12,
          excluded = false,
        },
      },
      label_items = {
        {
          label = "sales",
          duration = 30,
          exact_duration = 18,
          error_minutes = -12,
          excluded = false,
        },
        {
          label = nil,
          duration = 0,
          exact_duration = 12,
          error_minutes = 12,
          excluded = false,
        },
      },
      default_label = nil,
      activity_total = 30,
      workday_total = 30,
      activity_error_minutes = 0,
      workday_error_minutes = 0,
    })
  end)

  t.test("quantized summary supports 60 minute rounding", function()
    local block = block_from_lines({
      "--- worklog quantize=60 ---",
      "08:00 plan",
      "08:20 call #sales",
      "09:00 done",
    })

    t.eq(summary.quantized_summarize_block(block), {
      items = {
        {
          text = "call",
          label = "sales",
          duration = 60,
          exact_duration = 40,
          error_minutes = -20,
          excluded = false,
        },
        {
          text = "plan",
          label = nil,
          duration = 0,
          exact_duration = 20,
          error_minutes = 20,
          excluded = false,
        },
      },
      label_items = {
        {
          label = "sales",
          duration = 60,
          exact_duration = 40,
          error_minutes = -20,
          excluded = false,
        },
        {
          label = nil,
          duration = 0,
          exact_duration = 20,
          error_minutes = 20,
          excluded = false,
        },
      },
      default_label = nil,
      activity_total = 60,
      workday_total = 60,
      activity_error_minutes = 0,
      workday_error_minutes = 0,
    })
  end)
end
