return function(t)
  local render = require("daylog.render")

  local function find_layout_row(layout, predicate)
    for _, row in ipairs(layout) do
      if predicate(row) then
        return row
      end
    end

    return nil
  end

  local function collect_layout_rows(layout, predicate)
    local matches = {}

    for _, row in ipairs(layout) do
      if predicate(row) then
        table.insert(matches, row)
      end
    end

    return matches
  end

  t.test("render omits location on main summary rows and shows tags only for conflicts", function()
    t.eq(
      render.summary_lines({
        summary_items = {
          {
            text = "planning",
            tag = "ClientA",
            duration = 60,
            unrounded_duration = 60,
          },
          {
            text = "planning",
            tag = "internal",
            duration = 30,
            unrounded_duration = 30,
          },
          {
            text = "implementation",
            tag = "ClientA",
            duration = 90,
            unrounded_duration = 90,
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 150,
            unrounded_duration = 150,
          },
          {
            tag = "internal",
            duration = 30,
            unrounded_duration = 30,
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 120,
            unrounded_duration = 120,
          },
          {
            location = "home",
            duration = 60,
            unrounded_duration = 60,
          },
        },
        total_rows = {
          {
            duration = 180,
            unrounded_duration = 180,
            error_minutes = 0,
          },
        },
        activity_total = 180,
      }),
      {
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) planning #ClientA",
        "0.50h (+0m) planning #internal",
        "1.50h (+0m) implementation",
        "",
        "--- tags ---",
        "2.50h (+0m) #ClientA",
        "0.50h (+0m) #internal",
        "",
        "--- locations ---",
        "2.00h (+0m) @office",
        "1.00h (+0m) @home",
        "",
        "--- totals ---",
        "3.00h (+0m) workday",
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
            unrounded_duration = 30,
            error_minutes = 0,
          },
        },
        tag_totals = {
          {
            tag = nil,
            duration = 30,
            unrounded_duration = 30,
            error_minutes = 0,
          },
        },
        location_totals = {
          {
            location = nil,
            duration = 30,
            unrounded_duration = 30,
            error_minutes = 0,
          },
        },
        total_rows = {
          {
            duration = 30,
            unrounded_duration = 30,
            error_minutes = 0,
          },
        },
        activity_total = 30,
        activity_error_minutes = 0,
      }),
      {
        "",
        "--- summary q=15 d=dec ---",
        "0.50h (+0m) plan",
        "",
        "--- totals ---",
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
            unrounded_duration = 65,
            error_minutes = 5,
          },
          {
            text = "break",
            tag = "ooo",
            duration = 30,
            unrounded_duration = 25,
            error_minutes = -5,
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 60,
            unrounded_duration = 65,
            error_minutes = 5,
          },
          {
            tag = "ooo",
            duration = 30,
            unrounded_duration = 25,
            error_minutes = -5,
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 90,
            unrounded_duration = 90,
            error_minutes = 0,
          },
        },
        total_rows = {
          {
            duration = 90,
            unrounded_duration = 90,
            error_minutes = 0,
          },
        },
        activity_total = 90,
        activity_error_minutes = 0,
      }),
      {
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+5m) client",
        "0.50h (-5m) break",
        "",
        "--- tags ---",
        "1.00h (+5m) #ClientA",
        "0.50h (-5m) #ooo",
        "",
        "--- locations ---",
        "1.50h (+0m) @office",
        "",
        "--- totals ---",
        "1.50h (+0m) workday",
      }
    )
  end)

  t.test("render supports hhmm unrounded durations", function()
    t.eq(
      render.summary_lines({
        summary_items = {
          {
            text = "planning",
            tag = "ClientA",
            duration = 90,
            unrounded_duration = 90,
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 90,
            unrounded_duration = 90,
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 90,
            unrounded_duration = 90,
          },
        },
        total_rows = {
          {
            duration = 90,
            unrounded_duration = 90,
            error_minutes = 0,
          },
        },
        activity_total = 90,
      }, "hm"),
      {
        "",
        "--- summary q=15 d=hm ---",
        "1:30 (+0m) planning",
        "",
        "--- tags ---",
        "1:30 (+0m) #ClientA",
        "",
        "--- locations ---",
        "1:30 (+0m) @office",
        "",
        "--- totals ---",
        "1:30 (+0m) workday",
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
            unrounded_duration = 95,
            error_minutes = 5,
          },
        },
        tag_totals = {
          {
            tag = nil,
            duration = 90,
            unrounded_duration = 95,
            error_minutes = 5,
          },
        },
        location_totals = {
          {
            location = nil,
            duration = 90,
            unrounded_duration = 95,
            error_minutes = 5,
          },
        },
        total_rows = {
          {
            duration = 90,
            unrounded_duration = 95,
            error_minutes = 5,
          },
        },
        activity_total = 90,
        activity_error_minutes = 5,
      }, "hm"),
      {
        "",
        "--- summary q=15 d=hm ---",
        "1:30 (+5m) plan",
        "",
        "--- totals ---",
        "1:30 (+5m) workday",
      }
    )
  end)

  t.test("render unrounded summaries append !S on main rows", function()
    t.eq(
      render.summary_lines({
        summary_items = {
          {
            text = "implementation",
            tag = "ClientA",
            duration = 60,
            unrounded_duration = 60,
            logged = true,
          },
          {
            text = "implementation",
            tag = "ClientA",
            duration = 60,
            unrounded_duration = 60,
          },
        },
        tag_totals = {
          {
            tag = "ClientA",
            duration = 120,
            unrounded_duration = 120,
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 120,
            unrounded_duration = 120,
          },
        },
        total_rows = {
          {
            duration = 120,
            unrounded_duration = 120,
            error_minutes = 0,
          },
        },
        activity_total = 120,
      }),
      {
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) implementation !S",
        "1.00h (+0m) implementation",
        "",
        "--- tags ---",
        "2.00h (+0m) #ClientA",
        "",
        "--- locations ---",
        "2.00h (+0m) @office",
        "",
        "--- totals ---",
        "2.00h (+0m) workday",
      }
    )
  end)

  t.test("render quantized summaries append !S on main rows", function()
    t.eq(
      render.summary_lines({
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
      }),
      {
        "",
        "--- summary q=15 d=dec ---",
        "0.50h (-10m) implementation !S",
        "0.50h (-10m) implementation",
        "",
        "--- tags ---",
        "1.00h (-20m) #ClientA",
        "",
        "--- locations ---",
        "1.00h (-20m) @office",
        "",
        "--- totals ---",
        "1.00h (-20m) workday",
      }
    )
  end)

  t.test("render shows a name list on a logged row and stays bare when unnamed", function()
    t.eq(
      render.summary_lines({
        summary_items = {
          {
            text = "build",
            tag = "obs",
            duration = 60,
            unrounded_duration = 60,
            logged = true,
            names = { "name1", "name2" },
          },
        },
        tag_totals = {
          {
            tag = "obs",
            duration = 60,
            unrounded_duration = 60,
            logged = true,
            names = { "name1", "name2" },
          },
        },
        location_totals = {
          {
            location = "office",
            duration = 60,
            unrounded_duration = 60,
            logged = true,
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
      }),
      {
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) build !S[name1,name2]",
        "",
        "--- tags ---",
        "1.00h (+0m) #obs !T[name1,name2]",
        "",
        "--- locations ---",
        "1.00h (+0m) @office !L", -- unnamed logged row stays byte-identical to today
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      }
    )
  end)

  t.test("render builds a range report with daily sections before the aggregate total", function()
    t.eq(
      render.days_report_lines({
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
                  unrounded_duration = 68,
                  error_minutes = 8,
                },
              },
              tag_totals = {
                {
                  tag = nil,
                  duration = 60,
                  unrounded_duration = 68,
                  error_minutes = 8,
                },
              },
              location_totals = {
                {
                  location = nil,
                  duration = 60,
                  unrounded_duration = 68,
                  error_minutes = 8,
                },
              },
              total_rows = {
                {
                  duration = 60,
                  unrounded_duration = 68,
                  error_minutes = 8,
                },
              },
              activity_total = 60,
              activity_error_minutes = 8,
            },
          },
        },
        summary = {
          summary_items = {
            {
              text = "plan",
              tag = nil,
              duration = 60,
              unrounded_duration = 68,
              error_minutes = 8,
            },
          },
          tag_totals = {
            {
              tag = nil,
              duration = 60,
              unrounded_duration = 68,
              error_minutes = 8,
            },
          },
          location_totals = {
            {
              location = nil,
              duration = 60,
              unrounded_duration = 68,
              error_minutes = 8,
            },
          },
          total_rows = {
            {
              duration = 60,
              unrounded_duration = 68,
              error_minutes = 8,
            },
          },
          activity_total = 60,
          activity_error_minutes = 8,
        },
      }, "hm"),
      {
        "--- day summary 2026-05-18 ---",
        "1:00 (+8m) plan",
        "",
        "--- day totals 2026-05-18 ---",
        "1:00 (+8m) workday",
        "",
        "--- range summary 2026-W21 ---",
        "1:00 (+8m) plan",
        "",
        "--- range totals 2026-W21 ---",
        "1:00 (+8m) workday",
      }
    )
  end)

  t.test("render labels each day section with its own q= and leaves the aggregate bare", function()
    t.eq(
      render.days_report_lines({
        period_label = "2026-W21",
        days = {
          {
            date_label = "2026-05-18",
            quantize_minutes = 30,
            summary = {
              summary_items = {
                {
                  text = "plan",
                  tag = nil,
                  duration = 60,
                  unrounded_duration = 68,
                  error_minutes = 8,
                },
              },
              tag_totals = {},
              location_totals = {},
              total_rows = {
                {
                  duration = 60,
                  unrounded_duration = 68,
                  error_minutes = 8,
                },
              },
              activity_total = 60,
              activity_error_minutes = 8,
            },
          },
        },
        summary = {
          summary_items = {
            {
              text = "plan",
              tag = nil,
              duration = 60,
              unrounded_duration = 68,
              error_minutes = 8,
            },
          },
          tag_totals = {},
          location_totals = {},
          total_rows = {
            {
              duration = 60,
              unrounded_duration = 68,
              error_minutes = 8,
            },
          },
          activity_total = 60,
          activity_error_minutes = 8,
        },
      }, "hm"),
      {
        -- The day header carries that day's own bucket...
        "--- day summary 2026-05-18 q=30 ---",
        "1:00 (+8m) plan",
        "",
        "--- day totals 2026-05-18 ---",
        "1:00 (+8m) workday",
        "",
        -- ...while the aggregate header stays bare (no q= token).
        "--- range summary 2026-W21 ---",
        "1:00 (+8m) plan",
        "",
        "--- range totals 2026-W21 ---",
        "1:00 (+8m) workday",
      }
    )
  end)

  t.test("render can omit day sections for an aggregate-only report", function()
    t.eq(
      render.days_report_lines(
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
                    unrounded_duration = 20,
                    error_minutes = 5,
                  },
                },
                tag_totals = {},
                location_totals = {},
                total_rows = {
                  {
                    duration = 15,
                    unrounded_duration = 20,
                    error_minutes = 5,
                  },
                },
                activity_total = 15,
                activity_error_minutes = 5,
              },
            },
          },
          summary = {
            summary_items = {
              {
                text = "plan",
                tag = "ClientA",
                duration = 60,
                unrounded_duration = 68,
                error_minutes = 8,
              },
            },
            tag_totals = {
              {
                tag = "ClientA",
                duration = 60,
                unrounded_duration = 68,
                error_minutes = 8,
              },
            },
            location_totals = {
              {
                location = "office",
                duration = 60,
                unrounded_duration = 68,
                error_minutes = 8,
              },
            },
            total_rows = {
              {
                duration = 60,
                unrounded_duration = 68,
                error_minutes = 8,
              },
            },
            activity_total = 60,
            activity_error_minutes = 8,
          },
        },
        "hm",
        {
          aggregate_only = true,
        }
      ),
      {
        "--- range summary 2026-W21 ---",
        "1:00 (+8m) plan",
        "",
        "--- range tags 2026-W21 ---",
        "1:00 (+8m) #ClientA",
        "",
        "--- range locations 2026-W21 ---",
        "1:00 (+8m) @office",
        "",
        "--- range totals 2026-W21 ---",
        "1:00 (+8m) workday",
      }
    )
  end)

  t.test("render reports append !S on main rows (no logged section)", function()
    t.eq(
      render.days_report_lines({
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
                  unrounded_duration = 60,
                  error_minutes = 0,
                  logged = true,
                },
              },
              tag_totals = {},
              location_totals = {},
              total_rows = {
                {
                  duration = 60,
                  unrounded_duration = 60,
                  error_minutes = 0,
                },
              },
              activity_total = 60,
              activity_error_minutes = 0,
            },
          },
        },
        summary = {
          summary_items = {
            {
              text = "plan",
              tag = nil,
              duration = 60,
              unrounded_duration = 60,
              error_minutes = 0,
              logged = true,
            },
          },
          tag_totals = {},
          location_totals = {},
          total_rows = {
            {
              duration = 60,
              unrounded_duration = 60,
              error_minutes = 0,
            },
          },
          activity_total = 60,
          activity_error_minutes = 0,
        },
      }, "hm"),
      {
        "--- day summary 2026-05-18 ---",
        "1:00 (+0m) plan !S",
        "",
        "--- day totals 2026-05-18 ---",
        "1:00 (+0m) workday",
        "",
        "--- range summary 2026-W21 ---",
        "1:00 (+0m) plan !S",
        "",
        "--- range totals 2026-W21 ---",
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
                  unrounded_duration = 68,
                  error_minutes = 8,
                },
              },
              tag_totals = {
                {
                  tag = nil,
                  duration = 60,
                  unrounded_duration = 68,
                  error_minutes = 8,
                },
              },
              location_totals = {
                {
                  location = nil,
                  duration = 60,
                  unrounded_duration = 68,
                  error_minutes = 8,
                },
              },
              total_rows = {
                {
                  duration = 60,
                  unrounded_duration = 68,
                  error_minutes = 8,
                },
              },
              activity_total = 60,
              activity_error_minutes = 8,
            },
          },
        },
        summary = {
          summary_items = {
            {
              text = "plan",
              tag = nil,
              duration = 60,
              unrounded_duration = 68,
              error_minutes = 8,
            },
          },
          tag_totals = {
            {
              tag = nil,
              duration = 60,
              unrounded_duration = 68,
              error_minutes = 8,
            },
          },
          location_totals = {
            {
              location = nil,
              duration = 60,
              unrounded_duration = 68,
              error_minutes = 8,
            },
          },
          total_rows = {
            {
              duration = 60,
              unrounded_duration = 68,
              error_minutes = 8,
            },
          },
          activity_total = 60,
          activity_error_minutes = 8,
        },
      }, "hm"),
      {
        "--- day summary 2026-05-22 ---",
        "1:00 (+8m) plan",
        "",
        "--- day totals 2026-05-22 ---",
        "1:00 (+8m) workday",
        "",
        "--- range summary 2026-05-20..2026-05-22 ---",
        "1:00 (+8m) plan",
        "",
        "--- range totals 2026-05-20..2026-05-22 ---",
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
                    unrounded_duration = 20,
                    error_minutes = 5,
                  },
                },
                tag_totals = {},
                location_totals = {},
                total_rows = {
                  {
                    duration = 15,
                    unrounded_duration = 20,
                    error_minutes = 5,
                  },
                },
                activity_total = 15,
                activity_error_minutes = 5,
              },
            },
          },
          summary = {
            summary_items = {
              {
                text = "retro",
                tag = "internal",
                duration = 60,
                unrounded_duration = 68,
                error_minutes = 8,
              },
            },
            tag_totals = {
              {
                tag = "internal",
                duration = 60,
                unrounded_duration = 68,
                error_minutes = 8,
              },
            },
            location_totals = {
              {
                location = "home",
                duration = 60,
                unrounded_duration = 68,
                error_minutes = 8,
              },
            },
            total_rows = {
              {
                duration = 60,
                unrounded_duration = 68,
                error_minutes = 8,
              },
            },
            activity_total = 60,
            activity_error_minutes = 8,
          },
        },
        "hm",
        {
          aggregate_only = true,
        }
      ),
      {
        "--- range summary 2026-05-20..2026-05-22 ---",
        "1:00 (+8m) retro",
        "",
        "--- range tags 2026-05-20..2026-05-22 ---",
        "1:00 (+8m) #internal",
        "",
        "--- range locations 2026-05-20..2026-05-22 ---",
        "1:00 (+8m) @home",
        "",
        "--- range totals 2026-05-20..2026-05-22 ---",
        "1:00 (+8m) workday",
      }
    )
  end)

  t.test("summary_layout returns structured rows whose lines match summary_lines", function()
    local summary = {
      summary_items = {
        {
          text = "implementation",
          tag = "ClientA",
          duration = 60,
          unrounded_duration = 60,
          logged = true,
          source_entry_rows = { 2 },
        },
        {
          text = "implementation",
          tag = "ClientA",
          duration = 60,
          unrounded_duration = 60,
          source_entry_rows = { 3 },
        },
      },
      tag_totals = {
        {
          tag = "ClientA",
          duration = 120,
          unrounded_duration = 120,
        },
      },
      location_totals = {
        {
          location = "office",
          duration = 120,
          unrounded_duration = 120,
        },
      },
      total_rows = {
        {
          duration = 120,
          unrounded_duration = 120,
          error_minutes = 0,
        },
      },
      activity_total = 120,
    }

    local layout = render.summary_layout(summary)
    local lines_from_layout = {}

    for _, row in ipairs(layout) do
      table.insert(lines_from_layout, row.line)
    end

    t.eq(lines_from_layout, render.summary_lines(summary))
  end)

  t.test("summary_layout marks summary rows with kind summary_item and exposes the item", function()
    local first_item = {
      text = "implementation",
      tag = "ClientA",
      duration = 60,
      unrounded_duration = 60,
      logged = true,
      source_entry_rows = { 2 },
    }
    local second_item = {
      text = "implementation",
      tag = "ClientA",
      duration = 60,
      unrounded_duration = 60,
      source_entry_rows = { 3 },
    }

    local layout = render.summary_layout({
      summary_items = { first_item, second_item },
      tag_totals = {},
      location_totals = {},
      total_rows = {
        {
          duration = 120,
          unrounded_duration = 120,
          error_minutes = 0,
        },
      },
      activity_total = 120,
    })

    local summary_rows = collect_layout_rows(layout, function(row)
      return row.kind == "summary_item"
    end)

    t.eq(#summary_rows, 2)
    t.eq(summary_rows[1].section, "summary")
    t.eq(summary_rows[1].item, first_item)
    t.eq(summary_rows[1].line, "1.00h (+0m) implementation !S")
    t.eq(summary_rows[2].item, second_item)
    t.eq(summary_rows[2].line, "1.00h (+0m) implementation")
  end)

  t.test("summary_layout uses distinct kinds for tag, location, and total rows", function()
    local layout = render.summary_layout({
      summary_items = {
        {
          text = "plan",
          tag = "ClientA",
          duration = 60,
          unrounded_duration = 60,
          logged = true,
          source_entry_rows = { 2 },
        },
      },
      tag_totals = {
        { tag = "ClientA", duration = 60, unrounded_duration = 60 },
      },
      location_totals = {
        { location = "office", duration = 60, unrounded_duration = 60 },
      },
      total_rows = {
        {
          duration = 60,
          unrounded_duration = 60,
          error_minutes = 0,
        },
      },
      activity_total = 60,
    })

    local function find_by_line(line)
      return find_layout_row(layout, function(row)
        return row.line == line
      end)
    end

    t.eq(find_by_line("1.00h (+0m) #ClientA").kind, "tag_total")
    t.eq(find_by_line("1.00h (+0m) @office").kind, "location_total")
    t.eq(find_by_line("1.00h (+0m) workday").kind, "total")

    for _, row in ipairs(layout) do
      if row.kind == "summary_item" then
        t.eq(row.section, "summary")
      else
        t.ok(row.kind ~= "summary_item", "non-summary row leaked summary_item kind")
      end
    end
  end)

  t.test("summary_layout marks quantized summary rows as summary_item", function()
    local item = {
      text = "plan",
      tag = "ClientA",
      duration = 30,
      unrounded_duration = 20,
      error_minutes = -10,
      source_entry_rows = { 2 },
    }

    local layout = render.summary_layout({
      summary_items = { item },
      tag_totals = {},
      location_totals = {},
      total_rows = {
        {
          duration = 30,
          unrounded_duration = 20,
          error_minutes = -10,
        },
      },
      activity_total = 30,
      activity_error_minutes = 10,
    })

    local summary_row = find_layout_row(layout, function(row)
      return row.kind == "summary_item"
    end)

    t.eq(summary_row.item, item)
    t.eq(summary_row.line, "0.50h (-10m) plan")
    t.eq(summary_row.section, "summary")
  end)
end
