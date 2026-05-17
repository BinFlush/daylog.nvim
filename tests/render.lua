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
end
