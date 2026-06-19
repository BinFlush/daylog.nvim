return function(t)
  local journal = require("blotter.journal")

  t.test("journal builds a dated path from root and directory template", function()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    t.eq(
      journal.path_for_date({
        root = "/tmp/timereg",
        directory = "%Y/%V",
      }, now),
      "/tmp/timereg/2026/21/2026-05-18.blot"
    )
  end)

  t.test("journal allows an empty directory template", function()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    t.eq(
      journal.path_for_date({
        root = "/tmp/worklog",
        directory = "",
      }, now),
      "/tmp/worklog/2026-05-18.blot"
    )
  end)

  t.test("journal trims extra path separators around root and directory", function()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    t.eq(
      journal.path_for_date({
        root = "/tmp/worklog/",
        directory = "/%Y/%V/",
      }, now),
      "/tmp/worklog/2026/21/2026-05-18.blot"
    )
  end)

  t.test("journal keeps home-relative roots literal", function()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    t.eq(
      journal.path_for_date({
        root = "~/timereg",
        directory = "%Y/%V",
      }, now),
      "~/timereg/2026/21/2026-05-18.blot"
    )
  end)

  t.test("journal offsets dates relative to a midday anchor", function()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    t.eq(journal.date_label(journal.offset_date(now, -1)), "2026-05-17")
    t.eq(journal.date_label(journal.offset_date(now, 0)), "2026-05-18")
    t.eq(journal.date_label(journal.offset_date(now, 1)), "2026-05-19")
  end)

  t.test("journal derives monday to sunday for the current iso week", function()
    local dates = journal.iso_week_dates(os.time({
      year = 2026,
      month = 5,
      day = 22,
      hour = 9,
      min = 0,
      sec = 0,
    }))

    t.eq(#dates, 7)
    t.eq(journal.date_label(dates[1]), "2026-05-18")
    t.eq(journal.date_label(dates[7]), "2026-05-24")
  end)

  t.test("journal week label uses iso week year", function()
    t.eq(
      journal.week_label(os.time({
        year = 2021,
        month = 1,
        day = 1,
        hour = 12,
        min = 0,
        sec = 0,
      })),
      "2020-W53"
    )
  end)

  t.test("journal derives trailing dates oldest to newest including today", function()
    local dates = journal.trailing_dates(
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
    t.eq(journal.date_label(dates[1]), "2026-05-20")
    t.eq(journal.date_label(dates[2]), "2026-05-21")
    t.eq(journal.date_label(dates[3]), "2026-05-22")
  end)

  t.test("journal parses a dated journal filename into its date", function()
    t.eq(journal.date_label(journal.parse_date_label("2026-05-18.blot")), "2026-05-18")
  end)

  t.test("journal rejects filenames that are not valid journal dates", function()
    t.eq(journal.parse_date_label("notes.blot"), nil)
    t.eq(journal.parse_date_label("2026-05-18.txt"), nil)
    t.eq(journal.parse_date_label("2026-13-01.blot"), nil)
    t.eq(journal.parse_date_label("2026-02-30.blot"), nil)
  end)

  t.test("journal resolves a canonical journal path back to its date", function()
    local settings = { root = "/tmp/timereg", directory = "%Y/%V" }

    t.eq(
      journal.date_label(journal.date_from_path(settings, "/tmp/timereg/2026/21/2026-05-18.blot")),
      "2026-05-18"
    )
  end)

  t.test("journal ignores dated files outside the canonical location", function()
    local settings = { root = "/tmp/timereg", directory = "%Y/%V" }

    -- Right name, wrong directory (template would place it under 2026/21).
    t.eq(journal.date_from_path(settings, "/tmp/timereg/2026-05-18.blot"), nil)
    t.eq(journal.date_from_path(settings, "/somewhere/else/2026-05-18.blot"), nil)
    -- Not a dated journal filename at all.
    t.eq(journal.date_from_path(settings, "/tmp/timereg/2026/21/notes.blot"), nil)
  end)

  t.test("journal resolves canonical paths with an empty directory template", function()
    local settings = { root = "/tmp/worklog", directory = "" }

    t.eq(
      journal.date_label(journal.date_from_path(settings, "/tmp/worklog/2026-05-18.blot")),
      "2026-05-18"
    )
  end)

  t.test("journal resolves canonical Windows-style paths", function()
    local settings = { root = "C:\\Users\\me\\timereg", directory = "%Y" }

    t.eq(
      journal.date_label(
        journal.date_from_path(settings, "C:\\Users\\me\\timereg\\2026\\2026-05-18.blot")
      ),
      "2026-05-18"
    )
  end)

  t.test("journal ignores Windows-style dated files outside the canonical location", function()
    local settings = { root = "C:\\Users\\me\\timereg", directory = "%Y" }

    -- Right name, wrong directory (template would place it under 2026\).
    t.eq(journal.date_from_path(settings, "C:\\Users\\me\\timereg\\2026-05-18.blot"), nil)
    t.eq(journal.date_from_path(settings, "D:\\elsewhere\\2026-05-18.blot"), nil)
  end)

  local function day(year, month, d)
    return os.time({ year = year, month = month, day = d, hour = 12, min = 0, sec = 0 })
  end

  t.test("journal nearest_date returns nil for an empty set", function()
    t.eq(journal.nearest_date({}, day(2026, 5, 18), 1, 1), nil)
    t.eq(journal.nearest_date({}, day(2026, 5, 18), -1, 1), nil)
  end)

  t.test("journal nearest_date skips gaps to the next existing day in each direction", function()
    -- Sparse set with the anchor day itself missing in between.
    local dates = { day(2026, 5, 15), day(2026, 5, 18), day(2026, 5, 22) }
    local anchor = day(2026, 5, 18)

    t.eq(journal.date_label(journal.nearest_date(dates, anchor, 1, 1)), "2026-05-22")
    t.eq(journal.date_label(journal.nearest_date(dates, anchor, -1, 1)), "2026-05-15")
  end)

  t.test("journal nearest_date excludes the anchor day itself", function()
    local dates = { day(2026, 5, 17), day(2026, 5, 18), day(2026, 5, 19) }
    local anchor = day(2026, 5, 18)

    t.eq(journal.date_label(journal.nearest_date(dates, anchor, 1, 1)), "2026-05-19")
    t.eq(journal.date_label(journal.nearest_date(dates, anchor, -1, 1)), "2026-05-17")
  end)

  t.test("journal nearest_date honors a count and an anchor outside the set", function()
    local dates = { day(2026, 5, 10), day(2026, 5, 12), day(2026, 5, 14) }

    -- Anchor before everything: count walks forward through the set.
    local anchor = day(2026, 5, 1)
    t.eq(journal.date_label(journal.nearest_date(dates, anchor, 1, 1)), "2026-05-10")
    t.eq(journal.date_label(journal.nearest_date(dates, anchor, 1, 3)), "2026-05-14")
    -- Nothing earlier than the start of the set.
    t.eq(journal.nearest_date(dates, anchor, -1, 1), nil)
    -- count beyond the available days yields nil.
    t.eq(journal.nearest_date(dates, anchor, 1, 4), nil)
  end)

  t.test("journal nearest_date de-duplicates days that appear twice", function()
    -- The same day from two sources (buffer + disk) must count once.
    local dates = { day(2026, 5, 12), day(2026, 5, 12), day(2026, 5, 14) }
    local anchor = day(2026, 5, 10)

    t.eq(journal.date_label(journal.nearest_date(dates, anchor, 1, 2)), "2026-05-14")
  end)
end
