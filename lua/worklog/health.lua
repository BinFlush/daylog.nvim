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

  local setup_ok, setup_err = pcall(worklog.setup)
  if setup_ok then
    ok("worklog.setup() ran without error")
  else
    report_error("worklog.setup() failed", {
      tostring(setup_err),
    })
    return
  end

  start("Commands")
  check_command("WorklogNew")
  check_command("WorklogInsert")
  check_command("WorklogRepeat")
  check_command("WorklogCopy")
  check_command("WorklogOrder")
  check_command("WorklogSummarize")
  check_command("WorklogQuantSum")
  check_command("WorklogCheck")

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
end

return M
