local config = require("daylog.config")
local sources_sync = require("daylog.sources.sync")
local sources_registry = require("daylog.sources.registry")

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

local function info(message)
  if vim.health and vim.health.info then
    vim.health.info(message)
  else
    vim.health.report_info(message)
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
      "Run require('daylog').setup() during startup.",
    })
  end
end

function M.check()
  start("daylog.nvim")

  local loaded, daylog = pcall(require, "daylog")
  if loaded then
    ok('require("daylog") succeeded')
  else
    report_error('require("daylog") failed', {
      tostring(daylog),
    })
    return
  end

  if type(daylog.setup) == "function" then
    ok("daylog.setup is available")
  else
    report_error("daylog.setup is missing", {
      "Export a setup function from require('daylog').",
    })
    return
  end

  -- Intentionally do not call daylog.setup() here: it would reset the user's
  -- live configuration and refresh autocmds. The command checks below verify
  -- that setup has already been run.
  start("Commands")
  check_command("DaylogInsert")
  check_command("DaylogToday")
  check_command("DaylogInit")
  check_command("DaylogNextDay")
  check_command("DaylogPrevDay")
  check_command("DaylogDays")
  check_command("DaylogRepeat")
  check_command("DaylogCopy")
  check_command("DaylogOrder")
  check_command("DaylogLog")
  check_command("DaylogRefresh")
  check_command("DaylogSync")

  start("Filetype")
  if vim.filetype.match({ filename = "example.day" }) == "daylog" then
    ok("example.day detects as daylog")
  else
    report_error("example.day does not detect as daylog", {
      "Expected vim.filetype.match({ filename = 'example.day' }) to return 'daylog'.",
    })
  end

  start("Documentation")
  if has_help_tag("daylog.nvim") then
    ok(":help daylog.nvim is available")
  else
    warn(":help daylog.nvim is unavailable", {
      "Run :helptags doc or just helptags.",
    })
  end

  -- Telescope is optional: it enables live whole-tracker search in the source,
  -- rename, and map pickers. Without it the pickers fall back to vim.ui.select
  -- (fzf-lua / snacks / mini.pick included) -- fully functional, just no live search.
  start("Pickers")
  if pcall(require, "telescope") then
    ok("Telescope is installed (live whole-tracker search for sources, rename, and map)")
  else
    info("Telescope is not installed (using the vim.ui.select fallback -- fully functional)")
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
        "Install curl; daylog source sync uses curl for HTTP.",
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
            "Run :DaylogSync " .. name .. " to rebuild it.",
          })
        end
      else
        warn(string.format("source %s has no cache yet", name), {
          "Run :DaylogSync " .. name .. " or pick from it once.",
        })
      end
    end
  end
end

return M
