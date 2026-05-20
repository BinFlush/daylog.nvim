return function(t)
  local render = require("worklog.render")

  t.test("render omits location on main summary rows and shows tags only for conflicts", function()
    t.eq(
      render.summary_lines({
        summary_items = {
          {
            text = "planning",
            tag = "ClientA",
            duration = 60,
            exact_duration = 60,
            workday_excluded = false,
          },
          {
            text = "planning",
            tag = "internal",
            duration = 30,
            exact_duration = 30,
            workday_excluded = false,
          },
          {
            text = "implementation",
            tag = "ClientA",
            duration = 90,
            exact_duration = 90,
            workday_excluded = false,
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 150,
            exact_duration = 150,
          },
          {
            tag = "internal",
            duration = 30,
            exact_duration = 30,
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 120,
            exact_duration = 120,
          },
          {
            location = "home",
            duration = 60,
            exact_duration = 60,
          },
        },
        activity_total = 180,
        workday_total = 180,
      }, "exact"),
      {
        "",
        "--- summary exact ---",
        "1.00h planning #ClientA",
        "0.50h planning #internal",
        "1.50h implementation",
        "",
        "--- tags exact ---",
        "2.50h #ClientA",
        "0.50h #internal",
        "",
        "--- locations exact ---",
        "2.00h @office",
        "1.00h @home",
        "",
        "--- totals exact ---",
        "3.00h workday",
      }
    )
  end)

  t.test("render omits placeholder-only sections and activity when unnecessary", function()
    t.eq(
      render.summary_lines({
        summary_items = {
          {
            text = "plan",
            tag = nil,
            duration = 30,
            exact_duration = 30,
            error_minutes = 0,
            workday_excluded = false,
          },
        },
        tag_totals = {
          {
            tag = nil,
            duration = 30,
            exact_duration = 30,
            error_minutes = 0,
          },
        },
        location_totals = {
          {
            location = nil,
            duration = 30,
            exact_duration = 30,
            error_minutes = 0,
          },
        },
        activity_total = 30,
        workday_total = 30,
        activity_error_minutes = 0,
        workday_error_minutes = 0,
      }, "quantized"),
      {
        "",
        "--- summary quantized ---",
        "0.50h (+0m) plan",
        "",
        "--- totals quantized ---",
        "0.50h (+0m) workday",
      }
    )
  end)

  t.test("render preserves default quantized headers and sections", function()
    t.eq(
      render.summary_lines({
        summary_items = {
          {
            text = "client",
            tag = "ClientA",
            duration = 60,
            exact_duration = 65,
            error_minutes = 5,
            workday_excluded = false,
          },
          {
            text = "break",
            tag = "ooo",
            duration = 30,
            exact_duration = 25,
            error_minutes = -5,
            workday_excluded = true,
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 60,
            exact_duration = 65,
            error_minutes = 5,
          },
          {
            tag = "ooo",
            duration = 30,
            exact_duration = 25,
            error_minutes = -5,
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 90,
            exact_duration = 90,
            error_minutes = 0,
          },
        },
        activity_total = 90,
        workday_total = 60,
        activity_error_minutes = 0,
        workday_error_minutes = 5,
      }, "quantized"),
      {
        "",
        "--- summary quantized ---",
        "1.00h (+5m) client",
        "0.50h (-5m) break",
        "",
        "--- tags quantized ---",
        "1.00h (+5m) #ClientA",
        "0.50h (-5m) #ooo",
        "",
        "--- locations quantized ---",
        "1.50h (+0m) @office",
        "",
        "--- totals quantized ---",
        "1.50h (+0m) activity",
        "1.00h (+5m) workday",
      }
    )
  end)

  t.test("render supports hhmm exact durations", function()
    t.eq(
      render.summary_lines({
        summary_items = {
          {
            text = "planning",
            tag = "ClientA",
            duration = 90,
            exact_duration = 90,
            workday_excluded = false,
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 90,
            exact_duration = 90,
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 90,
            exact_duration = 90,
          },
        },
        activity_total = 90,
        workday_total = 90,
      }, "exact", "hhmm"),
      {
        "",
        "--- summary exact ---",
        "1:30 planning",
        "",
        "--- tags exact ---",
        "1:30 #ClientA",
        "",
        "--- locations exact ---",
        "1:30 @office",
        "",
        "--- totals exact ---",
        "1:30 workday",
      }
    )
  end)

  t.test("render supports hhmm quantized durations", function()
    t.eq(
      render.summary_lines({
        summary_items = {
          {
            text = "plan",
            tag = nil,
            duration = 90,
            exact_duration = 95,
            error_minutes = 5,
            workday_excluded = false,
          },
        },
        tag_totals = {
          {
            tag = nil,
            duration = 90,
            exact_duration = 95,
            error_minutes = 5,
          },
        },
        location_totals = {
          {
            location = nil,
            duration = 90,
            exact_duration = 95,
            error_minutes = 5,
          },
        },
        activity_total = 90,
        workday_total = 90,
        activity_error_minutes = 5,
        workday_error_minutes = 5,
      }, "quantized", "hhmm"),
      {
        "",
        "--- summary quantized ---",
        "1:30 (+5m) plan",
        "",
        "--- totals quantized ---",
        "1:30 (+5m) workday",
      }
    )
  end)

  t.test("render exact summaries append !L on main rows and show a logged section", function()
    t.eq(
      render.summary_lines({
        summary_items = {
          {
            text = "implementation",
            tag = "ClientA",
            duration = 60,
            exact_duration = 60,
            workday_excluded = false,
            logged = true,
          },
          {
            text = "implementation",
            tag = "ClientA",
            duration = 60,
            exact_duration = 60,
            workday_excluded = false,
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 120,
            exact_duration = 120,
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 120,
            exact_duration = 120,
          },
        },
        logged_totals = {
          {
            logged = true,
            duration = 60,
            exact_duration = 60,
          },
          {
            logged = false,
            duration = 60,
            exact_duration = 60,
          },
        },
        activity_total = 120,
        workday_total = 120,
      }, "exact"),
      {
        "",
        "--- summary exact ---",
        "1.00h implementation !L",
        "1.00h implementation",
        "",
        "--- tags exact ---",
        "2.00h #ClientA",
        "",
        "--- locations exact ---",
        "2.00h @office",
        "",
        "--- logged exact ---",
        "1.00h logged",
        "1.00h unlogged",
        "",
        "--- totals exact ---",
        "2.00h workday",
      }
    )
  end)

  t.test("render quantized summaries append !L on main rows and show logged deltas", function()
    t.eq(
      render.summary_lines({
        summary_items = {
          {
            text = "implementation",
            tag = "ClientA",
            duration = 30,
            exact_duration = 20,
            error_minutes = -10,
            workday_excluded = false,
            logged = true,
          },
          {
            text = "implementation",
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
            duration = 60,
            exact_duration = 40,
            error_minutes = -20,
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 60,
            exact_duration = 40,
            error_minutes = -20,
          },
        },
        logged_totals = {
          {
            logged = true,
            duration = 30,
            exact_duration = 20,
            error_minutes = -10,
          },
          {
            logged = false,
            duration = 30,
            exact_duration = 20,
            error_minutes = -10,
          },
        },
        activity_total = 60,
        workday_total = 60,
        activity_error_minutes = -20,
        workday_error_minutes = -20,
      }, "quantized"),
      {
        "",
        "--- summary quantized ---",
        "0.50h (-10m) implementation !L",
        "0.50h (-10m) implementation",
        "",
        "--- tags quantized ---",
        "1.00h (-20m) #ClientA",
        "",
        "--- locations quantized ---",
        "1.00h (-20m) @office",
        "",
        "--- logged quantized ---",
        "0.50h (-10m) logged",
        "0.50h (-10m) unlogged",
        "",
        "--- totals quantized ---",
        "1.00h (-20m) workday",
      }
    )
  end)

  t.test("render builds a weekly report with daily sections before the weekly total", function()
    t.eq(
      render.week_report_lines({
        period_label = "2026-W21",
        days = {
          {
            date_label = "2026-05-18",
            summary = {
              summary_items = {
                {
                  text = "plan",
                  tag = nil,
                  duration = 60,
                  exact_duration = 68,
                  error_minutes = 8,
                  workday_excluded = false,
                },
              },
              tag_totals = {
                {
                  tag = nil,
                  duration = 60,
                  exact_duration = 68,
                  error_minutes = 8,
                },
              },
              location_totals = {
                {
                  location = nil,
                  duration = 60,
                  exact_duration = 68,
                  error_minutes = 8,
                },
              },
              activity_total = 60,
              workday_total = 60,
              activity_error_minutes = 8,
              workday_error_minutes = 8,
            },
          },
        },
        summary = {
          summary_items = {
            {
              text = "plan",
              tag = nil,
              duration = 60,
              exact_duration = 68,
              error_minutes = 8,
              workday_excluded = false,
            },
          },
          tag_totals = {
            {
              tag = nil,
              duration = 60,
              exact_duration = 68,
              error_minutes = 8,
            },
          },
          location_totals = {
            {
              location = nil,
              duration = 60,
              exact_duration = 68,
              error_minutes = 8,
            },
          },
          activity_total = 60,
          workday_total = 60,
          activity_error_minutes = 8,
          workday_error_minutes = 8,
        },
      }, "hhmm"),
      {
        "--- day summary quantized 2026-05-18 ---",
        "1:00 (+8m) plan",
        "",
        "--- day totals quantized 2026-05-18 ---",
        "1:00 (+8m) workday",
        "",
        "--- week summary quantized 2026-W21 ---",
        "1:00 (+8m) plan",
        "",
        "--- week totals quantized 2026-W21 ---",
        "1:00 (+8m) workday",
      }
    )
  end)

  t.test("render can omit day sections for a weekly aggregate-only report", function()
    t.eq(
      render.week_report_lines(
        {
          period_label = "2026-W21",
          days = {
            {
              date_label = "2026-05-18",
              summary = {
                summary_items = {
                  {
                    text = "stale day",
                    tag = nil,
                    duration = 15,
                    exact_duration = 20,
                    error_minutes = 5,
                    workday_excluded = false,
                  },
                },
                tag_totals = {},
                location_totals = {},
                activity_total = 15,
                workday_total = 15,
                activity_error_minutes = 5,
                workday_error_minutes = 5,
              },
            },
          },
          summary = {
            summary_items = {
              {
                text = "plan",
                tag = "ClientA",
                duration = 60,
                exact_duration = 68,
                error_minutes = 8,
                workday_excluded = false,
              },
            },
            tag_totals = {
              {
                tag = "ClientA",
                duration = 60,
                exact_duration = 68,
                error_minutes = 8,
              },
            },
            location_totals = {
              {
                location = "office",
                duration = 60,
                exact_duration = 68,
                error_minutes = 8,
              },
            },
            activity_total = 60,
            workday_total = 60,
            activity_error_minutes = 8,
            workday_error_minutes = 8,
          },
        },
        "hhmm",
        {
          aggregate_only = true,
        }
      ),
      {
        "--- week summary quantized 2026-W21 ---",
        "1:00 (+8m) plan",
        "",
        "--- week tags quantized 2026-W21 ---",
        "1:00 (+8m) #ClientA",
        "",
        "--- week locations quantized 2026-W21 ---",
        "1:00 (+8m) @office",
        "",
        "--- week totals quantized 2026-W21 ---",
        "1:00 (+8m) workday",
      }
    )
  end)

  t.test("render weekly reports use logged headers when logged totals are present", function()
    t.eq(
      render.week_report_lines({
        period_label = "2026-W21",
        days = {
          {
            date_label = "2026-05-18",
            summary = {
              summary_items = {
                {
                  text = "plan",
                  tag = nil,
                  duration = 60,
                  exact_duration = 60,
                  error_minutes = 0,
                  workday_excluded = false,
                  logged = true,
                },
              },
              tag_totals = {},
              location_totals = {},
              logged_totals = {
                {
                  logged = true,
                  duration = 60,
                  exact_duration = 60,
                  error_minutes = 0,
                },
              },
              activity_total = 60,
              workday_total = 60,
              activity_error_minutes = 0,
              workday_error_minutes = 0,
            },
          },
        },
        summary = {
          summary_items = {
            {
              text = "plan",
              tag = nil,
              duration = 60,
              exact_duration = 60,
              error_minutes = 0,
              workday_excluded = false,
              logged = true,
            },
          },
          tag_totals = {},
          location_totals = {},
          logged_totals = {
            {
              logged = true,
              duration = 60,
              exact_duration = 60,
              error_minutes = 0,
            },
          },
          activity_total = 60,
          workday_total = 60,
          activity_error_minutes = 0,
          workday_error_minutes = 0,
        },
      }, "hhmm"),
      {
        "--- day summary quantized 2026-05-18 ---",
        "1:00 (+0m) plan !L",
        "",
        "--- day logged quantized 2026-05-18 ---",
        "1:00 (+0m) logged",
        "",
        "--- day totals quantized 2026-05-18 ---",
        "1:00 (+0m) workday",
        "",
        "--- week summary quantized 2026-W21 ---",
        "1:00 (+0m) plan !L",
        "",
        "--- week logged quantized 2026-W21 ---",
        "1:00 (+0m) logged",
        "",
        "--- week totals quantized 2026-W21 ---",
        "1:00 (+0m) workday",
      }
    )
  end)

  t.test("render builds a days report with range headers", function()
    t.eq(
      render.days_report_lines({
        period_label = "2026-05-20..2026-05-22",
        days = {
          {
            date_label = "2026-05-22",
            summary = {
              summary_items = {
                {
                  text = "plan",
                  tag = nil,
                  duration = 60,
                  exact_duration = 68,
                  error_minutes = 8,
                  workday_excluded = false,
                },
              },
              tag_totals = {
                {
                  tag = nil,
                  duration = 60,
                  exact_duration = 68,
                  error_minutes = 8,
                },
              },
              location_totals = {
                {
                  location = nil,
                  duration = 60,
                  exact_duration = 68,
                  error_minutes = 8,
                },
              },
              activity_total = 60,
              workday_total = 60,
              activity_error_minutes = 8,
              workday_error_minutes = 8,
            },
          },
        },
        summary = {
          summary_items = {
            {
              text = "plan",
              tag = nil,
              duration = 60,
              exact_duration = 68,
              error_minutes = 8,
              workday_excluded = false,
            },
          },
          tag_totals = {
            {
              tag = nil,
              duration = 60,
              exact_duration = 68,
              error_minutes = 8,
            },
          },
          location_totals = {
            {
              location = nil,
              duration = 60,
              exact_duration = 68,
              error_minutes = 8,
            },
          },
          activity_total = 60,
          workday_total = 60,
          activity_error_minutes = 8,
          workday_error_minutes = 8,
        },
      }, "hhmm"),
      {
        "--- day summary quantized 2026-05-22 ---",
        "1:00 (+8m) plan",
        "",
        "--- day totals quantized 2026-05-22 ---",
        "1:00 (+8m) workday",
        "",
        "--- range summary quantized 2026-05-20..2026-05-22 ---",
        "1:00 (+8m) plan",
        "",
        "--- range totals quantized 2026-05-20..2026-05-22 ---",
        "1:00 (+8m) workday",
      }
    )
  end)

  t.test("render can omit day sections for an aggregate-only days report", function()
    t.eq(
      render.days_report_lines(
        {
          period_label = "2026-05-20..2026-05-22",
          days = {
            {
              date_label = "2026-05-22",
              summary = {
                summary_items = {
                  {
                    text = "stale day",
                    tag = nil,
                    duration = 15,
                    exact_duration = 20,
                    error_minutes = 5,
                    workday_excluded = false,
                  },
                },
                tag_totals = {},
                location_totals = {},
                activity_total = 15,
                workday_total = 15,
                activity_error_minutes = 5,
                workday_error_minutes = 5,
              },
            },
          },
          summary = {
            summary_items = {
              {
                text = "retro",
                tag = "internal",
                duration = 60,
                exact_duration = 68,
                error_minutes = 8,
                workday_excluded = false,
              },
            },
            tag_totals = {
              {
                tag = "internal",
                duration = 60,
                exact_duration = 68,
                error_minutes = 8,
              },
            },
            location_totals = {
              {
                location = "home",
                duration = 60,
                exact_duration = 68,
                error_minutes = 8,
              },
            },
            activity_total = 60,
            workday_total = 60,
            activity_error_minutes = 8,
            workday_error_minutes = 8,
          },
        },
        "hhmm",
        {
          aggregate_only = true,
        }
      ),
      {
        "--- range summary quantized 2026-05-20..2026-05-22 ---",
        "1:00 (+8m) retro",
        "",
        "--- range tags quantized 2026-05-20..2026-05-22 ---",
        "1:00 (+8m) #internal",
        "",
        "--- range locations quantized 2026-05-20..2026-05-22 ---",
        "1:00 (+8m) @home",
        "",
        "--- range totals quantized 2026-05-20..2026-05-22 ---",
        "1:00 (+8m) workday",
      }
    )
  end)
end
