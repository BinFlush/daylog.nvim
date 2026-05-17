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

  local function total_duration(items)
    local total = 0

    for _, item in ipairs(items) do
      total = total + item.duration
    end

    return total
  end

  local function assert_activity_totals_match(test, result)
    test.eq(total_duration(result.summary_items), result.activity_total)
    test.eq(total_duration(result.tag_totals), result.activity_total)
    test.eq(total_duration(result.location_totals), result.activity_total)
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
      summary_items = {
        {
          text = "plan",
          tag = "ProjectOrion",
          duration = 30,
          exact_duration = 30,
          workday_excluded = false,
        },
        {
          text = "call",
          tag = "sales",
          duration = 30,
          exact_duration = 30,
          workday_excluded = false,
        },
        {
          text = "break",
          tag = "ooo",
          duration = 15,
          exact_duration = 15,
          workday_excluded = true,
        },
      },
      tag_totals = {
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
      location_totals = {
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
      summary_items = {
        {
          text = "break",
          tag = "ooo",
          duration = 60,
          exact_duration = 60,
          workday_excluded = true,
        },
        {
          text = "resume",
          tag = nil,
          duration = 60,
          exact_duration = 60,
          workday_excluded = false,
        },
      },
      tag_totals = {
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
      location_totals = {
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
      summary_items = {
        {
          text = "call",
          tag = "sales",
          duration = 30,
          exact_duration = 18,
          error_minutes = -12,
          workday_excluded = false,
        },
        {
          text = "plan",
          tag = nil,
          duration = 0,
          exact_duration = 12,
          error_minutes = 12,
          workday_excluded = false,
        },
      },
      tag_totals = {
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
      location_totals = {
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
      summary_items = {
        {
          text = "call",
          tag = "sales",
          duration = 60,
          exact_duration = 40,
          error_minutes = -20,
          workday_excluded = false,
        },
        {
          text = "plan",
          tag = nil,
          duration = 0,
          exact_duration = 20,
          error_minutes = 20,
          workday_excluded = false,
        },
      },
      tag_totals = {
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
      location_totals = {
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
      summary_items = {
        {
          text = "call",
          tag = "sales",
          duration = 60,
          exact_duration = 40,
          error_minutes = -20,
          workday_excluded = false,
        },
        {
          text = "plan",
          tag = nil,
          duration = 0,
          exact_duration = 20,
          error_minutes = 20,
          workday_excluded = false,
        },
      },
      tag_totals = {
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
      location_totals = {
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

  t.test("quantized summary derives item tag and location totals from one shared base", function()
    local block = block_from_lines({
      "--- worklog quantize=30 ---",
      "08:00 alpha #A @x",
      "08:17 beta #B @y",
      "08:34 gamma #C @x",
      "08:51 done",
    })

    local quantized = summary.quantized_summarize_block(block)

    t.eq(quantized, {
      summary_items = {
        {
          text = "alpha",
          tag = "A",
          duration = 30,
          exact_duration = 17,
          error_minutes = -13,
          workday_excluded = false,
        },
        {
          text = "beta",
          tag = "B",
          duration = 30,
          exact_duration = 17,
          error_minutes = -13,
          workday_excluded = false,
        },
        {
          text = "gamma",
          tag = "C",
          duration = 0,
          exact_duration = 17,
          error_minutes = 17,
          workday_excluded = false,
        },
      },
      tag_totals = {
        {
          tag = "A",
          duration = 30,
          exact_duration = 17,
          error_minutes = -13,
        },
        {
          tag = "B",
          duration = 30,
          exact_duration = 17,
          error_minutes = -13,
        },
        {
          tag = "C",
          duration = 0,
          exact_duration = 17,
          error_minutes = 17,
        },
      },
      location_totals = {
        {
          location = "x",
          duration = 30,
          exact_duration = 34,
          error_minutes = 4,
        },
        {
          location = "y",
          duration = 30,
          exact_duration = 17,
          error_minutes = -13,
        },
      },
      activity_total = 60,
      workday_total = 60,
      activity_error_minutes = -9,
      workday_error_minutes = -9,
    })

    assert_activity_totals_match(t, quantized)
  end)

  t.test("quantized summary folds same text and tag across locations", function()
    local block = block_from_lines({
      "--- worklog #ClientA quantize=30 ---",
      "08:00 planning @office",
      "08:17 planning @home",
      "08:34 done",
    })

    t.eq(summary.quantized_summarize_block(block), {
      summary_items = {
        {
          text = "planning",
          tag = "ClientA",
          duration = 30,
          exact_duration = 34,
          error_minutes = 4,
          workday_excluded = false,
        },
      },
      tag_totals = {
        {
          tag = "ClientA",
          duration = 30,
          exact_duration = 34,
          error_minutes = 4,
        },
      },
      location_totals = {
        {
          location = "office",
          duration = 30,
          exact_duration = 17,
          error_minutes = -13,
        },
        {
          location = "home",
          duration = 0,
          exact_duration = 17,
          error_minutes = 17,
        },
      },
      activity_total = 30,
      workday_total = 30,
      activity_error_minutes = 4,
      workday_error_minutes = 4,
    })
  end)

  t.test("summary ignores location for main item identity and keeps totals unchanged", function()
    local block = block_from_lines({
      "--- worklog #ClientA @office ---",
      "08:00 planning",
      "10:00 implementation @home",
      "11:00 planning",
      "13:00 internal meeting #internal",
      "14:00 client followup #ClientA @client",
      "17:00 done",
    })

    t.eq(summary.summarize_block(block), {
      summary_items = {
        {
          text = "planning",
          tag = "ClientA",
          duration = 240,
          exact_duration = 240,
          workday_excluded = false,
        },
        {
          text = "client followup",
          tag = "ClientA",
          duration = 180,
          exact_duration = 180,
          workday_excluded = false,
        },
        {
          text = "implementation",
          tag = "ClientA",
          duration = 60,
          exact_duration = 60,
          workday_excluded = false,
        },
        {
          text = "internal meeting",
          tag = "internal",
          duration = 60,
          exact_duration = 60,
          workday_excluded = false,
        },
      },
      tag_totals = {
        {
          tag = "ClientA",
          duration = 480,
          exact_duration = 480,
        },
        {
          tag = "internal",
          duration = 60,
          exact_duration = 60,
        },
      },
      location_totals = {
        {
          location = "home",
          duration = 240,
          exact_duration = 240,
        },
        {
          location = "client",
          duration = 180,
          exact_duration = 180,
        },
        {
          location = "office",
          duration = 120,
          exact_duration = 120,
        },
      },
      activity_total = 540,
      workday_total = 540,
    })
  end)

  t.test(
    "summary keeps same-text different-tag rows adjacent and sorts by combined duration",
    function()
      local block = block_from_lines({
        "--- worklog ---",
        "08:00 meeting #ClientA",
        "09:00 implementation #ClientA",
        "12:00 meeting #internal",
        "14:00 done",
      })

      t.eq(summary.summarize_block(block).summary_items, {
        {
          text = "meeting",
          tag = "internal",
          duration = 120,
          exact_duration = 120,
          workday_excluded = false,
        },
        {
          text = "meeting",
          tag = "ClientA",
          duration = 60,
          exact_duration = 60,
          workday_excluded = false,
        },
        {
          text = "implementation",
          tag = "ClientA",
          duration = 180,
          exact_duration = 180,
          workday_excluded = false,
        },
      })
    end
  )

  t.test("summary preserves stable order when text groups tie completely", function()
    local block = block_from_lines({
      "--- worklog ---",
      "08:00 alpha",
      "09:00 beta",
      "10:00 done",
    })

    t.eq(summary.summarize_block(block).summary_items, {
      {
        text = "alpha",
        tag = nil,
        duration = 60,
        exact_duration = 60,
        workday_excluded = false,
      },
      {
        text = "beta",
        tag = nil,
        duration = 60,
        exact_duration = 60,
        workday_excluded = false,
      },
    })
  end)

  t.test("summary preserves stable order within same-text tag ties", function()
    local block = block_from_lines({
      "--- worklog ---",
      "08:00 meeting #ClientA",
      "09:00 other",
      "10:00 meeting #internal",
      "11:00 done",
    })

    t.eq(summary.summarize_block(block).summary_items, {
      {
        text = "meeting",
        tag = "ClientA",
        duration = 60,
        exact_duration = 60,
        workday_excluded = false,
      },
      {
        text = "meeting",
        tag = "internal",
        duration = 60,
        exact_duration = 60,
        workday_excluded = false,
      },
      {
        text = "other",
        tag = "ClientA",
        duration = 60,
        exact_duration = 60,
        workday_excluded = false,
      },
    })
  end)

  t.test("summary keeps activity text containing pipes separate", function()
    local block = block_from_lines({
      "--- worklog ---",
      "08:00 alpha|beta",
      "09:00 alpha #beta",
      "10:00 done",
    })

    t.eq(summary.summarize_block(block).summary_items, {
      {
        text = "alpha|beta",
        tag = nil,
        duration = 60,
        exact_duration = 60,
        workday_excluded = false,
      },
      {
        text = "alpha",
        tag = "beta",
        duration = 60,
        exact_duration = 60,
        workday_excluded = false,
      },
    })
  end)
end
