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

  -- The single summary type is quantized; "exact" is just quantize=1 (rounding is a
  -- no-op on whole-minute durations). These helpers assert the unrounded shape by
  -- computing at quantize=1 and dropping the now-zero error fields.
  local function strip_errors(result)
    local groups = { result.summary_items, result.tag_totals, result.location_totals }
    if result.logged_totals then
      table.insert(groups, result.logged_totals)
    end

    for _, group in ipairs(groups) do
      for _, item in ipairs(group) do
        item.error_minutes = nil
      end
    end

    result.activity_error_minutes = nil
    result.workday_error_minutes = nil
    return result
  end

  local function summarize_exact_entries(entries)
    return strip_errors(summary.summarize_entries(entries, 1))
  end

  local function summarize_exact(block)
    return summarize_exact_entries(block.entries)
  end

  t.test("summary summarizes semantic worklog blocks directly", function()
    local block = block_from_lines({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "08:30 call #sales @client",
      "09:00 break #ooo",
      "09:15 done #ProjectOrion @office",
    })

    t.eq(summarize_exact(block), {
      summary_items = {
        {
          text = "plan",
          tag = "ProjectOrion",
          duration = 30,
          unrounded_duration = 30,
          workday_excluded = false,
          source_entry_rows = { 2 },
        },
        {
          text = "call",
          tag = "sales",
          duration = 30,
          unrounded_duration = 30,
          workday_excluded = false,
          source_entry_rows = { 3 },
        },
        {
          text = "break",
          tag = "ooo",
          duration = 15,
          unrounded_duration = 15,
          workday_excluded = true,
          source_entry_rows = { 4 },
        },
      },
      tag_totals = {
        {
          tag = "ProjectOrion",
          duration = 30,
          unrounded_duration = 30,
        },
        {
          tag = "sales",
          duration = 30,
          unrounded_duration = 30,
        },
        {
          tag = "ooo",
          duration = 15,
          unrounded_duration = 15,
        },
      },
      location_totals = {
        {
          location = "client",
          duration = 45,
          unrounded_duration = 45,
        },
        {
          location = "office",
          duration = 30,
          unrounded_duration = 30,
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

    t.eq(summarize_exact(block), {
      summary_items = {
        {
          text = "break",
          tag = "ooo",
          duration = 60,
          unrounded_duration = 60,
          workday_excluded = true,
          source_entry_rows = { 2 },
        },
        {
          text = "resume",
          tag = nil,
          duration = 60,
          unrounded_duration = 60,
          workday_excluded = false,
          source_entry_rows = { 3 },
        },
      },
      tag_totals = {
        {
          tag = "ooo",
          duration = 60,
          unrounded_duration = 60,
        },
        {
          tag = nil,
          duration = 60,
          unrounded_duration = 60,
        },
      },
      location_totals = {
        {
          location = "home",
          duration = 60,
          unrounded_duration = 60,
        },
        {
          location = nil,
          duration = 60,
          unrounded_duration = 60,
        },
      },
      activity_total = 120,
      workday_total = 60,
    })
  end)

  t.test(
    "summary splits logged main rows and counts logged totals from workday intervals",
    function()
      local block = block_from_lines({
        "--- worklog #ClientA @office ---",
        "08:00 implementation !L",
        "09:00 implementation",
        "10:00 break #ooo !L",
        "10:30 done",
      })

      t.eq(summarize_exact(block), {
        summary_items = {
          {
            text = "implementation",
            tag = "ClientA",
            duration = 60,
            unrounded_duration = 60,
            workday_excluded = false,
            logged = true,
            source_entry_rows = { 2 },
          },
          {
            text = "implementation",
            tag = "ClientA",
            duration = 60,
            unrounded_duration = 60,
            workday_excluded = false,
            source_entry_rows = { 3 },
          },
          {
            text = "break",
            tag = "ooo",
            duration = 30,
            unrounded_duration = 30,
            workday_excluded = true,
            logged = true,
            source_entry_rows = { 4 },
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 120,
            unrounded_duration = 120,
          },
          {
            tag = "ooo",
            duration = 30,
            unrounded_duration = 30,
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 150,
            unrounded_duration = 150,
          },
        },
        logged_totals = {
          {
            logged = true,
            duration = 60,
            unrounded_duration = 60,
          },
          {
            logged = false,
            duration = 60,
            unrounded_duration = 60,
          },
        },
        activity_total = 150,
        workday_total = 120,
      })
    end
  )

  t.test("quantized summary summarizes semantic worklog blocks directly", function()
    local block = block_from_lines({
      "--- worklog @office quantize=30 ---",
      "08:00 plan",
      "08:12 call #sales @client",
      "08:30 done",
    })

    t.eq(summary.summarize_block(block), {
      summary_items = {
        {
          text = "call",
          tag = "sales",
          duration = 30,
          unrounded_duration = 18,
          error_minutes = -12,
          workday_excluded = false,
          source_entry_rows = { 3 },
        },
        {
          text = "plan",
          tag = nil,
          duration = 0,
          unrounded_duration = 12,
          error_minutes = 12,
          workday_excluded = false,
          source_entry_rows = { 2 },
        },
      },
      tag_totals = {
        {
          tag = "sales",
          duration = 30,
          unrounded_duration = 18,
          error_minutes = -12,
        },
        {
          tag = nil,
          duration = 0,
          unrounded_duration = 12,
          error_minutes = 12,
        },
      },
      location_totals = {
        {
          location = "client",
          duration = 30,
          unrounded_duration = 18,
          error_minutes = -12,
        },
        {
          location = "office",
          duration = 0,
          unrounded_duration = 12,
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

    t.eq(summary.summarize_block(block), {
      summary_items = {
        {
          text = "call",
          tag = "sales",
          duration = 60,
          unrounded_duration = 40,
          error_minutes = -20,
          workday_excluded = false,
          source_entry_rows = { 3 },
        },
        {
          text = "plan",
          tag = nil,
          duration = 0,
          unrounded_duration = 20,
          error_minutes = 20,
          workday_excluded = false,
          source_entry_rows = { 2 },
        },
      },
      tag_totals = {
        {
          tag = "sales",
          duration = 60,
          unrounded_duration = 40,
          error_minutes = -20,
        },
        {
          tag = nil,
          duration = 0,
          unrounded_duration = 20,
          error_minutes = 20,
        },
      },
      location_totals = {
        {
          location = "client",
          duration = 60,
          unrounded_duration = 40,
          error_minutes = -20,
        },
        {
          location = "office",
          duration = 0,
          unrounded_duration = 20,
          error_minutes = 20,
        },
      },
      activity_total = 60,
      workday_total = 60,
      activity_error_minutes = 0,
      workday_error_minutes = 0,
    })
  end)

  t.test("quantized summary splits logged rows without splitting tag or location totals", function()
    local block = block_from_lines({
      "--- worklog #ClientA @office quantize=30 ---",
      "08:00 implementation !L",
      "08:20 implementation",
      "08:40 break #ooo !L",
      "09:00 done",
    })

    t.eq(summary.summarize_block(block), {
      summary_items = {
        {
          text = "implementation",
          tag = "ClientA",
          duration = 30,
          unrounded_duration = 20,
          error_minutes = -10,
          workday_excluded = false,
          logged = true,
          source_entry_rows = { 2 },
        },
        {
          text = "implementation",
          tag = "ClientA",
          duration = 30,
          unrounded_duration = 20,
          error_minutes = -10,
          workday_excluded = false,
          source_entry_rows = { 3 },
        },
        {
          text = "break",
          tag = "ooo",
          duration = 0,
          unrounded_duration = 20,
          error_minutes = 20,
          workday_excluded = true,
          logged = true,
          source_entry_rows = { 4 },
        },
      },
      tag_totals = {
        {
          tag = "ClientA",
          duration = 60,
          unrounded_duration = 40,
          error_minutes = -20,
        },
        {
          tag = "ooo",
          duration = 0,
          unrounded_duration = 20,
          error_minutes = 20,
        },
      },
      location_totals = {
        {
          location = "office",
          duration = 60,
          unrounded_duration = 60,
          error_minutes = 0,
        },
      },
      logged_totals = {
        {
          logged = true,
          duration = 30,
          unrounded_duration = 20,
          error_minutes = -10,
        },
        {
          logged = false,
          duration = 30,
          unrounded_duration = 20,
          error_minutes = -10,
        },
      },
      activity_total = 60,
      workday_total = 60,
      activity_error_minutes = 0,
      workday_error_minutes = -20,
    })
  end)

  t.test(
    "quantized logged totals follow visible main summary rows instead of independent bucket rounding",
    function()
      local block = block_from_lines({
        "--- worklog #ClientA quantize=30 ---",
        "08:00 implementation !L",
        "08:20 implementation",
        "08:40 done",
      })

      t.eq(summary.summarize_block(block), {
        summary_items = {
          {
            text = "implementation",
            tag = "ClientA",
            duration = 30,
            unrounded_duration = 20,
            error_minutes = -10,
            workday_excluded = false,
            logged = true,
            source_entry_rows = { 2 },
          },
          {
            text = "implementation",
            tag = "ClientA",
            duration = 0,
            unrounded_duration = 20,
            error_minutes = 20,
            workday_excluded = false,
            source_entry_rows = { 3 },
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 30,
            unrounded_duration = 40,
            error_minutes = 10,
          },
        },
        location_totals = {
          {
            location = nil,
            duration = 30,
            unrounded_duration = 40,
            error_minutes = 10,
          },
        },
        logged_totals = {
          {
            logged = true,
            duration = 30,
            unrounded_duration = 20,
            error_minutes = -10,
          },
          {
            logged = false,
            duration = 0,
            unrounded_duration = 20,
            error_minutes = 20,
          },
        },
        activity_total = 30,
        workday_total = 30,
        activity_error_minutes = 10,
        workday_error_minutes = 10,
      })
    end
  )

  t.test(
    "logged totals render logged before unlogged even when unlogged duration is larger",
    function()
      local block = block_from_lines({
        "--- worklog #ClientA quantize=30 ---",
        "08:00 implementation !L",
        "08:10 implementation",
        "09:00 done",
      })

      local result = summary.summarize_block(block)

      -- Unlogged exact = 50, logged exact = 10; after quantization unlogged gets the
      -- larger quantized bucket.  Logged must still appear before unlogged.
      t.ok(result.logged_totals ~= nil, "logged_totals should be present")
      t.ok(#result.logged_totals == 2, "should have two logged_total rows")
      t.eq(result.logged_totals[1].logged, true)
      t.eq(result.logged_totals[2].logged, false)
      t.ok(
        result.logged_totals[2].duration >= result.logged_totals[1].duration,
        "unlogged duration should be >= logged duration in this worklog"
      )
    end
  )

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

    t.eq(summary.summarize_block(block), {
      summary_items = {
        {
          text = "call",
          tag = "sales",
          duration = 60,
          unrounded_duration = 40,
          error_minutes = -20,
          workday_excluded = false,
          source_entry_rows = { 7 },
        },
        {
          text = "plan",
          tag = nil,
          duration = 0,
          unrounded_duration = 20,
          error_minutes = 20,
          workday_excluded = false,
          source_entry_rows = { 6 },
        },
      },
      tag_totals = {
        {
          tag = "sales",
          duration = 60,
          unrounded_duration = 40,
          error_minutes = -20,
        },
        {
          tag = nil,
          duration = 0,
          unrounded_duration = 20,
          error_minutes = 20,
        },
      },
      location_totals = {
        {
          location = "client",
          duration = 60,
          unrounded_duration = 40,
          error_minutes = -20,
        },
        {
          location = "office",
          duration = 0,
          unrounded_duration = 20,
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

    local quantized = summary.summarize_block(block)

    t.eq(quantized, {
      summary_items = {
        {
          text = "alpha",
          tag = "A",
          duration = 30,
          unrounded_duration = 17,
          error_minutes = -13,
          workday_excluded = false,
          source_entry_rows = { 2 },
        },
        {
          text = "beta",
          tag = "B",
          duration = 30,
          unrounded_duration = 17,
          error_minutes = -13,
          workday_excluded = false,
          source_entry_rows = { 3 },
        },
        {
          text = "gamma",
          tag = "C",
          duration = 0,
          unrounded_duration = 17,
          error_minutes = 17,
          workday_excluded = false,
          source_entry_rows = { 4 },
        },
      },
      tag_totals = {
        {
          tag = "A",
          duration = 30,
          unrounded_duration = 17,
          error_minutes = -13,
        },
        {
          tag = "B",
          duration = 30,
          unrounded_duration = 17,
          error_minutes = -13,
        },
        {
          tag = "C",
          duration = 0,
          unrounded_duration = 17,
          error_minutes = 17,
        },
      },
      location_totals = {
        {
          location = "x",
          duration = 30,
          unrounded_duration = 34,
          error_minutes = 4,
        },
        {
          location = "y",
          duration = 30,
          unrounded_duration = 17,
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

    t.eq(summary.summarize_block(block), {
      summary_items = {
        {
          text = "planning",
          tag = "ClientA",
          duration = 30,
          unrounded_duration = 34,
          error_minutes = 4,
          workday_excluded = false,
          source_entry_rows = { 2, 3 },
        },
      },
      tag_totals = {
        {
          tag = "ClientA",
          duration = 30,
          unrounded_duration = 34,
          error_minutes = 4,
        },
      },
      location_totals = {
        {
          location = "office",
          duration = 30,
          unrounded_duration = 17,
          error_minutes = -13,
        },
        {
          location = "home",
          duration = 0,
          unrounded_duration = 17,
          error_minutes = 17,
        },
      },
      activity_total = 30,
      workday_total = 30,
      activity_error_minutes = 4,
      workday_error_minutes = 4,
    })
  end)

  t.test("combined quantized summaries preserve daily rounding and sum errors", function()
    t.eq(
      summary.combine_summaries({
        {
          summary_items = {
            {
              text = "plan",
              tag = "ClientA",
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
              workday_excluded = false,
            },
          },
          tag_totals = {
            {
              tag = "ClientA",
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
            },
          },
          location_totals = {
            {
              location = "office",
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
            },
          },
          activity_total = 30,
          workday_total = 30,
          activity_error_minutes = -10,
          workday_error_minutes = -10,
        },
        {
          summary_items = {
            {
              text = "plan",
              tag = "ClientA",
              duration = 0,
              unrounded_duration = 20,
              error_minutes = 20,
              workday_excluded = false,
            },
          },
          tag_totals = {
            {
              tag = "ClientA",
              duration = 0,
              unrounded_duration = 20,
              error_minutes = 20,
            },
          },
          location_totals = {
            {
              location = "office",
              duration = 0,
              unrounded_duration = 20,
              error_minutes = 20,
            },
          },
          activity_total = 0,
          workday_total = 0,
          activity_error_minutes = 20,
          workday_error_minutes = 20,
        },
      }),
      {
        summary_items = {
          {
            text = "plan",
            tag = "ClientA",
            duration = 30,
            unrounded_duration = 40,
            error_minutes = 10,
            workday_excluded = false,
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 30,
            unrounded_duration = 40,
            error_minutes = 10,
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 30,
            unrounded_duration = 40,
            error_minutes = 10,
          },
        },
        activity_total = 30,
        workday_total = 30,
        activity_error_minutes = 10,
        workday_error_minutes = 10,
      }
    )
  end)

  t.test("combined quantized summaries preserve logged main-row separation and totals", function()
    t.eq(
      summary.combine_summaries({
        {
          summary_items = {
            {
              text = "plan",
              tag = "ClientA",
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
              workday_excluded = false,
              logged = true,
            },
          },
          tag_totals = {
            {
              tag = "ClientA",
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
            },
          },
          location_totals = {
            {
              location = "office",
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
            },
          },
          logged_totals = {
            {
              logged = true,
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
            },
          },
          activity_total = 30,
          workday_total = 30,
          activity_error_minutes = -10,
          workday_error_minutes = -10,
        },
        {
          summary_items = {
            {
              text = "plan",
              tag = "ClientA",
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
              workday_excluded = false,
            },
          },
          tag_totals = {
            {
              tag = "ClientA",
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
            },
          },
          location_totals = {
            {
              location = "office",
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
            },
          },
          logged_totals = {
            {
              logged = false,
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
            },
          },
          activity_total = 30,
          workday_total = 30,
          activity_error_minutes = -10,
          workday_error_minutes = -10,
        },
      }),
      {
        summary_items = {
          {
            text = "plan",
            tag = "ClientA",
            duration = 30,
            unrounded_duration = 20,
            error_minutes = -10,
            workday_excluded = false,
            logged = true,
          },
          {
            text = "plan",
            tag = "ClientA",
            duration = 30,
            unrounded_duration = 20,
            error_minutes = -10,
            workday_excluded = false,
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 60,
            unrounded_duration = 40,
            error_minutes = -20,
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 60,
            unrounded_duration = 40,
            error_minutes = -20,
          },
        },
        logged_totals = {
          {
            logged = true,
            duration = 30,
            unrounded_duration = 20,
            error_minutes = -10,
          },
          {
            logged = false,
            duration = 30,
            unrounded_duration = 20,
            error_minutes = -10,
          },
        },
        activity_total = 60,
        workday_total = 60,
        activity_error_minutes = -20,
        workday_error_minutes = -20,
      }
    )
  end)

  t.test("combined quantized summaries derive logged totals from combined summary items", function()
    t.eq(
      summary.combine_summaries({
        {
          summary_items = {
            {
              text = "implementation",
              tag = "ClientA",
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
              workday_excluded = false,
              logged = true,
            },
            {
              text = "implementation",
              tag = "ClientA",
              duration = 0,
              unrounded_duration = 20,
              error_minutes = 20,
              workday_excluded = false,
            },
          },
          tag_totals = {
            {
              tag = "ClientA",
              duration = 30,
              unrounded_duration = 40,
              error_minutes = 10,
            },
          },
          location_totals = {
            {
              location = "office",
              duration = 30,
              unrounded_duration = 40,
              error_minutes = 10,
            },
          },
          logged_totals = {
            {
              logged = true,
              duration = 999,
              unrounded_duration = 999,
              error_minutes = 0,
            },
          },
          activity_total = 30,
          workday_total = 30,
          activity_error_minutes = 10,
          workday_error_minutes = 10,
        },
      }),
      {
        summary_items = {
          {
            text = "implementation",
            tag = "ClientA",
            duration = 30,
            unrounded_duration = 20,
            error_minutes = -10,
            workday_excluded = false,
            logged = true,
          },
          {
            text = "implementation",
            tag = "ClientA",
            duration = 0,
            unrounded_duration = 20,
            error_minutes = 20,
            workday_excluded = false,
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 30,
            unrounded_duration = 40,
            error_minutes = 10,
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 30,
            unrounded_duration = 40,
            error_minutes = 10,
          },
        },
        logged_totals = {
          {
            logged = true,
            duration = 30,
            unrounded_duration = 20,
            error_minutes = -10,
          },
          {
            logged = false,
            duration = 0,
            unrounded_duration = 20,
            error_minutes = 20,
          },
        },
        activity_total = 30,
        workday_total = 30,
        activity_error_minutes = 10,
        workday_error_minutes = 10,
      }
    )
  end)

  t.test(
    "combined quantized logged totals follow combined visible summary rows instead of re-quantizing",
    function()
      -- Each day: impl !L = 20 exact, impl = 20 exact, bucket = 30.
      -- Tie on remainder; first-seen (logged=true) gets the single extra bucket.
      -- Per-day result: logged = 30, unlogged = 0.
      --
      -- Combined visible rows: logged = 60, unlogged = 0.
      --
      -- If logged and unlogged exact totals were independently re-quantized after
      -- combining (logged exact = 40 → target 30, unlogged exact = 40 → target 30),
      -- the result would be logged = 30, unlogged = 30 — diverging from the visible
      -- combined rows.  The invariant requires logged = 60, unlogged = 0.
      local day = {
        summary_items = {
          {
            text = "implementation",
            tag = "ClientA",
            duration = 30,
            unrounded_duration = 20,
            error_minutes = -10,
            workday_excluded = false,
            logged = true,
          },
          {
            text = "implementation",
            tag = "ClientA",
            duration = 0,
            unrounded_duration = 20,
            error_minutes = 20,
            workday_excluded = false,
          },
        },
        tag_totals = {
          { tag = "ClientA", duration = 30, unrounded_duration = 40, error_minutes = 10 },
        },
        location_totals = {
          { location = nil, duration = 30, unrounded_duration = 40, error_minutes = 10 },
        },
        logged_totals = {
          { logged = true, duration = 30, unrounded_duration = 20, error_minutes = -10 },
          { logged = false, duration = 0, unrounded_duration = 20, error_minutes = 20 },
        },
        activity_total = 30,
        workday_total = 30,
        activity_error_minutes = 10,
        workday_error_minutes = 10,
      }

      t.eq(summary.combine_summaries({ day, day }), {
        summary_items = {
          {
            text = "implementation",
            tag = "ClientA",
            duration = 60,
            unrounded_duration = 40,
            error_minutes = -20,
            workday_excluded = false,
            logged = true,
          },
          {
            text = "implementation",
            tag = "ClientA",
            duration = 0,
            unrounded_duration = 40,
            error_minutes = 40,
            workday_excluded = false,
          },
        },
        tag_totals = {
          { tag = "ClientA", duration = 60, unrounded_duration = 80, error_minutes = 20 },
        },
        location_totals = {
          { location = nil, duration = 60, unrounded_duration = 80, error_minutes = 20 },
        },
        logged_totals = {
          { logged = true, duration = 60, unrounded_duration = 40, error_minutes = -20 },
          { logged = false, duration = 0, unrounded_duration = 40, error_minutes = 40 },
        },
        activity_total = 60,
        workday_total = 60,
        activity_error_minutes = 20,
        workday_error_minutes = 20,
      })
    end
  )

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

    t.eq(summarize_exact(block), {
      summary_items = {
        {
          text = "planning",
          tag = "ClientA",
          duration = 240,
          unrounded_duration = 240,
          workday_excluded = false,
          source_entry_rows = { 2, 4 },
        },
        {
          text = "client followup",
          tag = "ClientA",
          duration = 180,
          unrounded_duration = 180,
          workday_excluded = false,
          source_entry_rows = { 6 },
        },
        {
          text = "implementation",
          tag = "ClientA",
          duration = 60,
          unrounded_duration = 60,
          workday_excluded = false,
          source_entry_rows = { 3 },
        },
        {
          text = "internal meeting",
          tag = "internal",
          duration = 60,
          unrounded_duration = 60,
          workday_excluded = false,
          source_entry_rows = { 5 },
        },
      },
      tag_totals = {
        {
          tag = "ClientA",
          duration = 480,
          unrounded_duration = 480,
        },
        {
          tag = "internal",
          duration = 60,
          unrounded_duration = 60,
        },
      },
      location_totals = {
        {
          location = "home",
          duration = 240,
          unrounded_duration = 240,
        },
        {
          location = "client",
          duration = 180,
          unrounded_duration = 180,
        },
        {
          location = "office",
          duration = 120,
          unrounded_duration = 120,
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

      t.eq(summarize_exact(block).summary_items, {
        {
          text = "meeting",
          tag = "internal",
          duration = 120,
          unrounded_duration = 120,
          workday_excluded = false,
          source_entry_rows = { 4 },
        },
        {
          text = "meeting",
          tag = "ClientA",
          duration = 60,
          unrounded_duration = 60,
          workday_excluded = false,
          source_entry_rows = { 2 },
        },
        {
          text = "implementation",
          tag = "ClientA",
          duration = 180,
          unrounded_duration = 180,
          workday_excluded = false,
          source_entry_rows = { 3 },
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

    t.eq(summarize_exact(block).summary_items, {
      {
        text = "alpha",
        tag = nil,
        duration = 60,
        unrounded_duration = 60,
        workday_excluded = false,
        source_entry_rows = { 2 },
      },
      {
        text = "beta",
        tag = nil,
        duration = 60,
        unrounded_duration = 60,
        workday_excluded = false,
        source_entry_rows = { 3 },
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

    t.eq(summarize_exact(block).summary_items, {
      {
        text = "meeting",
        tag = "ClientA",
        duration = 60,
        unrounded_duration = 60,
        workday_excluded = false,
        source_entry_rows = { 2 },
      },
      {
        text = "meeting",
        tag = "internal",
        duration = 60,
        unrounded_duration = 60,
        workday_excluded = false,
        source_entry_rows = { 4 },
      },
      {
        text = "other",
        tag = "ClientA",
        duration = 60,
        unrounded_duration = 60,
        workday_excluded = false,
        source_entry_rows = { 3 },
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

    t.eq(summarize_exact(block).summary_items, {
      {
        text = "alpha|beta",
        tag = nil,
        duration = 60,
        unrounded_duration = 60,
        workday_excluded = false,
        source_entry_rows = { 2 },
      },
      {
        text = "alpha",
        tag = "beta",
        duration = 60,
        unrounded_duration = 60,
        workday_excluded = false,
        source_entry_rows = { 3 },
      },
    })
  end)

  t.test("summary provenance points back to the entry rows that fed each item", function()
    local block = block_from_lines({
      "--- worklog ---",
      "08:00 implementation",
      "09:00 meeting",
      "10:00 implementation",
      "11:00 done",
    })

    local items = summarize_exact(block).summary_items

    t.eq(items[1].text, "implementation")
    t.eq(items[1].source_entry_rows, { 2, 4 })
    t.eq(items[2].text, "meeting")
    t.eq(items[2].source_entry_rows, { 3 })
  end)

  t.test("summary provenance keeps logged and unlogged source rows separate", function()
    local block = block_from_lines({
      "--- worklog #ClientA ---",
      "08:00 implementation !L",
      "09:00 implementation",
      "10:00 implementation !L",
      "11:00 done",
    })

    local items = summarize_exact(block).summary_items

    t.eq(items[1].logged, true)
    t.eq(items[1].source_entry_rows, { 2, 4 })
    t.eq(items[2].logged, nil)
    t.eq(items[2].source_entry_rows, { 3 })
  end)

  t.test("summary provenance records #ooo source rows on workday-excluded items", function()
    local block = block_from_lines({
      "--- worklog ---",
      "08:00 break #ooo",
      "09:00 plan",
      "10:00 break #ooo",
      "10:30 done",
    })

    local items = summarize_exact(block).summary_items
    local break_item

    for _, item in ipairs(items) do
      if item.text == "break" then
        break_item = item
      end
    end

    t.eq(break_item.workday_excluded, true)
    t.eq(break_item.source_entry_rows, { 2, 4 })
  end)

  t.test("quantized summary preserves source_entry_rows on visible main rows", function()
    local block = block_from_lines({
      "--- worklog #ClientA quantize=30 ---",
      "08:00 planning @office",
      "08:17 planning @home",
      "08:34 done",
    })

    local items = summary.summarize_block(block).summary_items

    t.eq(#items, 1)
    t.eq(items[1].text, "planning")
    t.eq(items[1].source_entry_rows, { 2, 3 })
  end)
end
