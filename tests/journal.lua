return function(t)
  local journal = require("worklog.journal")

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
      journal.today_path({
        root = "/tmp/timereg",
        directory = "%Y/%V",
      }, now),
      "/tmp/timereg/2026/21/2026-05-18.wkl"
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
      journal.today_path({
        root = "/tmp/worklog",
        directory = "",
      }, now),
      "/tmp/worklog/2026-05-18.wkl"
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
      journal.today_path({
        root = "/tmp/worklog/",
        directory = "/%Y/%V/",
      }, now),
      "/tmp/worklog/2026/21/2026-05-18.wkl"
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
      journal.today_path({
        root = "~/timereg",
        directory = "%Y/%V",
      }, now),
      "~/timereg/2026/21/2026-05-18.wkl"
    )
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
end
