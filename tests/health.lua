return function(t)
  local health = require("daylog.health")
  local daylog = require("daylog")

  local function capture_reports(methods, fn)
    local reports = {
      start = {},
      ok = {},
      info = {},
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
      info = function(message)
        table.insert(reports.info, message)
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
      report_info = function(message)
        table.insert(reports.info, message)
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

  -- The one honest :Daylog line health reports, built from the same dispatch-derived verb list.
  local function daylog_available_line()
    local verbs = require("daylog.commands").verb_names()
    return string.format(":Daylog is available (%d verbs: %s)", #verbs, table.concat(verbs, ", "))
  end

  t.test("setup can run more than once", function()
    daylog.setup()

    local ok, err = pcall(daylog.setup)
    t.ok(ok, err)
  end)

  t.test("health check reports core integration", function()
    daylog.setup()

    local reports = capture_reports(modern_methods, function()
      health.check()
    end)

    t.eq(#reports.error, 0)
    t.eq(#reports.warn, 0)
    t.ok(includes(reports.start, "daylog.nvim"))
    t.ok(includes(reports.ok, 'require("daylog") succeeded'))
    t.ok(includes(reports.ok, "daylog.setup is available"))
    t.ok(includes(reports.ok, daylog_available_line()))

    -- The verb list is derived from the dispatch table, sorted, and includes the verbs the old
    -- hardcoded health list had drifted past.
    local verbs = require("daylog.commands").verb_names()
    local sorted = vim.deepcopy(verbs)
    table.sort(sorted)
    t.eq(verbs, sorted)
    for _, verb in ipairs({ "bar", "export", "keys", "sync", "today", "insert" }) do
      t.ok(vim.tbl_contains(verbs, verb), verb .. " should be a dispatchable verb")
    end

    t.ok(includes(reports.ok, "example.day detects as daylog"))
    t.ok(includes(reports.ok, ":help daylog.nvim is available"))
    t.ok(includes(reports.start, "Pickers"))
    -- Telescope is not on the test runtimepath, so the picker section takes the
    -- fallback branch (an info note, never a warning or error).
    t.ok(
      includes(
        reports.info,
        "Telescope is not installed (using the vim.ui.select fallback -- fully functional)"
      )
    )
  end)

  t.test("health check supports legacy health api", function()
    daylog.setup()

    local reports = capture_reports(legacy_methods, function()
      health.check()
    end)

    t.eq(#reports.error, 0)
    t.eq(#reports.warn, 0)
    t.ok(includes(reports.start, "daylog.nvim"))
    t.ok(includes(reports.ok, 'require("daylog") succeeded'))
    t.ok(includes(reports.ok, daylog_available_line()))
  end)

  t.test("health check does not reset the user's configuration", function()
    local config = require("daylog.config")
    daylog.setup({
      daybook = { root = "/tmp/hc", directory = "%Y" },
      auto_summary = "idle",
    })

    capture_reports(modern_methods, function()
      health.check()
    end)

    t.eq(config.get().daybook.root, "/tmp/hc")
    t.eq(config.get().auto_summary, "idle")

    daylog.setup()
  end)

  t.test("health reports configured sources and a missing cache", function()
    daylog.setup({
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
    t.ok(includes(reports.ok, daylog_available_line()))

    local warned = false
    for _, item in ipairs(reports.warn) do
      if item.message == "source ADO has no cache yet" then
        warned = true
      end
    end
    t.ok(warned, "expected a 'no cache yet' warning for ADO")

    daylog.setup()
  end)

  t.test("health reports a registered custom source", function()
    local registry = require("daylog.sources.registry")
    daylog.setup() -- clears the registry; no config sources declared

    registry.register("Jira", {
      fetch = function(cb)
        cb({})
      end,
      format_item = function(item)
        return item.id
      end,
      to_entry_text = function(item)
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

    daylog.setup() -- clear the registry again
  end)
end
