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
end
