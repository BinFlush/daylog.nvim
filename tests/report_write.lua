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

  t.test("apply_changes stops and warns on the first write failure", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local good = dir .. "/good.day"
    local bad = dir .. "/no-such-subdir/bad.day" -- parent does not exist -> writefile fails
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
    -- The file before the failure kept its content; the command did not throw.
    t.eq(vim.fn.readfile(good), { "written" })
    t.eq(vim.fn.filereadable(bad), 0)
  end)
end
