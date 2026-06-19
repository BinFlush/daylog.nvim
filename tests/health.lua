return function(t)
  local health = require("blotter.health")
  local blotter = require("blotter")

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
    blotter.setup()

    local ok, err = pcall(blotter.setup)
    t.ok(ok, err)
  end)

  t.test("health check reports core integration", function()
    blotter.setup()

    local reports = capture_reports(modern_methods, function()
      health.check()
    end)

    t.eq(#reports.error, 0)
    t.eq(#reports.warn, 0)
    t.ok(includes(reports.start, "blotter.nvim"))
    t.ok(includes(reports.ok, 'require("blotter") succeeded'))
    t.ok(includes(reports.ok, "blotter.setup is available"))
    t.ok(includes(reports.ok, ":BlotInsert is available"))
    t.ok(includes(reports.ok, ":BlotterToday is available"))
    t.ok(includes(reports.ok, ":BlotterInit is available"))
    t.ok(includes(reports.ok, ":BlotterNextDay is available"))
    t.ok(includes(reports.ok, ":BlotterPrevDay is available"))
    t.ok(includes(reports.ok, ":BlotterDays is available"))
    t.ok(includes(reports.ok, ":BlotterWeek is available"))
    t.ok(includes(reports.ok, ":BlotRepeat is available"))
    t.ok(includes(reports.ok, ":BlotterCopy is available"))
    t.ok(includes(reports.ok, ":BlotterOrder is available"))
    t.ok(includes(reports.ok, ":BlotLog is available"))
    t.ok(includes(reports.ok, ":BlotterRefresh is available"))
    t.ok(includes(reports.ok, "example.blot detects as blotter"))
    t.ok(includes(reports.ok, ":help blotter.nvim is available"))
  end)

  t.test("health check supports legacy health api", function()
    blotter.setup()

    local reports = capture_reports(legacy_methods, function()
      health.check()
    end)

    t.eq(#reports.error, 0)
    t.eq(#reports.warn, 0)
    t.ok(includes(reports.start, "blotter.nvim"))
    t.ok(includes(reports.ok, 'require("blotter") succeeded'))
    t.ok(includes(reports.ok, ":BlotInsert is available"))
  end)

  t.test("health check does not reset the user's configuration", function()
    local config = require("blotter.config")
    blotter.setup({
      journal = { root = "/tmp/hc", directory = "%Y" },
      auto_summary = "idle",
    })

    capture_reports(modern_methods, function()
      health.check()
    end)

    t.eq(config.get().journal.root, "/tmp/hc")
    t.eq(config.get().auto_summary, "idle")

    blotter.setup()
  end)

  t.test("health reports configured sources and a missing cache", function()
    blotter.setup({
      sources = {
        ADO = {
          type = "azure_devops",
          organization = "contoso",
          project = "Platform",
          token = function()
            return "pat"
          end,
        },
      },
    })

    -- Point the cache dir at a fresh temp path so the "no cache yet" branch is
    -- deterministic regardless of any real cache on the machine.
    local old_stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(what)
      if what == "cache" then
        return vim.fn.tempname()
      end
      return old_stdpath(what)
    end

    local reports = capture_reports(modern_methods, function()
      health.check()
    end)

    vim.fn.stdpath = old_stdpath

    t.ok(includes(reports.start, "Sources"))
    t.ok(includes(reports.ok, "source ADO (azure_devops) is configured"))
    t.ok(includes(reports.ok, ":BlotterSync is available"))

    local warned = false
    for _, item in ipairs(reports.warn) do
      if item.message == "source ADO has no cache yet" then
        warned = true
      end
    end
    t.ok(warned, "expected a 'no cache yet' warning for ADO")

    blotter.setup()
  end)

  t.test("health reports a registered custom source", function()
    local registry = require("blotter.sources.registry")
    blotter.setup() -- clears the registry; no config sources declared

    registry.register("Jira", {
      fetch = function(cb)
        cb({})
      end,
      format_item = function(item)
        return item.id
      end,
      to_blot_text = function(item)
        return item.id
      end,
    })

    local old_stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(what)
      if what == "cache" then
        return vim.fn.tempname()
      end
      return old_stdpath(what)
    end

    local reports = capture_reports(modern_methods, function()
      health.check()
    end)

    vim.fn.stdpath = old_stdpath

    t.ok(includes(reports.start, "Sources"))
    t.ok(includes(reports.ok, "source Jira (registered) is configured"))

    blotter.setup() -- clear the registry again
  end)
end
