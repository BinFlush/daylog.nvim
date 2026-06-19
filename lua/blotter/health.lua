local config = require("blotter.config")
local sources_sync = require("blotter.sources.sync")
local sources_registry = require("blotter.sources.registry")

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
      "Run require('blotter').setup() during startup.",
    })
  end
end

function M.check()
  start("worklog.nvim")

  local loaded, worklog = pcall(require, "blotter")
  if loaded then
    ok('require("blotter") succeeded')
  else
    report_error('require("blotter") failed', {
      tostring(worklog),
    })
    return
  end

  if type(worklog.setup) == "function" then
    ok("worklog.setup is available")
  else
    report_error("worklog.setup is missing", {
      "Export a setup function from require('blotter').",
    })
    return
  end

  -- Intentionally do not call worklog.setup() here: it would reset the user's
  -- live configuration and refresh autocmds. The command checks below verify
  -- that setup has already been run.
  start("Commands")
  check_command("BlotInsert")
  check_command("BlotterToday")
  check_command("BlotterInit")
  check_command("BlotterNextDay")
  check_command("BlotterPrevDay")
  check_command("BlotterDays")
  check_command("BlotterWeek")
  check_command("BlotRepeat")
  check_command("BlotterCopy")
  check_command("BlotterOrder")
  check_command("BlotLog")
  check_command("BlotterRefresh")
  check_command("BlotterSync")

  start("Filetype")
  if vim.filetype.match({ filename = "example.blot" }) == "blotter" then
    ok("example.blot detects as blotter")
  else
    report_error("example.blot does not detect as blotter", {
      "Expected vim.filetype.match({ filename = 'example.blot' }) to return 'blotter'.",
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

  -- Report every registered source -- built-in (declared in config) and custom
  -- (registered directly) -- so the section reflects what actually works. Reads
  -- config.get() only to label the declared type; never calls setup.
  local config_sources = config.get().sources or {}
  local names = sources_registry.names()
  if #names > 0 then
    start("Sources")

    if vim.fn.executable("curl") == 1 then
      ok("curl is available")
    else
      report_error("curl is not on PATH", {
        "Install curl; worklog source sync uses curl for HTTP.",
      })
    end

    for _, name in ipairs(names) do
      local declared = config_sources[name]
      ok(
        string.format(
          "source %s (%s) is configured",
          name,
          declared and declared.type or "registered"
        )
      )

      if vim.fn.filereadable(sources_sync.cache_path(name)) == 1 then
        local cache = sources_sync.read_cache(name)
        if cache then
          ok(string.format("source %s cache is readable (%d items)", name, #(cache.items or {})))
        else
          warn(string.format("source %s cache is unreadable or corrupt", name), {
            "Run :BlotterSync " .. name .. " to rebuild it.",
          })
        end
      else
        warn(string.format("source %s has no cache yet", name), {
          "Run :BlotterSync " .. name .. " or pick from it once.",
        })
      end
    end
  end
end

return M
