return function(t)
  local week = require("blotter.week")

  t.test("week report combines daily quantized summaries without re-quantizing", function()
    local report = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.blot",
        lines = {
          "--- blots #ClientA q=30 ---",
          "08:00 plan",
          "08:20 done",
        },
      },
      {
        date_label = "2026-05-19",
        path = "/tmp/2026-05-19.blot",
        lines = {
          "--- blots #ClientA q=60 ---",
          "08:00 plan",
          "08:20 done",
        },
      },
    })

    t.eq(report, {
      days = {
        {
          date_label = "2026-05-18",
          path = "/tmp/2026-05-18.blot",
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
                source_blot_rows = { 2 },
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
            activity_total = 30,
            workday_total = 30,
            activity_error_minutes = -10,
            workday_error_minutes = -10,
          },
        },
        {
          date_label = "2026-05-19",
          path = "/tmp/2026-05-19.blot",
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
                source_blot_rows = { 2 },
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
            activity_total = 0,
            workday_total = 0,
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
        activity_total = 30,
        workday_total = 30,
        activity_error_minutes = 10,
        workday_error_minutes = 10,
      },
    })
  end)

  t.test("week report preserves logged separation through daily recomputation", function()
    local report = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.blot",
        lines = {
          "--- blots #ClientA q=30 ---",
          "08:00 plan !L",
          "08:20 plan",
          "08:40 done",
        },
      },
      {
        date_label = "2026-05-19",
        path = "/tmp/2026-05-19.blot",
        lines = {
          "--- blots #ClientA q=30 ---",
          "08:00 plan !L",
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
          unrounded_duration = 40,
          error_minutes = -20,
          workday_excluded = false,
          logged = true,
        },
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
      logged_totals = {
        {
          logged = true,
          duration = 60,
          unrounded_duration = 40,
          error_minutes = -20,
        },
        {
          logged = false,
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

  t.test("build_report skips missing and empty files", function()
    local report = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.blot",
        lines = nil,
      },
      {
        date_label = "2026-05-19",
        path = "/tmp/2026-05-19.blot",
        lines = { "" },
      },
      {
        date_label = "2026-05-20",
        path = "/tmp/2026-05-20.blot",
        lines = {
          "--- blots ---",
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
        path = "/tmp/2026-05-18.blot",
        lines = {
          "--- blots ---",
          "09:00 done",
          "08:00 plan",
        },
      },
    })

    t.eq(report, nil)
    t.eq(
      err,
      "blotter: /tmp/2026-05-18.blot: unordered timestamps near lines 2 and 3; fix manually or run :BlotterOrder"
    )
  end)

  t.test("build_report skips a prose-only day with no blotter", function()
    local report = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.blot",
        lines = { "Holiday - no work" },
      },
      {
        date_label = "2026-05-19",
        path = "/tmp/2026-05-19.blot",
        lines = {
          "--- blots ---",
          "08:00 plan",
          "09:00 done",
        },
      },
    })

    t.eq(#report.days, 1)
    t.eq(report.days[1].date_label, "2026-05-19")
    t.eq(report.summary.workday_total, 60)
  end)

  t.test("build_report aborts on timestamped blots with no blotter header", function()
    local report, err = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.blot",
        lines = {
          "08:00 plan",
          "09:00 done",
        },
      },
    })

    t.eq(report, nil)
    t.eq(
      err,
      "blotter: /tmp/2026-05-18.blot: no blotter block found; first line must be a "
        .. "blotter header such as --- blots --- or --- blots #ClientA @office q=30 ---"
    )
  end)

  t.test("build_report reports the generalized no-data error", function()
    local report, err = week.build_report({})

    t.eq(report, nil)
    t.eq(err, "blotter: no journal blotters found")
  end)

  t.test("build_week_report derives monday to sunday journal paths and label", function()
    local seen_paths = {}
    local now = os.time({
      year = 2026,
      month = 5,
      day = 22,
      hour = 12,
      min = 0,
      sec = 0,
    })

    local report = week.build_week_report(
      {
        root = "/tmp/timereg",
        directory = "%Y/%V",
      },
      now,
      function(path)
        table.insert(seen_paths, path)

        if path == "/tmp/timereg/2026/21/2026-05-18.blot" then
          return {
            "--- blots ---",
            "08:00 plan",
            "09:00 done",
          }
        end

        return nil
      end
    )

    t.eq(seen_paths, {
      "/tmp/timereg/2026/21/2026-05-18.blot",
      "/tmp/timereg/2026/21/2026-05-19.blot",
      "/tmp/timereg/2026/21/2026-05-20.blot",
      "/tmp/timereg/2026/21/2026-05-21.blot",
      "/tmp/timereg/2026/21/2026-05-22.blot",
      "/tmp/timereg/2026/21/2026-05-23.blot",
      "/tmp/timereg/2026/21/2026-05-24.blot",
    })
    t.eq(report.period_label, "2026-W21")
    t.eq(#report.days, 1)
    t.eq(report.days[1].date_label, "2026-05-18")
  end)

  t.test("days report derives trailing journal paths through one helper", function()
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

        if path == "/tmp/timereg/2026/21/2026-05-22.blot" then
          return {
            "--- blots ---",
            "08:00 plan",
            "09:00 done",
          }
        end

        return nil
      end
    )

    t.eq(seen_paths, {
      "/tmp/timereg/2026/21/2026-05-20.blot",
      "/tmp/timereg/2026/21/2026-05-21.blot",
      "/tmp/timereg/2026/21/2026-05-22.blot",
    })
    t.eq(report.period_label, "2026-05-20..2026-05-22")
    t.eq(#report.days, 1)
    t.eq(report.days[1].date_label, "2026-05-22")
  end)
end
