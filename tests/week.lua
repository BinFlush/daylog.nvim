return function(t)
  local week = require("daylog.week")

  t.test("multi-day report combines daily quantized summaries without re-quantizing", function()
    local report = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.day",
        lines = {
          "--- log #ClientA q=30 ---",
          "08:00 plan",
          "08:20 done",
        },
      },
      {
        date_label = "2026-05-19",
        path = "/tmp/2026-05-19.day",
        lines = {
          "--- log #ClientA q=60 ---",
          "08:00 plan",
          "08:20 done",
        },
      },
    })

    t.eq(report, {
      days = {
        {
          date_label = "2026-05-18",
          path = "/tmp/2026-05-18.day",
          quantize_minutes = 30,
          summary = {
            summary_items = {
              {
                text = "plan",
                tag = "ClientA",
                duration = 30,
                unrounded_duration = 20,
                error_minutes = -10,
                workday_excluded = false,
                source_entry_rows = { 2 },
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
                location = nil,
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
                workday_excluded = false,
              },
            },
            activity_total = 30,
            workday_total = 30,
            tag_total = 30,
            location_total = 30,
            activity_error_minutes = -10,
            workday_error_minutes = -10,
          },
        },
        {
          date_label = "2026-05-19",
          path = "/tmp/2026-05-19.day",
          quantize_minutes = 60,
          summary = {
            summary_items = {
              {
                text = "plan",
                tag = "ClientA",
                duration = 0,
                unrounded_duration = 20,
                error_minutes = 20,
                workday_excluded = false,
                source_entry_rows = { 2 },
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
                location = nil,
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
                workday_excluded = false,
              },
            },
            activity_total = 0,
            workday_total = 0,
            tag_total = 0,
            location_total = 0,
            activity_error_minutes = 20,
            workday_error_minutes = 20,
          },
        },
      },
      summary = {
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
            location = nil,
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
            workday_excluded = false,
          },
        },
        activity_total = 30,
        workday_total = 30,
        tag_total = 30,
        location_total = 30,
        activity_error_minutes = 10,
        workday_error_minutes = 10,
      },
    })
  end)

  t.test("multi-day report preserves the logged flag through daily recomputation", function()
    -- A bare `!S` flags the row as logged without splitting; aggregating across days keeps the
    -- flag and foots to one honest row.
    local report = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.day",
        lines = {
          "--- log #ClientA q=30 ---",
          "08:00 plan !S",
          "08:20 plan",
          "08:40 done",
        },
      },
      {
        date_label = "2026-05-19",
        path = "/tmp/2026-05-19.day",
        lines = {
          "--- log #ClientA q=30 ---",
          "08:00 plan !S",
          "08:20 done",
        },
      },
    })

    t.eq(report.summary, {
      summary_items = {
        {
          text = "plan",
          tag = "ClientA",
          duration = 60,
          unrounded_duration = 60,
          error_minutes = 0,
          workday_excluded = false,
          logged = true,
        },
      },
      tag_totals = {
        {
          tag = "ClientA",
          duration = 60,
          unrounded_duration = 60,
          error_minutes = 0,
        },
      },
      location_totals = {
        {
          location = nil,
          duration = 60,
          unrounded_duration = 60,
          error_minutes = 0,
        },
      },
      total_rows = {
        {
          duration = 60,
          unrounded_duration = 60,
          error_minutes = 0,
          workday_excluded = false,
        },
      },
      activity_total = 60,
      workday_total = 60,
      tag_total = 60,
      location_total = 60,
      activity_error_minutes = 0,
      workday_error_minutes = 0,
    })
  end)

  t.test("build_report skips missing and empty files", function()
    local report = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.day",
        lines = nil,
      },
      {
        date_label = "2026-05-19",
        path = "/tmp/2026-05-19.day",
        lines = { "" },
      },
      {
        date_label = "2026-05-20",
        path = "/tmp/2026-05-20.day",
        lines = {
          "--- log ---",
          "08:00 plan",
          "09:00 done",
        },
      },
    })

    t.eq(#report.days, 1)
    t.eq(report.days[1].date_label, "2026-05-20")
    t.eq(report.summary.activity_total, 60)
    t.eq(report.summary.workday_total, 60)
  end)

  t.test("build_report aborts on invalid files and includes the file path", function()
    local report, err = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.day",
        lines = {
          "--- log ---",
          "09:00 done",
          "08:00 plan",
        },
      },
    })

    t.eq(report, nil)
    t.eq(
      err,
      "daylog: /tmp/2026-05-18.day: unordered timestamps near lines 2 and 3; fix manually or run :Daylog order"
    )
  end)

  t.test("build_report skips a prose-only day with no log", function()
    local report = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.day",
        lines = { "Holiday - no work" },
      },
      {
        date_label = "2026-05-19",
        path = "/tmp/2026-05-19.day",
        lines = {
          "--- log ---",
          "08:00 plan",
          "09:00 done",
        },
      },
    })

    t.eq(#report.days, 1)
    t.eq(report.days[1].date_label, "2026-05-19")
    t.eq(report.summary.workday_total, 60)
  end)

  t.test("build_report aborts on timestamped entries with no log header", function()
    local report, err = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.day",
        lines = {
          "08:00 plan",
          "09:00 done",
        },
      },
    })

    t.eq(report, nil)
    t.eq(
      err,
      "daylog: /tmp/2026-05-18.day: no log block found; first line must be a "
        .. "log header such as --- log --- or --- log #ClientA @office q=30 ---"
    )
  end)

  t.test("build_report reports the generalized no-data error", function()
    local report, err = week.build_report({})

    t.eq(report, nil)
    t.eq(err, "daylog: no daybook logs found")
  end)

  t.test("days report derives trailing daybook paths through one helper", function()
    local seen_paths = {}
    local now = os.time({
      year = 2026,
      month = 5,
      day = 22,
      hour = 12,
      min = 0,
      sec = 0,
    })

    local report = week.build_days_report(
      {
        root = "/tmp/timereg",
        directory = "%Y/%V",
      },
      now,
      3,
      function(path)
        table.insert(seen_paths, path)

        if path == "/tmp/timereg/2026/21/2026-05-22.day" then
          return {
            "--- log ---",
            "08:00 plan",
            "09:00 done",
          }
        end

        return nil
      end
    )

    t.eq(seen_paths, {
      "/tmp/timereg/2026/21/2026-05-20.day",
      "/tmp/timereg/2026/21/2026-05-21.day",
      "/tmp/timereg/2026/21/2026-05-22.day",
    })
    -- The label resolves to the span of days actually found (only 05-22 here), with a
    -- found-day count, not the requested trailing bounds.
    t.eq(report.period_label, "2026-05-22..2026-05-22 (1 found)")
    t.eq(#report.days, 1)
    t.eq(report.days[1].date_label, "2026-05-22")
  end)
end
