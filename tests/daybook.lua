return function(t)
  local daybook = require("daylog.daybook")

  t.test("daybook builds a dated path from root and directory template", function()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    t.eq(
      daybook.path_for_date({
        root = "/tmp/timereg",
        directory = "%Y/%V",
      }, now),
      "/tmp/timereg/2026/21/2026-05-18.day"
    )
  end)

  t.test("daybook allows an empty directory template", function()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    t.eq(
      daybook.path_for_date({
        root = "/tmp/daylog",
        directory = "",
      }, now),
      "/tmp/daylog/2026-05-18.day"
    )
  end)

  t.test("daybook trims extra path separators around root and directory", function()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    t.eq(
      daybook.path_for_date({
        root = "/tmp/daylog/",
        directory = "/%Y/%V/",
      }, now),
      "/tmp/daylog/2026/21/2026-05-18.day"
    )
  end)

  t.test("daybook keeps home-relative roots literal", function()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    t.eq(
      daybook.path_for_date({
        root = "~/timereg",
        directory = "%Y/%V",
      }, now),
      "~/timereg/2026/21/2026-05-18.day"
    )
  end)

  t.test("daybook offsets dates relative to a midday anchor", function()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    t.eq(daybook.date_label(daybook.offset_date(now, -1)), "2026-05-17")
    t.eq(daybook.date_label(daybook.offset_date(now, 0)), "2026-05-18")
    t.eq(daybook.date_label(daybook.offset_date(now, 1)), "2026-05-19")
  end)

  t.test("daybook resolves named date tokens against a reference day", function()
    -- 2026-05-22 is a Friday.
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 9, min = 0, sec = 0 })
    local function label(token)
      local ts = daybook.resolve_date(token, now)
      return ts and daybook.date_label(ts) or nil
    end

    t.eq(label("today"), "2026-05-22")
    t.eq(label("yesterday"), "2026-05-21")
    -- A weekday is the most recent occurrence on or before today.
    t.eq(label("friday"), "2026-05-22") -- today is Friday
    t.eq(label("fri"), "2026-05-22") -- abbreviation
    t.eq(label("monday"), "2026-05-18") -- this week's Monday
    t.eq(label("sunday"), "2026-05-17") -- last Sunday (not the coming one)
    t.eq(label("Wed"), "2026-05-20") -- case-insensitive
    t.eq(label("tomorrow"), "2026-05-23")
    -- Signed relative day offsets; a bare (unsigned) number is NOT an offset (it is a report
    -- count in the shared grammar).
    t.eq(label("+1"), "2026-05-23")
    t.eq(label("-3"), "2026-05-19")
    t.eq(label("+0"), "2026-05-22")
    t.eq(label("3"), nil)
    -- A literal date passes through; anything else is nil.
    t.eq(label("2026-01-09"), "2026-01-09")
    t.eq(label("someday"), nil)
    t.eq(label("2026-13-01"), nil)
  end)

  t.test("daybook derives trailing dates oldest to newest including today", function()
    local dates = daybook.trailing_dates(
      os.time({
        year = 2026,
        month = 5,
        day = 22,
        hour = 12,
        min = 0,
        sec = 0,
      }),
      3
    )

    t.eq(#dates, 3)
    t.eq(daybook.date_label(dates[1]), "2026-05-20")
    t.eq(daybook.date_label(dates[2]), "2026-05-21")
    t.eq(daybook.date_label(dates[3]), "2026-05-22")
  end)

  t.test("daybook builds an inclusive date range, oldest to newest", function()
    local from = os.time({ year = 2026, month = 5, day = 30, hour = 12, min = 0, sec = 0 })
    local to = os.time({ year = 2026, month = 6, day = 2, hour = 12, min = 0, sec = 0 })
    local dates = daybook.range_dates(from, to)

    -- Spans the month boundary.
    t.eq(#dates, 4)
    t.eq(daybook.date_label(dates[1]), "2026-05-30")
    t.eq(daybook.date_label(dates[4]), "2026-06-02")
  end)

  t.test("daybook range of a single day has one date; a reversed range is empty", function()
    local day = os.time({ year = 2026, month = 5, day = 18, hour = 12, min = 0, sec = 0 })
    local later = os.time({ year = 2026, month = 5, day = 20, hour = 12, min = 0, sec = 0 })

    local single = daybook.range_dates(day, day)
    t.eq(#single, 1)
    t.eq(daybook.date_label(single[1]), "2026-05-18")

    t.eq(daybook.range_dates(later, day), {})
  end)

  t.test("daybook parse_report_range tolerates surrounding whitespace", function()
    t.eq(daybook.parse_report_range("7"), { count = 7 })
    t.eq(daybook.parse_report_range("7 "), { count = 7 }) -- a stray trailing space still parses
    t.eq(daybook.parse_report_range("  monday..today  "), { from = "monday", to = "today" })
    t.eq(daybook.parse_report_range("bogus"), nil)
  end)

  t.test("daybook parses a YYYY-MM-DD date, rejecting invalid ones", function()
    t.eq(daybook.date_label(daybook.parse_date("2026-05-18")), "2026-05-18")
    t.eq(daybook.parse_date("2026-13-01"), nil)
    t.eq(daybook.parse_date("2026-02-30"), nil)
    t.eq(daybook.parse_date("2026-05-18.day"), nil)
    t.eq(daybook.parse_date("nope"), nil)
  end)

  t.test("daybook parses a dated daybook filename into its date", function()
    t.eq(daybook.date_label(daybook.parse_date_label("2026-05-18.day")), "2026-05-18")
  end)

  t.test("daybook rejects filenames that are not valid daybook dates", function()
    t.eq(daybook.parse_date_label("notes.day"), nil)
    t.eq(daybook.parse_date_label("2026-05-18.txt"), nil)
    t.eq(daybook.parse_date_label("2026-13-01.day"), nil)
    t.eq(daybook.parse_date_label("2026-02-30.day"), nil)
  end)

  t.test("daybook resolves a canonical daybook path back to its date", function()
    local settings = { root = "/tmp/timereg", directory = "%Y/%V" }

    t.eq(
      daybook.date_label(daybook.date_from_path(settings, "/tmp/timereg/2026/21/2026-05-18.day")),
      "2026-05-18"
    )
  end)

  t.test("daybook ignores dated files outside the canonical location", function()
    local settings = { root = "/tmp/timereg", directory = "%Y/%V" }

    -- Right name, wrong directory (template would place it under 2026/21).
    t.eq(daybook.date_from_path(settings, "/tmp/timereg/2026-05-18.day"), nil)
    t.eq(daybook.date_from_path(settings, "/somewhere/else/2026-05-18.day"), nil)
    -- Not a dated daybook filename at all.
    t.eq(daybook.date_from_path(settings, "/tmp/timereg/2026/21/notes.day"), nil)
  end)

  t.test("daybook resolves canonical paths with an empty directory template", function()
    local settings = { root = "/tmp/daylog", directory = "" }

    t.eq(
      daybook.date_label(daybook.date_from_path(settings, "/tmp/daylog/2026-05-18.day")),
      "2026-05-18"
    )
  end)

  t.test("daybook resolves canonical Windows-style paths", function()
    local settings = { root = "C:\\Users\\me\\timereg", directory = "%Y" }

    t.eq(
      daybook.date_label(
        daybook.date_from_path(settings, "C:\\Users\\me\\timereg\\2026\\2026-05-18.day")
      ),
      "2026-05-18"
    )
  end)

  t.test("daybook ignores Windows-style dated files outside the canonical location", function()
    local settings = { root = "C:\\Users\\me\\timereg", directory = "%Y" }

    -- Right name, wrong directory (template would place it under 2026\).
    t.eq(daybook.date_from_path(settings, "C:\\Users\\me\\timereg\\2026-05-18.day"), nil)
    t.eq(daybook.date_from_path(settings, "D:\\elsewhere\\2026-05-18.day"), nil)
  end)

  local function day(year, month, d)
    return os.time({ year = year, month = month, day = d, hour = 12, min = 0, sec = 0 })
  end

  t.test("daybook nearest_date returns nil for an empty set", function()
    t.eq(daybook.nearest_date({}, day(2026, 5, 18), 1, 1), nil)
    t.eq(daybook.nearest_date({}, day(2026, 5, 18), -1, 1), nil)
  end)

  t.test("daybook nearest_date skips gaps to the next existing day in each direction", function()
    -- Sparse set with the anchor day itself missing in between.
    local dates = { day(2026, 5, 15), day(2026, 5, 18), day(2026, 5, 22) }
    local anchor = day(2026, 5, 18)

    t.eq(daybook.date_label(daybook.nearest_date(dates, anchor, 1, 1)), "2026-05-22")
    t.eq(daybook.date_label(daybook.nearest_date(dates, anchor, -1, 1)), "2026-05-15")
  end)

  t.test("daybook nearest_date excludes the anchor day itself", function()
    local dates = { day(2026, 5, 17), day(2026, 5, 18), day(2026, 5, 19) }
    local anchor = day(2026, 5, 18)

    t.eq(daybook.date_label(daybook.nearest_date(dates, anchor, 1, 1)), "2026-05-19")
    t.eq(daybook.date_label(daybook.nearest_date(dates, anchor, -1, 1)), "2026-05-17")
  end)

  t.test("daybook nearest_date honors a count and an anchor outside the set", function()
    local dates = { day(2026, 5, 10), day(2026, 5, 12), day(2026, 5, 14) }

    -- Anchor before everything: count walks forward through the set.
    local anchor = day(2026, 5, 1)
    t.eq(daybook.date_label(daybook.nearest_date(dates, anchor, 1, 1)), "2026-05-10")
    t.eq(daybook.date_label(daybook.nearest_date(dates, anchor, 1, 3)), "2026-05-14")
    -- Nothing earlier than the start of the set.
    t.eq(daybook.nearest_date(dates, anchor, -1, 1), nil)
    -- count beyond the available days yields nil.
    t.eq(daybook.nearest_date(dates, anchor, 1, 4), nil)
  end)

  t.test("daybook nearest_date de-duplicates days that appear twice", function()
    -- The same day from two sources (buffer + disk) must count once.
    local dates = { day(2026, 5, 12), day(2026, 5, 12), day(2026, 5, 14) }
    local anchor = day(2026, 5, 10)

    t.eq(daybook.date_label(daybook.nearest_date(dates, anchor, 1, 2)), "2026-05-14")
  end)
end
