return function(t)
  local analyze = require("worklog.analyze")
  local document = require("worklog.document")
  local summary = require("worklog.summary")

  local function block_from_lines(lines)
    local analysis = analyze.analyze(document.parse(lines))
    return analysis.worklog_blocks[1]
  end

  local function block_at(lines, index)
    local analysis = analyze.analyze(document.parse(lines))
    return analysis.worklog_blocks[index]
  end

  t.test("summary summarizes semantic worklog blocks directly", function()
    local block = block_from_lines({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "08:30 call #sales @client",
      "09:00 break #ooo",
      "09:15 done #ProjectOrion @office",
    })

    t.eq(summary.summarize_block(block), {
      items = {
        {
          text = "plan",
          tag = "ProjectOrion",
          location = "office",
          duration = 30,
          exact_duration = 30,
          excluded = false,
        },
        {
          text = "call",
          tag = "sales",
          location = "client",
          duration = 30,
          exact_duration = 30,
          excluded = false,
        },
        {
          text = "break",
          tag = "ooo",
          location = "client",
          duration = 15,
          exact_duration = 15,
          excluded = true,
        },
      },
      tag_items = {
        {
          tag = "ProjectOrion",
          duration = 30,
          exact_duration = 30,
        },
        {
          tag = "sales",
          duration = 30,
          exact_duration = 30,
        },
        {
          tag = "ooo",
          duration = 15,
          exact_duration = 15,
        },
      },
      location_items = {
        {
          location = "client",
          duration = 45,
          exact_duration = 45,
        },
        {
          location = "office",
          duration = 30,
          exact_duration = 30,
        },
      },
      activity_total = 75,
      workday_total = 60,
    })
  end)

  t.test("summary treats cleared metadata as untagged and no location", function()
    local block = block_from_lines({
      "--- worklog ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
    })

    t.eq(summary.summarize_block(block), {
      items = {
        {
          text = "break",
          tag = "ooo",
          location = "home",
          duration = 60,
          exact_duration = 60,
          excluded = true,
        },
        {
          text = "resume",
          tag = nil,
          location = nil,
          duration = 60,
          exact_duration = 60,
          excluded = false,
        },
      },
      tag_items = {
        {
          tag = "ooo",
          duration = 60,
          exact_duration = 60,
        },
        {
          tag = nil,
          duration = 60,
          exact_duration = 60,
        },
      },
      location_items = {
        {
          location = "home",
          duration = 60,
          exact_duration = 60,
        },
        {
          location = nil,
          duration = 60,
          exact_duration = 60,
        },
      },
      activity_total = 120,
      workday_total = 60,
    })
  end)

  t.test("quantized summary summarizes semantic worklog blocks directly", function()
    local block = block_from_lines({
      "--- worklog @office quantize=30 ---",
      "08:00 plan",
      "08:12 call #sales @client",
      "08:30 done",
    })

    t.eq(summary.quantized_summarize_block(block), {
      items = {
        {
          text = "call",
          tag = "sales",
          location = "client",
          duration = 30,
          exact_duration = 18,
          error_minutes = -12,
          excluded = false,
        },
        {
          text = "plan",
          tag = nil,
          location = "office",
          duration = 0,
          exact_duration = 12,
          error_minutes = 12,
          excluded = false,
        },
      },
      tag_items = {
        {
          tag = "sales",
          duration = 30,
          exact_duration = 18,
          error_minutes = -12,
        },
        {
          tag = nil,
          duration = 0,
          exact_duration = 12,
          error_minutes = 12,
        },
      },
      location_items = {
        {
          location = "client",
          duration = 30,
          exact_duration = 18,
          error_minutes = -12,
        },
        {
          location = "office",
          duration = 0,
          exact_duration = 12,
          error_minutes = 12,
        },
      },
      activity_total = 30,
      workday_total = 30,
      activity_error_minutes = 0,
      workday_error_minutes = 0,
    })
  end)

  t.test("quantized summary supports 60 minute rounding", function()
    local block = block_from_lines({
      "--- worklog @office quantize=60 ---",
      "08:00 plan",
      "08:20 call #sales @client",
      "09:00 done",
    })

    t.eq(summary.quantized_summarize_block(block), {
      items = {
        {
          text = "call",
          tag = "sales",
          location = "client",
          duration = 60,
          exact_duration = 40,
          error_minutes = -20,
          excluded = false,
        },
        {
          text = "plan",
          tag = nil,
          location = "office",
          duration = 0,
          exact_duration = 20,
          error_minutes = 20,
          excluded = false,
        },
      },
      tag_items = {
        {
          tag = "sales",
          duration = 60,
          exact_duration = 40,
          error_minutes = -20,
        },
        {
          tag = nil,
          duration = 0,
          exact_duration = 20,
          error_minutes = 20,
        },
      },
      location_items = {
        {
          location = "client",
          duration = 60,
          exact_duration = 40,
          error_minutes = -20,
        },
        {
          location = "office",
          duration = 0,
          exact_duration = 20,
          error_minutes = 20,
        },
      },
      activity_total = 60,
      workday_total = 60,
      activity_error_minutes = 0,
      workday_error_minutes = 0,
    })
  end)

  t.test("quantized summary uses the selected block quantize", function()
    local block = block_at({
      "--- worklog @office quantize=30 ---",
      "08:00 plan",
      "08:12 call #sales @client",
      "08:30 done",
      "--- worklog @office quantize=60 ---",
      "09:00 plan",
      "09:20 call #sales @client",
      "10:00 done",
    }, 2)

    t.eq(summary.quantized_summarize_block(block), {
      items = {
        {
          text = "call",
          tag = "sales",
          location = "client",
          duration = 60,
          exact_duration = 40,
          error_minutes = -20,
          excluded = false,
        },
        {
          text = "plan",
          tag = nil,
          location = "office",
          duration = 0,
          exact_duration = 20,
          error_minutes = 20,
          excluded = false,
        },
      },
      tag_items = {
        {
          tag = "sales",
          duration = 60,
          exact_duration = 40,
          error_minutes = -20,
        },
        {
          tag = nil,
          duration = 0,
          exact_duration = 20,
          error_minutes = 20,
        },
      },
      location_items = {
        {
          location = "client",
          duration = 60,
          exact_duration = 40,
          error_minutes = -20,
        },
        {
          location = "office",
          duration = 0,
          exact_duration = 20,
          error_minutes = 20,
        },
      },
      activity_total = 60,
      workday_total = 60,
      activity_error_minutes = 0,
      workday_error_minutes = 0,
    })
  end)
end
