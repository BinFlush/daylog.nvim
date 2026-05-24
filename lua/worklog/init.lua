local filetype = require("worklog.filetype")
local append_copy = require("worklog.usecases.append_copy")
local carryover = require("worklog.usecases.carryover")
local check = require("worklog.usecases.check")
local config = require("worklog.config")
local insert_now = require("worklog.usecases.insert_now")
local journal = require("worklog.journal")
local log_current = require("worklog.usecases.log_current")
local new_worklog = require("worklog.usecases.new_worklog")
local order_worklogs = require("worklog.usecases.order_worklogs")
local refresh_summaries = require("worklog.usecases.refresh_summaries")
local render = require("worklog.render")
local repeat_current = require("worklog.usecases.repeat_current")
local summarize = require("worklog.usecases.summarize")
local syntax = require("worklog.syntax")
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

-- Run a use case over the current buffer and apply its edit script, warning on
-- failure. Extra arguments are forwarded to the use case after the buffer lines.
local function run_buffer_usecase(run, ...)
  local result, err = run(buffer_lines(), ...)
  if not result then
    warn(err)
    return false
  end

  apply_result(result)
  return true
end

-- Guards against the refresh edits re-triggering the auto-refresh autocmds.
local refreshing = false

-- Rebuild every worklog's existing summary to match its entries. A no-op when
-- all summaries are already current. `join` merges the edit into the previous
-- undo block, used by the autocmd-driven refreshes so one keystroke stays one
-- undo step.
local function apply_refresh(join)
  if refreshing then
    return
  end

  local result = refresh_summaries.run(buffer_lines())
  if not result.edits or #result.edits == 0 then
    return
  end

  refreshing = true
  pcall(function()
    if join then
      pcall(vim.cmd, "undojoin")
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    apply_result(result)

    -- Restore the cursor, clamped to the possibly-resized buffer.
    local line_count = vim.api.nvim_buf_line_count(0)
    local row = math.min(cursor[1], line_count)
    local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
    vim.api.nvim_win_set_cursor(0, { row, math.min(cursor[2], #line) })
  end)
  refreshing = false
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

local function expanded_journal_settings()
  local settings = config.get().journal
  if settings == nil then
    return nil
  end

  return {
    root = vim.fn.expand(settings.root),
    directory = settings.directory,
  }
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

-- An optional positive day-step count; an empty argument defaults to 1.
local function parse_step_count(value)
  if value == nil or value == "" then
    return 1
  end

  return parse_positive_integer(value)
end

local function parse_day_offset(value)
  if value == nil or value == "" then
    return 0
  end

  if type(value) ~= "string" or value:match("^[+-]?%d+$") == nil then
    return nil, "worklog: day offset must be an integer"
  end

  local number = tonumber(value)
  if number == nil then
    return nil, "worklog: day offset must be an integer"
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

-- Open (creating the directory, file, and header as needed) the journal file
-- for a date. Returns ok, was_initialized.
local function open_journal_file(settings, date)
  local path = journal.path_for_date(settings, date)
  local directory = vim.fn.fnamemodify(path, ":h")

  if vim.fn.isdirectory(directory) == 0 and vim.fn.mkdir(directory, "p") == 0 then
    warn("worklog: failed to create journal directory: " .. directory)
    return false
  end

  local should_initialize = vim.fn.filereadable(path) == 0 or vim.fn.getfsize(path) == 0

  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    warn(tostring(err))
    return false
  end

  if should_initialize and not apply_new_worklog(config.get().defaults) then
    return false
  end

  return true, should_initialize
end

-- The journal date the current buffer represents, or nil when it is not a
-- canonical journal file (unnamed buffer, journal unconfigured, or a dated file
-- outside the configured location).
local function current_buffer_journal_date(settings)
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return nil
  end

  return journal.date_from_path(settings, vim.fn.fnamemodify(name, ":p"))
end

-- Roll a task that ran across midnight into today: close the previous day at
-- 24:00, open/create today, continue the activity from 00:00, then apply the
-- originating command at the current time. Returns true when it took over the
-- request (carried over, declined, or intentionally refused), false when this
-- is not a carryover situation and the caller should hard-block instead.
local function run_carryover(settings, command, now)
  local lines = buffer_lines()

  local carried = carryover.last_running_entry(lines)
  if not carried then
    return false
  end

  -- Capture the cursor entry before the buffer switches away.
  local repeated
  if command == "repeat" then
    local err
    repeated, err = carryover.entry_at_row(lines, cursor_row())
    if not repeated then
      warn(err)
      return true
    end
  end

  local today_path = journal.path_for_date(settings, now)
  if vim.fn.filereadable(today_path) == 1 and vim.fn.getfsize(today_path) > 0 then
    warn("worklog: today's worklog already exists; open it with :WorklogToday")
    return true
  end

  local prompt = string.format("Past midnight: carry '%s' over to today's worklog?", carried.text)
  if vim.fn.confirm(prompt, "&Yes\n&No", 1) ~= 1 then
    return true
  end

  local close, close_err = carryover.close_edit(lines)
  if not close then
    warn(close_err)
    return true
  end
  apply_result(close)

  if not pcall(vim.cmd, "silent write") then
    warn("worklog: failed to save the previous day before carrying over")
    return true
  end

  if not open_journal_file(settings, now) then
    return true
  end

  local seed, seed_err = carryover.seed_edit(buffer_lines(), carried, 0)
  if not seed then
    warn(seed_err)
    return true
  end
  apply_result(seed)

  if command == "repeat" then
    local clock = os.date("*t", now)
    local seed_repeat, seed_repeat_err =
      carryover.seed_edit(buffer_lines(), repeated, clock.hour * 60 + clock.min)
    if not seed_repeat then
      warn(seed_repeat_err)
      return true
    end
    apply_result(seed_repeat)
  else
    apply_insert_time(os.date("%H:%M", now))
  end

  return true
end

-- Refuse to stamp the current time into a day that is not today. When the
-- buffer is not a canonical journal file the guard stays silent so the plugin
-- keeps working on arbitrary files. Returns true when the request was handled
-- (blocked or carried over) and the caller should stop.
local function guard_current_time(command)
  local settings = expanded_journal_settings()
  if settings == nil then
    return false
  end

  local file_date = current_buffer_journal_date(settings)
  if file_date == nil then
    return false
  end

  local now = os.time()
  if journal.same_date(file_date, now) then
    return false
  end

  if
    journal.same_date(file_date, journal.offset_date(now, -1))
    and run_carryover(settings, command, now)
  then
    return true
  end

  warn(
    string.format(
      "worklog: this file is dated %s, not today (%s); refusing to insert the current time",
      journal.date_label(file_date),
      journal.date_label(now)
    )
  )
  return true
end

-- Insert the current time at the cursor and enter insert mode.
function M.insert_now()
  if guard_current_time("insert") then
    return
  end

  apply_insert_time(os.date("%H:%M"))
end

-- Set the active worklog's single summary (replacing any existing one).
function M.append_summary()
  run_buffer_usecase(summarize.run, syntax.REPORT_KIND.EXACT)
end

function M.append_quantized_summary()
  run_buffer_usecase(summarize.run, syntax.REPORT_KIND.QUANTIZED)
end

function M.append_copy()
  run_buffer_usecase(append_copy.run)
end

function M.repeat_current()
  if guard_current_time("repeat") then
    return
  end

  run_buffer_usecase(repeat_current.run, cursor_row(), os.date("%H:%M"))
end

function M.order_worklogs()
  run_buffer_usecase(order_worklogs.run)
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

function M.log_current()
  run_buffer_usecase(log_current.run, cursor_row())
end

-- Rebuild every existing summary in the current buffer to match its entries.
function M.refresh()
  apply_refresh(false)
end

function M.new_worklog()
  apply_new_worklog(config.get().defaults)
end

function M.open_today(day_offset)
  local settings = expanded_journal_settings()
  if settings == nil then
    warn("worklog: journal.root is not configured")
    return
  end

  if not can_abandon_current_buffer() then
    warn("worklog: current buffer has unsaved changes")
    return
  end

  local now = os.time()
  local offset = day_offset or 0
  local target_date = journal.offset_date(now, offset)

  local ok, was_initialized = open_journal_file(settings, target_date)
  if not ok then
    return
  end

  if offset ~= 0 or not was_initialized then
    return
  end

  apply_insert_time(os.date("%H:%M", now))
end

-- Open the journal file `step` days from the one in the current buffer, falling
-- back to today when the buffer is not a canonical journal file. Pure
-- navigation: it never inserts the current time, even when it lands on today.
function M.open_relative_day(step)
  local settings = expanded_journal_settings()
  if settings == nil then
    warn("worklog: journal.root is not configured")
    return
  end

  if not can_abandon_current_buffer() then
    warn("worklog: current buffer has unsaved changes")
    return
  end

  local anchor = current_buffer_journal_date(settings) or os.time()
  open_journal_file(settings, journal.offset_date(anchor, step))
end

function M.open_week(aggregate_only)
  local settings = expanded_journal_settings()
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
    render.week_report_lines(report, config.get().defaults.duration_format, {
      aggregate_only = aggregate_only,
    }),
    (aggregate_only and "worklog-week-summary-" or "worklog-week-") .. report.period_label .. ".wkl"
  )
end

function M.open_days(count, aggregate_only)
  local settings = expanded_journal_settings()
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
    render.days_report_lines(report, config.get().defaults.duration_format, {
      aggregate_only = aggregate_only,
    }),
    (aggregate_only and "worklog-days-summary-" or "worklog-days-") .. report.period_label .. ".wkl"
  )
end

-- Wire the autocmds that drive automatic summary refresh for the configured
-- mode. `off` installs nothing (manual :WorklogRefresh still works).
local function setup_auto_summary(mode)
  if mode == "off" then
    return
  end

  local group = vim.api.nvim_create_augroup("WorklogAutoSummary", { clear = true })

  local function on_worklog_buffer(opts, action)
    if vim.bo[opts.buf].filetype == "worklog" then
      action()
    end
  end

  if mode == "save" then
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = group,
      callback = function(opts)
        on_worklog_buffer(opts, function()
          apply_refresh(true)
        end)
      end,
    })
  elseif mode == "idle" then
    vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI", "InsertLeave" }, {
      group = group,
      callback = function(opts)
        on_worklog_buffer(opts, function()
          apply_refresh(true)
        end)
      end,
    })
  elseif mode == "change" then
    local generation = 0
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      callback = function(opts)
        on_worklog_buffer(opts, function()
          generation = generation + 1
          local scheduled = generation
          -- Debounce: only the last change in a burst refreshes.
          vim.defer_fn(function()
            if scheduled == generation then
              apply_refresh(true)
            end
          end, 200)
        end)
      end,
    })
  end
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

  ensure_user_command("WorklogToday", function(args)
    local offset, err = parse_day_offset(args.args)
    if offset == nil then
      warn(err)
      return
    end

    M.open_today(offset)
  end, {
    nargs = "?",
  })

  ensure_user_command("WorklogNextDay", function(args)
    local count, err = parse_step_count(args.args)
    if not count then
      warn(err)
      return
    end

    M.open_relative_day(count)
  end, {
    nargs = "?",
  })

  ensure_user_command("WorklogPrevDay", function(args)
    local count, err = parse_step_count(args.args)
    if not count then
      warn(err)
      return
    end

    M.open_relative_day(-count)
  end, {
    nargs = "?",
  })

  ensure_user_command("WorklogWeek", function(args)
    M.open_week(args.bang)
  end, {
    bang = true,
  })

  ensure_user_command("WorklogDays", function(args)
    local count, err = parse_positive_integer(args.args)
    if not count then
      warn(err)
      return
    end

    M.open_days(count, args.bang)
  end, {
    bang = true,
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

  ensure_user_command("WorklogLog", function()
    M.log_current()
  end)

  ensure_user_command("WorklogRefresh", function()
    M.refresh()
  end)

  setup_auto_summary(config.get().auto_summary)
end

return M
