-- Tests for report_write: the day-file targets of a resolved report row, and the guarded fan-out write
-- that warns (instead of throwing) when a disk write fails part-way.
return function(t)
  local report_write = require("daylog.report_write")
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_captured_notify = helpers.with_captured_notify

  t.test("target_paths is the single path for a day row, every day for an aggregate", function()
    local report =
      { days = { { path = "/d/1.day" }, { path = "/d/2.day" }, { path = "/d/3.day" } } }
    t.eq(report_write.target_paths(report, { scope = "day", path = "/d/2.day" }), { "/d/2.day" })
    t.eq(
      report_write.target_paths(report, { scope = "period" }),
      { "/d/1.day", "/d/2.day", "/d/3.day" }
    )
  end)

  t.test("apply_changes writes each file to disk and returns true", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local a, b = dir .. "/a.day", dir .. "/b.day"
    local ok = report_write.apply_changes({
      { path = a, lines = { "--- log ---", "08:00 plan" } },
      { path = b, lines = { "--- log ---", "09:00 review" } },
    })
    t.eq(ok, true)
    t.eq(vim.fn.readfile(a), { "--- log ---", "08:00 plan" })
    t.eq(vim.fn.readfile(b), { "--- log ---", "09:00 review" })
  end)

  t.test("apply_changes aborts the whole fan-out and warns on a write failure", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local good = dir .. "/good.day"
    local bad = dir .. "/no-such-subdir/bad.day" -- parent does not exist -> staging fails
    with_captured_notify(function(messages)
      local ok = report_write.apply_changes({
        { path = good, lines = { "written" } },
        { path = bad, lines = { "never" } },
      })
      t.eq(ok, false)
      t.eq(messages[1].level, vim.log.levels.WARN)
      t.ok(
        messages[1].message:find("could not write", 1, true) ~= nil,
        "warns with a daylog: message"
      )
    end)
    -- All-or-nothing: the good change was staged then rolled back, so NEITHER file exists, no temp is
    -- left behind, and the command did not throw.
    t.eq(vim.fn.filereadable(good), 0)
    t.eq(vim.fn.filereadable(bad), 0)
    t.eq(vim.fn.filereadable(good .. ".tmp"), 0)
  end)

  t.test(
    "a fan-out failure leaves an existing day file untouched (atomic, no truncation)",
    function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local existing = dir .. "/existing.day"
      vim.fn.writefile({ "--- log ---", "08:00 original" }, existing)
      local bad = dir .. "/no-such-subdir/bad.day"
      with_captured_notify(function()
        report_write.apply_changes({
          { path = existing, lines = { "--- log ---", "09:00 replacement" } },
          { path = bad, lines = { "never" } },
        })
      end)
      -- Staged then rolled back: the original content survives intact, never truncated.
      t.eq(vim.fn.readfile(existing), { "--- log ---", "08:00 original" })
    end
  )
end
