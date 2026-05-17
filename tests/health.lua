return function(t)
  local health = require("worklog.health")
  local worklog = require("worklog")

  local function capture_reports(methods, fn)
    local reports = {
      start = {},
      ok = {},
      warn = {},
      error = {},
    }
    local old_health = vim.health

    vim.health = methods(reports)

    local ok, err = xpcall(fn, debug.traceback)
    vim.health = old_health

    if not ok then
      error(err, 0)
    end

    return reports
  end

  local function modern_methods(reports)
    return {
      start = function(message)
        table.insert(reports.start, message)
      end,
      ok = function(message)
        table.insert(reports.ok, message)
      end,
      warn = function(message, advice)
        table.insert(reports.warn, {
          message = message,
          advice = advice,
        })
      end,
      error = function(message, advice)
        table.insert(reports.error, {
          message = message,
          advice = advice,
        })
      end,
    }
  end

  local function legacy_methods(reports)
    return {
      report_start = function(message)
        table.insert(reports.start, message)
      end,
      report_ok = function(message)
        table.insert(reports.ok, message)
      end,
      report_warn = function(message, advice)
        table.insert(reports.warn, {
          message = message,
          advice = advice,
        })
      end,
      report_error = function(message, advice)
        table.insert(reports.error, {
          message = message,
          advice = advice,
        })
      end,
    }
  end

  local function includes(messages, expected)
    for _, message in ipairs(messages) do
      if message == expected then
        return true
      end
    end

    return false
  end

  t.test("setup can run more than once", function()
    worklog.setup()

    local ok, err = pcall(worklog.setup)
    t.ok(ok, err)
  end)

  t.test("health check reports core integration", function()
    local reports = capture_reports(modern_methods, function()
      health.check()
    end)

    t.eq(#reports.error, 0)
    t.eq(#reports.warn, 0)
    t.ok(includes(reports.start, "worklog.nvim"))
    t.ok(includes(reports.ok, 'require("worklog") succeeded'))
    t.ok(includes(reports.ok, "worklog.setup is available"))
    t.ok(includes(reports.ok, "worklog.setup() ran without error"))
    t.ok(includes(reports.ok, ":WorklogNew is available"))
    t.ok(includes(reports.ok, ":WorklogInsert is available"))
    t.ok(includes(reports.ok, ":WorklogRepeat is available"))
    t.ok(includes(reports.ok, ":WorklogCopy is available"))
    t.ok(includes(reports.ok, ":WorklogOrder is available"))
    t.ok(includes(reports.ok, ":WorklogSummarize is available"))
    t.ok(includes(reports.ok, ":WorklogQuantSum is available"))
    t.ok(includes(reports.ok, ":WorklogCheck is available"))
    t.ok(includes(reports.ok, "example.wkl detects as worklog"))
    t.ok(includes(reports.ok, ":help worklog.nvim is available"))
  end)

  t.test("health check supports legacy health api", function()
    local reports = capture_reports(legacy_methods, function()
      health.check()
    end)

    t.eq(#reports.error, 0)
    t.eq(#reports.warn, 0)
    t.ok(includes(reports.start, "worklog.nvim"))
    t.ok(includes(reports.ok, 'require("worklog") succeeded'))
    t.ok(includes(reports.ok, ":WorklogNew is available"))
  end)
end
