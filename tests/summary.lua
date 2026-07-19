return function(t)
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")
  local summary = require("daylog.summary")
  local render = require("daylog.render")

  local function block_from_lines(lines)
    local analysis = analyze.analyze(document.parse(lines))
    return analysis.log_blocks[1]
  end

  local function block_at(lines, index)
    local analysis = analyze.analyze(document.parse(lines))
    return analysis.log_blocks[index]
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

  -- The single summary type is quantized; "exact" is just q=1 (rounding is a no-op on whole-minute
  -- durations). These helpers assert the unrounded SHAPE, so they compute at q=1 and drop the
  -- now-zero error fields, the echoed bucket, and the coarser sections' provenance (asserted on its
  -- own; the main rows keep theirs).
  -- The echoed bucket and the coarser sections' provenance are derived plumbing, asserted on their
  -- own; a shape assertion drops them so it reads as the report the user sees.
  local function shape(result)
    local groups = { result.tag_totals, result.location_totals, result.total_rows }
    for _, group in ipairs(groups) do
      for _, item in ipairs(group) do
        item.source_entry_rows = nil
      end
    end
    result.bucket_minutes = nil
    return result
  end

  local function strip_errors(result)
    shape(result)
    local groups =
      { result.summary_items, result.tag_totals, result.location_totals, result.total_rows }

    for _, group in ipairs(groups) do
      for _, item in ipairs(group) do
        item.error_minutes = nil
      end
    end

    result.activity_error_minutes = nil
    return result
  end

  local function summarize_exact_entries(entries)
    return strip_errors(summary.summarize_entries(entries, 1))
  end

  local function summarize_exact(block)
    return summarize_exact_entries(block.entries)
  end

  t.test("summary summarizes semantic log blocks directly", function()
    local block = block_from_lines({
      "--- log #ProjectOrion @office ---",
      "08:00 plan",
      "08:30 call #sales @client",
      "09:00",
      "09:15 done #ProjectOrion @office",
    })

    t.eq(summarize_exact(block), {
      summary_items = {
        {
          text = "plan",
          tag = "ProjectOrion",
          location = "office",
          duration = 30,
          unrounded_duration = 30,
          source_entry_rows = { 2 },
        },
        {
          text = "call",
          tag = "sales",
          location = "client",
          duration = 30,
          unrounded_duration = 30,
          source_entry_rows = { 3 },
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
      },
      location_totals = {
        {
          location = "office",
          duration = 30,
          unrounded_duration = 30,
        },
        {
          location = "client",
          duration = 30,
          unrounded_duration = 30,
        },
      },
      total_rows = {
        {
          duration = 60,
          unrounded_duration = 60,
        },
      },
      activity_total = 60,
    })
  end)

  t.test("summary treats cleared metadata as untagged and no location", function()
    local block = block_from_lines({
      "--- log ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
    })

    t.eq(summarize_exact(block), {
      summary_items = {
        {
          text = "break",
          tag = "ooo",
          location = "home",
          duration = 60,
          unrounded_duration = 60,
          source_entry_rows = { 2 },
        },
        {
          text = "resume",
          tag = nil,
          duration = 60,
          unrounded_duration = 60,
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
      total_rows = {
        {
          duration = 120,
          unrounded_duration = 120,
        },
      },
      activity_total = 120,
    })
  end)

  t.test("quantized summary supports 60 minute rounding", function()
    local block = block_from_lines({
      "--- log @office q=60 ---",
      "08:00 plan",
      "08:20 call #sales @client",
      "09:00 done",
    })

    t.eq(shape(summary.summarize_block(block)), {
      summary_items = {
        {
          text = "call",
          tag = "sales",
          location = "client",
          duration = 60,
          unrounded_duration = 40,
          error_minutes = -20,
          source_entry_rows = { 3 },
        },
        {
          text = "plan",
          tag = nil,
          location = "office",
          duration = 0,
          unrounded_duration = 20,
          error_minutes = 20,
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
      total_rows = {
        {
          duration = 60,
          unrounded_duration = 60,
          error_minutes = 0,
        },
      },
      activity_total = 60,
      activity_error_minutes = 0,
    })
  end)

  local function render_block(block)
    return render.summary_lines(summary.summarize_block(block), block.duration_format, {
      leading_blank = false,
      quantize_minutes = block.quantize_minutes,
    })
  end

  t.test("a numeric commitment above a cell's honest total inflates and propagates", function()
    -- #Beta honest 90, committed !T[]120: there is no unlogged slack to absorb into, so the
    -- surplus inflates the cell and propagates -- `design review` and `@home` rise to 120 and
    -- the activity total to 270. One logged row, no unlogged remainder.
    local block = block_from_lines({
      "--- log q=15 ---",
      "09:00 standup #Acme @office",
      "09:30 auth bugfix #Acme @office",
      "11:30",
      "12:00 design review #Beta @home !T[]120",
      "13:30 done",
    })

    t.eq(render_block(block), {
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) auth bugfix",
      "2.00h (-30m) design review",
      "0.50h (+0m) standup",
      "",
      "--- tags ---",
      "2.50h (+0m) #Acme",
      "2.00h (-30m) #Beta !T[]",
      "",
      "--- locations ---",
      "2.50h (+0m) @office",
      "2.00h (-30m) @home",
      "",
      "--- totals ---",
      "4.50h (-30m) workday",
    })

    assert_activity_totals_match(t, summary.summarize_block(block))
  end)

  t.test("tag and location sections order rows by descending duration", function()
    -- A tag with a small logged (!T[]10) slice and a large unlogged slice: the sections
    -- sort purely by duration, so the larger unlogged row comes first. (There is no
    -- separate logged section any more and no logged-first ordering.)
    local block = block_from_lines({
      "--- log #ClientA q=30 ---",
      "08:00 implementation !T[]10",
      "08:10 implementation",
      "09:00 done",
    })

    local result = summary.summarize_block(block)

    t.eq(#result.tag_totals, 2)
    -- Logged slice = 10m, unlogged = 50m; the larger (unlogged) row sorts first.
    t.ok(result.tag_totals[1].duration >= result.tag_totals[2].duration, "sorted descending")
    t.eq(result.tag_totals[1].logged, nil)
    t.eq(result.tag_totals[2].logged, true)
  end)

  t.test("logging a manually-rounded row does not move an un-frozen row", function()
    -- thing two is manually rounded down (round-1) then logged at that value (!S[]60). The
    -- un-frozen "thing one" must keep its own honest 60 -- the nudge's residual lands on
    -- the total (120, not the abstract round(128) = 135), never on an unrelated row.
    local s = summary.summarize_entries(
      block_from_lines({
        "--- log ---",
        "08:00 thing one",
        "09:00 thing two round-1 !S[]60",
        "10:08 done",
      }).entries,
      15
    )

    local by_text = {}
    for _, item in ipairs(s.summary_items) do
      by_text[item.text] = item
    end
    t.eq(by_text["thing one"].duration, 60)
    t.eq(by_text["thing one"].error_minutes, 0)
    t.eq(by_text["thing two"].duration, 60)
    t.eq(by_text["thing two"].error_minutes, 8)
    -- The manual round-1 nudge lands on the totals row, not on the frozen logged row (a
    -- committed slice is displayed at its pinned value and carries no per-row nudge).
    t.eq(s.total_rows[#s.total_rows].nudge, -1)
    t.eq(by_text["thing two"].logged, true)
    t.eq(s.activity_total, 120)

    -- The main summary splits by !S[]: thing two logged (60), thing one unlogged (60).
    t.eq(by_text["thing one"].logged, nil)
    t.eq(by_text["thing one"].duration, 60)
    t.eq(by_text["thing two"].duration, 60)
  end)

  t.test(
    "a named !S[] slice and its bare same-activity sibling sum to the activity total",
    function()
      local result = summary.summarize_block(block_from_lines({
        "--- log q=15 ---",
        "08:00 build !S[a]30",
        "08:30 build",
        "09:30 done",
      }))
      local total, named, bare = 0, nil, nil
      for _, row in ipairs(result.summary_items) do
        total = total + row.duration
        if row.names then
          named = row
        else
          bare = row
        end
      end
      t.eq(named.duration, 30)
      t.eq(named.logged, true)
      t.eq(named.names, { "a" })
      t.eq(bare.duration, 60)
      t.eq(bare.logged, nil)
      t.eq(total, result.activity_total)
      t.eq(result.activity_total, 90)
      assert_activity_totals_match(t, result)
    end
  )

  t.test("combine_summaries keeps name-split rows separate and merges same-name rows", function()
    local day1 = summary.summarize_block(block_from_lines({
      "--- log q=15 ---",
      "08:00 x #obs !T[a]60",
      "09:00 y #obs !T[b]30",
      "09:30 done",
    }))
    local day2 = summary.summarize_block(block_from_lines({
      "--- log q=15 ---",
      "08:00 z #obs !T[a]45",
      "08:45 done",
    }))
    local combined = summary.combine_summaries({ day1, day2 })
    t.eq(combined.activity_total, 135)

    local by_names = {}
    for _, row in ipairs(combined.tag_totals) do
      t.eq(row.tag, "obs")
      by_names[table.concat(row.names or {}, ",")] = row.duration
    end
    t.eq(by_names["a"], 105) -- merged across both days
    t.eq(by_names["b"], 30) -- kept separate from the [a] slice
    t.eq(total_duration(combined.tag_totals), combined.activity_total)
  end)

  t.test("a cross-cutting infeasible commitment renders honestly and foots", function()
    -- !T[]120 and !L[]90 commit the same 60m granule to contradictory over-values (non-laminar); the
    -- quantizer can't satisfy both, so it falls back to the honest quantization -- every section foots
    -- to 60 -- rather than fabricating a value that breaks footing.
    local result = summary.summarize_block(block_from_lines({
      "--- log q=15 ---",
      "09:00 work #T @L !T[]120 !L[]90",
      "10:00 stop",
    }))
    t.eq(result.activity_total, 60)
    assert_activity_totals_match(t, result)
    t.eq(total_duration(result.total_rows), 60)
  end)

  t.test("a !W claim states the day's total and every section foots to it", function()
    -- Both counted entries are on the timesheet at 90 minutes; the clock measured 120, and that gap
    -- is what every section's residual reports. The claim covers the whole counted day, so no plain
    -- workday row remains.
    local result = summary.summarize_block(block_from_lines({
      "--- log q=15 ---",
      "08:00 a #x @o !W[]90",
      "09:00 b #y @o !W[]90",
      "10:00",
      "10:30 done",
    }))
    t.eq(result.activity_total, 90)
    assert_activity_totals_match(t, result)
    t.eq(#result.total_rows, 1)
    t.eq(result.total_rows[1].logged, true)
    t.eq(result.total_rows[1].duration, 90)
    t.eq(result.total_rows[1].error_minutes, 30)
  end)

  t.test("a !W claim on some entries leaves the rest a plain workday row", function()
    -- Only the morning is on the timesheet; the afternoon stays in the plain remainder row, and the
    -- two rows partition the day.
    local result = summary.summarize_block(block_from_lines({
      "--- log q=15 ---",
      "08:00 a !W[]45",
      "09:00 b",
      "10:00",
    }))
    t.eq(#result.total_rows, 2)
    local claimed, plain
    for _, row in ipairs(result.total_rows) do
      if row.logged then
        claimed = row
      else
        plain = row
      end
    end
    t.eq(claimed.duration, 45)
    t.eq(claimed.error_minutes, 15)
    t.eq(plain.duration, 60)
    t.eq(plain.error_minutes, 0)
    t.eq(result.activity_total, 105)
    assert_activity_totals_match(t, result)
  end)

  t.test("a blank entry (bare timestamp) is uncounted -- excluded from every section", function()
    -- The 11:00 blank marks an uncounted gap (11:00-13:00); a note may follow it. Only the three real
    -- activities are counted, and every section foots to their total.
    local result = summary.summarize_block(block_from_lines({
      "--- log q=15 ---",
      "08:00 started working",
      "09:00 more work",
      "11:00",
      "    a comment about free time",
      "13:00 came back",
      "16:00",
    }))
    t.eq(result.activity_total, 360) -- 60 + 120 + 180; the 2h gap is excluded
    assert_activity_totals_match(t, result)
    for _, item in ipairs(result.summary_items) do
      t.ok(item.text ~= "" and item.text ~= nil, "no blank row leaks into the summary")
    end
  end)

  t.test("quantized summary uses the selected block quantize", function()
    local block = block_at({
      "--- log @office q=30 ---",
      "08:00 plan",
      "08:12 call #sales @client",
      "08:30 done",
      "--- log @office q=60 ---",
      "09:00 plan",
      "09:20 call #sales @client",
      "10:00 done",
    }, 2)

    t.eq(shape(summary.summarize_block(block)), {
      summary_items = {
        {
          text = "call",
          tag = "sales",
          location = "client",
          duration = 60,
          unrounded_duration = 40,
          error_minutes = -20,
          source_entry_rows = { 7 },
        },
        {
          text = "plan",
          tag = nil,
          location = "office",
          duration = 0,
          unrounded_duration = 20,
          error_minutes = 20,
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
      total_rows = {
        {
          duration = 60,
          unrounded_duration = 60,
          error_minutes = 0,
        },
      },
      activity_total = 60,
      activity_error_minutes = 0,
    })
  end)

  t.test("quantized summary derives item tag and location totals from one shared base", function()
    local block = block_from_lines({
      "--- log q=30 ---",
      "08:00 alpha #A @x",
      "08:17 beta #B @y",
      "08:34 gamma #C @x",
      "08:51 done",
    })

    local quantized = shape(summary.summarize_block(block))

    t.eq(quantized, {
      summary_items = {
        {
          text = "alpha",
          tag = "A",
          location = "x",
          duration = 30,
          unrounded_duration = 17,
          error_minutes = -13,
          source_entry_rows = { 2 },
        },
        {
          text = "beta",
          tag = "B",
          location = "y",
          duration = 30,
          unrounded_duration = 17,
          error_minutes = -13,
          source_entry_rows = { 3 },
        },
        {
          text = "gamma",
          tag = "C",
          location = "x",
          duration = 0,
          unrounded_duration = 17,
          error_minutes = 17,
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
      total_rows = {
        {
          duration = 60,
          unrounded_duration = 51,
          error_minutes = -9,
        },
      },
      activity_total = 60,
      activity_error_minutes = -9,
    })

    assert_activity_totals_match(t, quantized)
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
          total_rows = {
            {
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
            },
          },
          activity_total = 30,
          activity_error_minutes = -10,
        },
        {
          summary_items = {
            {
              text = "plan",
              tag = "ClientA",
              duration = 0,
              unrounded_duration = 20,
              error_minutes = 20,
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
          total_rows = {
            {
              duration = 0,
              unrounded_duration = 20,
              error_minutes = 20,
            },
          },
          activity_total = 0,
          activity_error_minutes = 20,
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
        total_rows = {
          {
            duration = 30,
            unrounded_duration = 40,
            error_minutes = 10,
          },
        },
        activity_total = 30,
        activity_error_minutes = 10,
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
          total_rows = {
            {
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
            },
          },
          activity_total = 30,
          activity_error_minutes = -10,
        },
        {
          summary_items = {
            {
              text = "plan",
              tag = "ClientA",
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
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
          total_rows = {
            {
              duration = 30,
              unrounded_duration = 20,
              error_minutes = -10,
            },
          },
          activity_total = 30,
          activity_error_minutes = -10,
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
            logged = true,
          },
          {
            text = "plan",
            tag = "ClientA",
            duration = 30,
            unrounded_duration = 20,
            error_minutes = -10,
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
        total_rows = {
          {
            duration = 60,
            unrounded_duration = 40,
            error_minutes = -20,
          },
        },
        activity_total = 60,
        activity_error_minutes = -20,
      }
    )
  end)

  t.test("combined quantized summaries preserve logged main-row separation", function()
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
              logged = true,
            },
            {
              text = "implementation",
              tag = "ClientA",
              duration = 0,
              unrounded_duration = 20,
              error_minutes = 20,
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
          total_rows = {
            {
              duration = 30,
              unrounded_duration = 40,
              error_minutes = 10,
            },
          },
          activity_total = 30,
          activity_error_minutes = 10,
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
            logged = true,
          },
          {
            text = "implementation",
            tag = "ClientA",
            duration = 0,
            unrounded_duration = 20,
            error_minutes = 20,
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
        total_rows = {
          {
            duration = 30,
            unrounded_duration = 40,
            error_minutes = 10,
          },
        },
        activity_total = 30,
        activity_error_minutes = 10,
      }
    )
  end)

  t.test(
    "combined main summary rows follow combined visible rows instead of re-quantizing",
    function()
      -- Each day: impl !S[] = 20 exact, impl = 20 exact, bucket = 30.
      -- Tie on remainder; first-seen (logged=true) gets the single extra bucket.
      -- Per-day result: logged main row = 30, unlogged = 0.
      --
      -- Combined visible main rows: logged = 60, unlogged = 0.
      --
      -- If the logged and unlogged main rows were independently re-quantized after
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
            logged = true,
          },
          {
            text = "implementation",
            tag = "ClientA",
            duration = 0,
            unrounded_duration = 20,
            error_minutes = 20,
          },
        },
        tag_totals = {
          { tag = "ClientA", duration = 30, unrounded_duration = 40, error_minutes = 10 },
        },
        location_totals = {
          { location = nil, duration = 30, unrounded_duration = 40, error_minutes = 10 },
        },
        total_rows = {
          { duration = 30, unrounded_duration = 40, error_minutes = 10 },
        },
        activity_total = 30,
        activity_error_minutes = 10,
      }

      t.eq(summary.combine_summaries({ day, day }), {
        summary_items = {
          {
            text = "implementation",
            tag = "ClientA",
            duration = 60,
            unrounded_duration = 40,
            error_minutes = -20,
            logged = true,
          },
          {
            text = "implementation",
            tag = "ClientA",
            duration = 0,
            unrounded_duration = 40,
            error_minutes = 40,
          },
        },
        tag_totals = {
          { tag = "ClientA", duration = 60, unrounded_duration = 80, error_minutes = 20 },
        },
        location_totals = {
          { location = nil, duration = 60, unrounded_duration = 80, error_minutes = 20 },
        },
        total_rows = {
          { duration = 60, unrounded_duration = 80, error_minutes = 20 },
        },
        activity_total = 60,
        activity_error_minutes = 20,
      })
    end
  )

  t.test(
    "summary keeps same-text different-tag rows adjacent and sorts by combined duration",
    function()
      local block = block_from_lines({
        "--- log ---",
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
          source_entry_rows = { 4 },
        },
        {
          text = "meeting",
          tag = "ClientA",
          duration = 60,
          unrounded_duration = 60,
          source_entry_rows = { 2 },
        },
        {
          text = "implementation",
          tag = "ClientA",
          duration = 180,
          unrounded_duration = 180,
          source_entry_rows = { 3 },
        },
      })
    end
  )

  t.test("summary preserves stable order when text groups tie completely", function()
    local block = block_from_lines({
      "--- log ---",
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
        source_entry_rows = { 2 },
      },
      {
        text = "beta",
        tag = nil,
        duration = 60,
        unrounded_duration = 60,
        source_entry_rows = { 3 },
      },
    })
  end)

  t.test("summary preserves stable order within same-text tag ties", function()
    local block = block_from_lines({
      "--- log ---",
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
        source_entry_rows = { 2 },
      },
      {
        text = "meeting",
        tag = "internal",
        duration = 60,
        unrounded_duration = 60,
        source_entry_rows = { 4 },
      },
      {
        text = "other",
        tag = "ClientA",
        duration = 60,
        unrounded_duration = 60,
        source_entry_rows = { 3 },
      },
    })
  end)

  t.test("summary keeps activity text containing pipes separate", function()
    local block = block_from_lines({
      "--- log ---",
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
        source_entry_rows = { 2 },
      },
      {
        text = "alpha",
        tag = "beta",
        duration = 60,
        unrounded_duration = 60,
        source_entry_rows = { 3 },
      },
    })
  end)

  t.test("summary provenance points back to the entry rows that fed each item", function()
    local block = block_from_lines({
      "--- log ---",
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
    -- Numeric commitments split the cell: the logged slice carries the marked rows (2, 4)
    -- and the unlogged remainder carries the plain row (3). Committing 120 keeps the logged
    -- slice larger than the 60m remainder, so it sorts first.
    local block = block_from_lines({
      "--- log #ClientA ---",
      "08:00 implementation !S[]120",
      "09:00 implementation",
      "10:00 implementation !S[]120",
      "11:00 done",
    })

    local items = summarize_exact(block).summary_items

    t.eq(items[1].logged, true)
    t.eq(items[1].source_entry_rows, { 2, 4 })
    t.eq(items[2].logged, nil)
    t.eq(items[2].source_entry_rows, { 3 })
  end)

  t.test("summary provenance folds a repeated activity's source rows into one item", function()
    local block = block_from_lines({
      "--- log ---",
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

    t.eq(break_item.tag, "ooo")
    t.eq(break_item.source_entry_rows, { 2, 4 })
  end)

  t.test("quantized summary preserves source_entry_rows on visible main rows", function()
    -- One activity in two places is two rows -- the granule is (label, tag, location) -- and each
    -- carries the entries behind it.
    local block = block_from_lines({
      "--- log #ClientA q=30 ---",
      "08:00 planning @office",
      "08:17 planning @home",
      "08:34 done",
    })

    local items = summary.summarize_block(block).summary_items

    t.eq(#items, 2)
    t.eq(items[1].text, "planning")
    t.eq(items[1].source_entry_rows, { 2 })
    t.eq(items[2].source_entry_rows, { 3 })
  end)

  t.test("one activity in one place stays a single row carrying both entries", function()
    local block = block_from_lines({
      "--- log #ClientA q=30 ---",
      "08:00 planning @office",
      "08:17 planning @office",
      "08:34 done",
    })

    local items = summary.summarize_block(block).summary_items

    t.eq(#items, 1)
    t.eq(items[1].source_entry_rows, { 2, 3 })
  end)

  local function durations_by_text(items)
    local by_text = {}
    for _, item in ipairs(items) do
      by_text[item.text] = item.duration
    end
    return by_text
  end

  t.test("summary reconciles durations across a utc offset change (travel)", function()
    -- 14:00@+2 = 12:00Z, 11:00@-4 = 15:00Z, 17:00@-4 = 21:00Z. So "leave" spans
    -- 12:00Z->15:00Z = 3h and "resume" 15:00Z->21:00Z = 6h, where the raw local
    -- delta for "leave" would be a nonsensical -3h.
    local block = block_from_lines({
      "--- log utc+2 ---",
      "14:00 leave",
      "11:00 resume utc-4",
      "17:00 done",
    })
    local result = summarize_exact(block)
    local by_text = durations_by_text(result.summary_items)

    t.eq(result.activity_total, 540) -- 9h, not the 3h the raw local clock implies
    t.eq(by_text.leave, 180)
    t.eq(by_text.resume, 360)
  end)

  t.test("summary reconciles a DST fall-back where the local clock repeats", function()
    -- Fall back: 02:45@+2 = 00:45Z, then 02:15@+1 = 01:15Z. The local clock appears
    -- to step backward (02:45 -> 02:15) but the real interval is 30 minutes.
    local block = block_from_lines({
      "--- log utc+2 ---",
      "02:45 wind down",
      "02:15 still up utc+1",
      "03:00 sleep",
    })
    local by_text = durations_by_text(summarize_exact(block).summary_items)

    t.eq(by_text["wind down"], 30) -- 00:45Z -> 01:15Z
    t.eq(by_text["still up"], 45) -- 01:15Z -> 03:00@+1 = 02:00Z
  end)

  t.test("a uniform header offset summarizes identically to no offset", function()
    -- The zero-overhead invariant: within one zone the base offset cancels in every
    -- delta, so declaring utc+2 throughout matches a log with no offset at all.
    local entries = { "08:00 plan", "08:30 call #sales", "09:15 done" }
    local plain = block_from_lines({
      "--- log #ClientA @office ---",
      entries[1],
      entries[2],
      entries[3],
    })
    local zoned = block_from_lines({
      "--- log #ClientA @office utc+2 ---",
      entries[1],
      entries[2],
      entries[3],
    })

    t.eq(summarize_exact(zoned), summarize_exact(plain))
  end)

  t.test("a manual round nudge shifts a row and its totals by one q-step", function()
    -- A 50-min task floors to 0.75h (+5m) at q=15; round+1 forces it up one bucket.
    local block = block_from_lines({
      "--- log #ClientA @office q=15 ---",
      "08:00 task round+1",
      "08:50 done",
    })
    local s = summary.summarize_block(block)

    t.eq(s.summary_items[1].duration, 60) -- 1.00h, one bucket above the floor
    t.eq(s.summary_items[1].error_minutes, -10) -- 50 true - 60 displayed
    t.eq(s.summary_items[1].nudge, 1)
    t.eq(s.activity_total, 60)
    t.eq(s.total_rows[1].nudge, 1)

    -- The nudge flows into the tag and location totals too -- they are the same time under a
    -- different grouping -- so each section inherits the shift and stays footed with the balanced main.
    t.eq(total_duration(s.tag_totals), 60)
    t.eq(s.tag_totals[1].nudge, 1)
    t.eq(total_duration(s.location_totals), 60)
    t.eq(s.location_totals[1].nudge, 1)
  end)

  t.test("a no-nudge log summarizes with no nudge fields (zero overhead)", function()
    local block = block_from_lines({
      "--- log #ClientA @office q=15 ---",
      "08:00 task",
      "08:50 done",
    })
    local s = summary.summarize_block(block)

    t.eq(s.summary_items[1].nudge, nil)
    t.eq(s.total_rows[1].nudge, nil)
  end)

  t.test("a manual nudge keeps each section a partition that sums to its total", function()
    local block = block_from_lines({
      "--- log #ClientA @office q=15 ---",
      "08:00 plan",
      "08:50 review round+1",
      "09:35 done",
    })
    local s = summary.summarize_block(block)

    t.eq(total_duration(s.summary_items), s.activity_total)
    t.eq(total_duration(s.tag_totals), s.activity_total)
    t.eq(total_duration(s.location_totals), s.activity_total)
  end)

  t.test("a nudge on one day reconciles the combined week total and residual", function()
    -- Three single-task days each floor to 0.75h (+5m); a round+1 on the third lifts
    -- the week from 2.25h (+15m) to a clean 2.50h (+0m) -- the user's scenario.
    local function day(lines)
      return summary.summarize_block(block_from_lines(lines))
    end
    local mon = day({ "--- log #ClientA q=15 ---", "08:00 plan", "08:50 done" })
    local tue = day({ "--- log #ClientA q=15 ---", "08:00 review", "08:50 done" })
    local fri = day({ "--- log #ClientA q=15 ---", "08:00 wrapup round+1", "08:50 done" })

    local week = summary.combine_summaries({ mon, tue, fri })
    t.eq(week.activity_total, 150) -- 45 + 45 + 60 = 2.50h
    t.eq(week.activity_error_minutes, 0) -- +5 +5 -10 cancel
  end)

  t.test("summary groups aliased entries under their target label", function()
    -- Two different descriptions aliased to one label merge into a single row, labeled
    -- and counted by the alias; an unaliased activity is unaffected.
    local block = block_from_lines({
      "--- log ---",
      "08:00 fix login => BUG-1",
      "08:30 chase timeout => BUG-1",
      "09:00 standup",
      "09:15 done",
    })

    t.eq(summarize_exact(block).summary_items, {
      {
        text = "BUG-1",
        tag = nil,
        duration = 60,
        unrounded_duration = 60,
        source_entry_rows = { 2, 3 },
      },
      {
        text = "standup",
        tag = nil,
        duration = 15,
        unrounded_duration = 15,
        source_entry_rows = { 4 },
      },
    })
  end)
end
