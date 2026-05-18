return function(t)
  local week = require("worklog.week")

  t.test("week report combines daily quantized summaries without re-quantizing", function()
    local report = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.wkl",
        lines = {
          "--- worklog #ClientA quantize=30 ---",
          "08:00 plan",
          "08:20 done",
        },
      },
      {
        date_label = "2026-05-19",
        path = "/tmp/2026-05-19.wkl",
        lines = {
          "--- worklog #ClientA quantize=60 ---",
          "08:00 plan",
          "08:20 done",
        },
      },
    }, "2026-W21")

    t.eq(report, {
      week_label = "2026-W21",
      days = {
        {
          date_label = "2026-05-18",
          path = "/tmp/2026-05-18.wkl",
          summary = {
            summary_items = {
              {
                text = "plan",
                tag = "ClientA",
                duration = 30,
                exact_duration = 20,
                error_minutes = -10,
                workday_excluded = false,
              },
            },
            tag_totals = {
              {
                tag = "ClientA",
                duration = 30,
                exact_duration = 20,
                error_minutes = -10,
              },
            },
            location_totals = {
              {
                location = nil,
                duration = 30,
                exact_duration = 20,
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
          path = "/tmp/2026-05-19.wkl",
          summary = {
            summary_items = {
              {
                text = "plan",
                tag = "ClientA",
                duration = 0,
                exact_duration = 20,
                error_minutes = 20,
                workday_excluded = false,
              },
            },
            tag_totals = {
              {
                tag = "ClientA",
                duration = 0,
                exact_duration = 20,
                error_minutes = 20,
              },
            },
            location_totals = {
              {
                location = nil,
                duration = 0,
                exact_duration = 20,
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
            exact_duration = 40,
            error_minutes = 10,
            workday_excluded = false,
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 30,
            exact_duration = 40,
            error_minutes = 10,
          },
        },
        location_totals = {
          {
            location = nil,
            duration = 30,
            exact_duration = 40,
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

  t.test("week report skips missing and empty files", function()
    local report = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.wkl",
        lines = nil,
      },
      {
        date_label = "2026-05-19",
        path = "/tmp/2026-05-19.wkl",
        lines = { "" },
      },
      {
        date_label = "2026-05-20",
        path = "/tmp/2026-05-20.wkl",
        lines = {
          "--- worklog ---",
          "08:00 plan",
          "09:00 done",
        },
      },
    }, "2026-W21")

    t.eq(#report.days, 1)
    t.eq(report.days[1].date_label, "2026-05-20")
    t.eq(report.summary.activity_total, 60)
    t.eq(report.summary.workday_total, 60)
  end)

  t.test("week report aborts on invalid files and includes the file path", function()
    local report, err = week.build_report({
      {
        date_label = "2026-05-18",
        path = "/tmp/2026-05-18.wkl",
        lines = {
          "--- worklog ---",
          "09:00 done",
          "08:00 plan",
        },
      },
    }, "2026-W21")

    t.eq(report, nil)
    t.eq(
      err,
      "worklog: /tmp/2026-05-18.wkl: unordered timestamps near lines 2 and 3; fix manually or run :WorklogOrder"
    )
  end)

  t.test("week report derives monday to sunday journal paths through one helper", function()
    local seen_paths = {}
    local now = os.time({
      year = 2026,
      month = 5,
      day = 22,
      hour = 12,
      min = 0,
      sec = 0,
    })

    local report = week.build_journal_report(
      {
        root = "/tmp/timereg",
        directory = "%Y/%V",
      },
      now,
      function(path)
        table.insert(seen_paths, path)

        if path == "/tmp/timereg/2026/21/2026-05-18.wkl" then
          return {
            "--- worklog ---",
            "08:00 plan",
            "09:00 done",
          }
        end

        return nil
      end
    )

    t.eq(seen_paths, {
      "/tmp/timereg/2026/21/2026-05-18.wkl",
      "/tmp/timereg/2026/21/2026-05-19.wkl",
      "/tmp/timereg/2026/21/2026-05-20.wkl",
      "/tmp/timereg/2026/21/2026-05-21.wkl",
      "/tmp/timereg/2026/21/2026-05-22.wkl",
      "/tmp/timereg/2026/21/2026-05-23.wkl",
      "/tmp/timereg/2026/21/2026-05-24.wkl",
    })
    t.eq(report.week_label, "2026-W21")
    t.eq(#report.days, 1)
    t.eq(report.days[1].date_label, "2026-05-18")
  end)
end
