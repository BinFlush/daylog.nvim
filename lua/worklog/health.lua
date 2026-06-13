local config = require("worklog.config")
local sources_sync = require("worklog.sources.sync")

local M = {}

local function start(name)
  if vim.health and vim.health.start then
    vim.health.start(name)
  else
    vim.health.report_start(name)
  end
end

local function ok(message)
  if vim.health and vim.health.ok then
    vim.health.ok(message)
  else
    vim.health.report_ok(message)
  end
end

local function warn(message, advice)
  if vim.health and vim.health.warn then
    vim.health.warn(message, advice)
  else
    vim.health.report_warn(message, advice)
  end
end

local function report_error(message, advice)
  if vim.health and vim.health.error then
    vim.health.error(message, advice)
  else
    vim.health.report_error(message, advice)
  end
end

local function has_command(name)
  return vim.fn.exists(":" .. name) == 2
end

local function has_help_tag(name)
  for _, item in ipairs(vim.fn.getcompletion(name, "help")) do
    if item == name then
      return true
    end
  end

  return false
end

local function check_command(name)
  if has_command(name) then
    ok(":" .. name .. " is available")
  else
    report_error(":" .. name .. " is missing", {
      "Run require('worklog').setup() during startup.",
    })
  end
end

function M.check()
  start("worklog.nvim")

  local loaded, worklog = pcall(require, "worklog")
  if loaded then
    ok('require("worklog") succeeded')
  else
    report_error('require("worklog") failed', {
      tostring(worklog),
    })
    return
  end

  if type(worklog.setup) == "function" then
    ok("worklog.setup is available")
  else
    report_error("worklog.setup is missing", {
      "Export a setup function from require('worklog').",
    })
    return
  end

  -- Intentionally do not call worklog.setup() here: it would reset the user's
  -- live configuration and refresh autocmds. The command checks below verify
  -- that setup has already been run.
  start("Commands")
  check_command("WorklogInsert")
  check_command("WorklogToday")
  check_command("WorklogNextDay")
  check_command("WorklogPrevDay")
  check_command("WorklogDays")
  check_command("WorklogWeek")
  check_command("WorklogRepeat")
  check_command("WorklogCopy")
  check_command("WorklogOrder")
  check_command("WorklogLog")
  check_command("WorklogRefresh")
  check_command("WorklogSync")

  start("Filetype")
  if vim.filetype.match({ filename = "example.wkl" }) == "worklog" then
    ok("example.wkl detects as worklog")
  else
    report_error("example.wkl does not detect as worklog", {
      "Expected vim.filetype.match({ filename = 'example.wkl' }) to return 'worklog'.",
    })
  end

  start("Documentation")
  if has_help_tag("worklog.nvim") then
    ok(":help worklog.nvim is available")
  else
    warn(":help worklog.nvim is unavailable", {
      "Run :helptags doc or just helptags.",
    })
  end

  -- Only report on sources when some are configured, so the default install stays
  -- clean. Reads config.get() (never calls setup), matching the section above.
  local sources = config.get().sources
  if sources and next(sources) then
    start("Sources")

    if vim.fn.executable("curl") == 1 then
      ok("curl is available")
    else
      report_error("curl is not on PATH", {
        "Install curl; worklog source sync uses curl for HTTP.",
      })
    end

    local names = {}
    for name in pairs(sources) do
      table.insert(names, name)
    end
    table.sort(names)

    for _, name in ipairs(names) do
      ok(string.format("source %s (%s) is configured", name, sources[name].type))

      if vim.fn.filereadable(sources_sync.cache_path(name)) == 1 then
        local cache = sources_sync.read_cache(name)
        if cache then
          ok(string.format("source %s cache is readable (%d items)", name, #(cache.items or {})))
        else
          warn(string.format("source %s cache is unreadable or corrupt", name), {
            "Run :WorklogSync " .. name .. " to rebuild it.",
          })
        end
      else
        warn(string.format("source %s has no cache yet", name), {
          "Run :WorklogSync " .. name .. " or pick from it once.",
        })
      end
    end
  end
end

return M
