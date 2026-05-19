local filetype = require("worklog.filetype")
local append_copy = require("worklog.usecases.append_copy")
local append_quantized_summary = require("worklog.usecases.append_quantized_summary")
local append_summary = require("worklog.usecases.append_summary")
local check = require("worklog.usecases.check")
local config = require("worklog.config")
local insert_now = require("worklog.usecases.insert_now")
local journal = require("worklog.journal")
local new_worklog = require("worklog.usecases.new_worklog")
local order_worklogs = require("worklog.usecases.order_worklogs")
local render = require("worklog.render")
local repeat_current = require("worklog.usecases.repeat_current")
local week = require("worklog.week")

local M = {}

local function warn(message)
  vim.notify(message, vim.log.levels.WARN)
end

local function info(message)
  vim.notify(message, vim.log.levels.INFO)
end

local function ensure_user_command(name, callback, options)
  if vim.fn.exists(":" .. name) == 2 then
    return
  end

  vim.api.nvim_create_user_command(name, callback, options or {})
end

---@return string[]
local function buffer_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

---@return integer
local function cursor_row()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function apply_result(result)
  for _, edit in ipairs(result.edits or {}) do
    vim.api.nvim_buf_set_lines(0, edit.start_index, edit.end_index, false, edit.lines)
  end

  if result.cursor then
    vim.api.nvim_win_set_cursor(0, result.cursor)
  end

  if result.startinsert then
    vim.cmd("startinsert!")
  end
end

local function apply_insert_time(time)
  local lines = buffer_lines()
  local row = cursor_row()
  local result, err = insert_now.run(lines, row, time)
  if not result then
    warn(err)
    return false
  end

  apply_result(result)
  return true
end

local function apply_new_worklog(defaults)
  local lines = buffer_lines()
  local result, err = new_worklog.run(lines, defaults)
  if not result then
    warn(err)
    return false
  end

  apply_result(result)
  return true
end

local function unique_buffer_name(base_name)
  if vim.fn.bufexists(base_name) == 0 then
    return base_name
  end

  local suffix = 2
  local candidate = base_name .. "#" .. suffix

  while vim.fn.bufexists(candidate) == 1 do
    suffix = suffix + 1
    candidate = base_name .. "#" .. suffix
  end

  return candidate
end

local function journal_lines(path)
  if vim.fn.filereadable(path) == 1 then
    return vim.fn.readfile(path)
  end

  return nil
end

local function parse_positive_integer(value)
  if type(value) ~= "string" or value:match("^%d+$") == nil then
    return nil, "worklog: days count must be a positive integer"
  end

  local number = tonumber(value)
  if number == nil or number <= 0 then
    return nil, "worklog: days count must be a positive integer"
  end

  return number
end

local function open_report_buffer(lines, name)
  vim.cmd("botright new")
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
  vim.bo.buflisted = false
  vim.bo.swapfile = false
  if name then
    vim.api.nvim_buf_set_name(0, unique_buffer_name(name))
  end
  vim.bo.modifiable = true
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.bo.modified = false
  vim.bo.modifiable = false
end

local function can_abandon_current_buffer()
  return not vim.bo.modified or vim.o.hidden or vim.o.autowrite or vim.o.autowriteall
end

-- Insert the current time at the cursor and enter insert mode.
function M.insert_now()
  apply_insert_time(os.date("%H:%M"))
end

-- Append a summary and totals block based on the active worklog.
function M.append_summary()
  local lines = buffer_lines()
  local result, err = append_summary.run(lines)
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.append_quantized_summary()
  local lines = buffer_lines()
  local result, err = append_quantized_summary.run(lines)
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.append_copy()
  local lines = buffer_lines()
  local result, err = append_copy.run(lines)
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.repeat_current()
  local lines = buffer_lines()
  local row = cursor_row()
  local result, err = repeat_current.run(lines, row, os.date("%H:%M"))
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.order_worklogs()
  local lines = buffer_lines()
  local result, err = order_worklogs.run(lines)
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.check()
  local lines = buffer_lines()
  local result, err = check.run(lines)

  if not result then
    warn(err)
    return
  end

  info(result.message)
end

function M.new_worklog()
  apply_new_worklog(config.get().defaults)
end

function M.open_today()
  local settings = config.get().journal
  if settings == nil then
    warn("worklog: journal.root is not configured")
    return
  end

  if not can_abandon_current_buffer() then
    warn("worklog: current buffer has unsaved changes")
    return
  end

  local now = os.time()
  local path = journal.today_path(settings, now)
  local directory = vim.fn.fnamemodify(path, ":h")

  if vim.fn.isdirectory(directory) == 0 and vim.fn.mkdir(directory, "p") == 0 then
    warn("worklog: failed to create journal directory: " .. directory)
    return
  end

  local should_initialize = vim.fn.filereadable(path) == 0 or vim.fn.getfsize(path) == 0

  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    warn(tostring(err))
    return
  end

  if not should_initialize then
    return
  end

  if not apply_new_worklog(config.get().defaults) then
    return
  end

  apply_insert_time(os.date("%H:%M", now))
end

function M.open_week()
  local settings = config.get().journal
  if settings == nil then
    warn("worklog: journal.root is not configured")
    return
  end

  local report, err = week.build_week_report(settings, os.time(), journal_lines)
  if not report then
    warn(err)
    return
  end

  open_report_buffer(
    render.week_report_lines(report, config.get().defaults.duration_format),
    "worklog-week-" .. report.period_label
  )
end

function M.open_days(count)
  local settings = config.get().journal
  if settings == nil then
    warn("worklog: journal.root is not configured")
    return
  end

  local report, err = week.build_days_report(settings, os.time(), count, journal_lines)
  if not report then
    warn(err)
    return
  end

  open_report_buffer(
    render.days_report_lines(report, config.get().defaults.duration_format),
    "worklog-days-" .. report.period_label
  )
end

function M.setup(options)
  config.setup(options)
  filetype.register()

  ensure_user_command("WorklogNew", function()
    M.new_worklog()
  end)

  ensure_user_command("WorklogInsert", function()
    M.insert_now()
  end)

  ensure_user_command("WorklogToday", function()
    M.open_today()
  end)

  ensure_user_command("WorklogWeek", function()
    M.open_week()
  end)

  ensure_user_command("WorklogDays", function(args)
    local count, err = parse_positive_integer(args.args)
    if not count then
      warn(err)
      return
    end

    M.open_days(count)
  end, {
    nargs = 1,
  })

  ensure_user_command("WorklogRepeat", function()
    M.repeat_current()
  end)

  ensure_user_command("WorklogOrder", function()
    M.order_worklogs()
  end)

  ensure_user_command("WorklogCopy", function()
    M.append_copy()
  end)

  ensure_user_command("WorklogSummarize", function()
    M.append_summary()
  end)

  ensure_user_command("WorklogQuantSum", function()
    M.append_quantized_summary()
  end)

  ensure_user_command("WorklogCheck", function()
    M.check()
  end)
end

return M
