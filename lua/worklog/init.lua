local filetype = require("worklog.filetype")
local append_copy = require("worklog.usecases.append_copy")
local carryover = require("worklog.usecases.carryover")
local config = require("worklog.config")
local insert_entry = require("worklog.usecases.insert_entry")
local insert_now = require("worklog.usecases.insert_now")
local journal = require("worklog.journal")
local log_current = require("worklog.usecases.log_current")
local new_worklog = require("worklog.usecases.new_worklog")
local order_worklogs = require("worklog.usecases.order_worklogs")
local refresh_summaries = require("worklog.usecases.refresh_summaries")
local render = require("worklog.render")
local repeat_current = require("worklog.usecases.repeat_current")
local sources_http = require("worklog.sources.http")
local sources_registry = require("worklog.sources.registry")
local sources_sync = require("worklog.sources.sync")
local week = require("worklog.week")

local M = {}

local function warn(message)
  vim.notify(message, vim.log.levels.WARN)
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

-- Whether a line list holds no worklog content: empty or a single blank line.
-- Mirrors new_worklog's empty_buffer and week's empty_lines so every layer
-- agrees on what "empty" means.
local function lines_are_empty(lines)
  for _, line in ipairs(lines) do
    if line:find("%S") then
      return false
    end
  end

  return true
end

local function buffer_is_empty()
  return lines_are_empty(buffer_lines())
end

---@return integer
local function cursor_row()
  return vim.api.nvim_win_get_cursor(0)[1]
end

-- Guards the refresh edits from re-triggering the auto-refresh autocmds, and
-- signals apply_result that apply_refresh will publish diagnostics itself.
local refreshing = false

local diagnostic_namespace = vim.api.nvim_create_namespace("worklog")

-- Publish the worklog's problems (e.g. out-of-order timestamps) as buffer
-- diagnostics. They are recomputed and replace the previous set on every refresh,
-- so they clear themselves as soon as the worklog is valid again -- however it
-- was fixed -- and render inline in any mode.
local function publish_diagnostics(warnings)
  local items = {}

  for _, warning in ipairs(warnings or {}) do
    table.insert(items, {
      lnum = math.max((warning.row or 1) - 1, 0),
      col = 0,
      severity = vim.diagnostic.severity.WARN,
      source = "worklog",
      message = warning.message,
    })
  end

  vim.diagnostic.set(diagnostic_namespace, 0, items)
end

-- Recompute and publish the buffer's worklog diagnostics from its current text.
local function refresh_diagnostics()
  publish_diagnostics(refresh_summaries.run(buffer_lines()).warnings)
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

  -- Keep buffer diagnostics current after any edit. This is the single choke
  -- point every edit path flows through. apply_refresh already publishes from its
  -- own analysis (and sets `refreshing` around its edit), so skip while it runs.
  if not refreshing then
    refresh_diagnostics()
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

-- Rebuild every worklog's existing summary to match its entries, and publish the
-- buffer diagnostics for any problems found. A no-op edit-wise when all summaries
-- are already current. `join` merges the edit into the previous undo block, used
-- by the autocmd-driven refreshes so one keystroke stays one undo step.
local function apply_refresh(join)
  if refreshing then
    return
  end

  local result = refresh_summaries.run(buffer_lines())
  publish_diagnostics(result.warnings)

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

-- Insert a fully-resolved "HH:MM <text>" entry at the cursor's worklog and enter
-- insert mode. Mirrors apply_insert_time but carries an activity string (the text
-- is built and sanitized by the source layer before it gets here).
local function apply_insert_entry(time, text)
  local result, err = insert_entry.run(buffer_lines(), cursor_row(), time, text)
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

-- A loaded, file-backed buffer whose name resolves to `path`, or nil. Report
-- buffers (buftype "nofile", e.g. "worklog-week-2026-W21.wkl") are skipped so
-- they can never shadow a real journal file.
local function loaded_buffer_for_path(path)
  local target = vim.fn.fnamemodify(path, ":p")

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fn.fnamemodify(name, ":p") == target then
        return buf
      end
    end
  end

  return nil
end

-- Read a journal day's lines for reporting. Prefer a loaded buffer for the path
-- so reports reflect unsaved edits; otherwise fall back to the file on disk.
-- Returns nil when neither is available, which the report pipeline treats as an
-- empty day.
local function journal_lines(path)
  local buf = loaded_buffer_for_path(path)
  if buf then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  if vim.fn.filereadable(path) == 1 then
    return vim.fn.readfile(path)
  end

  return nil
end

-- True when a journal day already holds worklog content, considering a loaded
-- (possibly unsaved) buffer before falling back to the file on disk.
local function journal_path_has_content(path)
  local buf = loaded_buffer_for_path(path)
  if buf then
    return not lines_are_empty(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end

  if vim.fn.filereadable(path) == 0 then
    return false
  end

  -- Match the loaded-buffer branch: a whitespace-only file is empty, not content.
  return not lines_are_empty(vim.fn.readfile(path))
end

local function expanded_journal_settings()
  local settings = config.get().journal
  if settings == nil then
    return nil
  end

  return {
    -- Absolutize so a relative journal.root still matches the absolute buffer
    -- paths date_from_path compares against (it uses string equality).
    root = vim.fn.fnamemodify(vim.fn.expand(settings.root), ":p"),
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

  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    warn(tostring(err))
    return false
  end

  -- Decide from the live buffer, not disk: :edit reuses an existing unsaved
  -- buffer (today seeded but never written, then navigated away and back),
  -- whose content must not be re-seeded. A freshly opened missing/empty file is
  -- an empty buffer and gets the initial header.
  local should_initialize = buffer_is_empty()

  if should_initialize and not apply_new_worklog(config.get().defaults) then
    return false
  end

  return true, should_initialize
end

-- Open the journal file for a date for navigation only: never create the
-- directory or file and never write a header. A missing day opens as an empty,
-- unmodified buffer named for that date, so nothing is written to disk and the
-- buffer can be abandoned cleanly.
local function edit_journal_file(settings, date)
  local path = journal.path_for_date(settings, date)

  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    warn(tostring(err))
    return false
  end

  return true
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

-- Today's worklog must be left in a valid state: leaving a broken today (out-of-order
-- entries, an invalid entry, ...) would silently stop tracking the active day, so the
-- day-navigation commands refuse until it is fixed. Only today is guarded -- browsing a
-- past day's old problems is fine -- and only the plugin's own navigation (a raw :edit
-- cannot be vetoed). The problems are published as buffer diagnostics so they show up.
local function refuse_when_today_has_errors(settings)
  local file_date = current_buffer_journal_date(settings)
  if not file_date or not journal.same_date(file_date, os.time()) then
    return false
  end

  local warnings = refresh_summaries.run(buffer_lines()).warnings
  if #warnings == 0 then
    return false
  end

  publish_diagnostics(warnings)
  warn("worklog: today's worklog has errors; fix them before leaving the day")
  return true
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
  if journal_path_has_content(today_path) then
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

  -- Refresh the previous day's summary so the carried-over 24:00 close is
  -- reflected on disk regardless of the auto_summary mode (apply_result only
  -- republishes diagnostics; it does not recompute summaries).
  apply_refresh(false)

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

-- Bring the activity under the cursor into today's worklog at the current time,
-- used when :WorklogRepeat runs on another day's file. The browsed day is left
-- untouched; today is opened (created if needed) and the window switches to it.
local function run_cross_day_repeat(settings, now)
  -- Capture the activity before open_journal_file switches the buffer away.
  local activity, err = carryover.entry_at_row(buffer_lines(), cursor_row())
  if not activity then
    warn(err)
    return
  end

  -- Opening today switches the window away from the browsed day; refuse cleanly when
  -- that buffer cannot be abandoned (unsaved with 'hidden' off), the same way the day
  -- navigation does, instead of surfacing a raw E37 from the :edit below. The browsed
  -- day is left untouched, so -- unlike carryover -- it is not saved on the user's behalf.
  if not can_abandon_current_buffer() then
    warn("worklog: current buffer has unsaved changes")
    return
  end

  local clock = os.date("*t", now)
  local minutes = clock.hour * 60 + clock.min

  -- If today already holds a worklog, confirm the activity can be inserted there before
  -- switching to it, so a broken today is reported while staying on the browsed day
  -- rather than yanking the window across and only then failing. A missing/empty (or
  -- whitespace-only) today is initialized fresh by open_journal_file and always seeds.
  local today_lines = journal_lines(journal.path_for_date(settings, now))
  if today_lines and not lines_are_empty(today_lines) then
    local ok, validate_err = carryover.seed_edit(today_lines, activity, minutes)
    if not ok then
      warn(validate_err)
      return
    end
  end

  if not open_journal_file(settings, now) then
    return
  end

  local seed, seed_err = carryover.seed_edit(buffer_lines(), activity, minutes)
  if not seed then
    warn(seed_err)
    return
  end

  apply_result(seed)
  apply_refresh(false)
end

-- Refuse to stamp the current time into a day that is not today. When the
-- buffer is not a canonical journal file the guard stays silent so the plugin
-- keeps working on arbitrary files. Returns true when the request was handled
-- (blocked, carried over, or repeated into today) and the caller should stop.
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

  -- :WorklogRepeat on any other day brings the cursor activity into today instead
  -- of refusing; :WorklogInsert still refuses (there is no activity to carry).
  if command == "repeat" then
    run_cross_day_repeat(settings, now)
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

-- Command-line completion over configured source names (first argument only).
local function source_complete(arglead)
  local matches = {}
  for _, name in ipairs(sources_registry.names()) do
    if name:sub(1, #arglead) == arglead then
      table.insert(matches, name)
    end
  end
  return matches
end

-- Bring a work item from a configured source into the current worklog at the
-- current time. Offline-first: reads the source's local cache and opens
-- vim.ui.select (Telescope/fzf/snacks take over if installed). On pick the
-- configured "{id} {title}" template is inserted; cancelling falls back to a bare
-- timestamp, exactly like :WorklogInsert with no argument.
function M.insert_from_source(name)
  if guard_current_time("insert") then
    return
  end

  local source = sources_registry.get(name)
  if not source then
    warn("worklog: unknown source '" .. name .. "'")
    return
  end

  local sources = config.get().sources or {}
  local ttl = sources[name] and sources[name].ttl or 1800

  -- The picker is async, so capture the moment and the target buffer up front: a
  -- late selection then stamps the time the command was issued and never edits a
  -- buffer we have since moved away from.
  local time = os.date("%H:%M")
  local target_buf = vim.api.nvim_get_current_buf()

  -- Apply a chosen item into the originating buffer, guarding against the buffer
  -- changing under the async picker.
  local function insert_choice(item)
    if vim.api.nvim_get_current_buf() ~= target_buf then
      warn("worklog: buffer changed during selection; aborting insert")
      return
    end

    apply_insert_entry(time, source.to_entry_text(item))
  end

  local has_telescope = pcall(require, "telescope")

  sources_sync.ensure_fresh(name, ttl, function(items)
    -- With Telescope and a searchable source, type-as-you-search across the whole
    -- tracker (cached items show at an empty prompt). Otherwise the offline cache
    -- via vim.ui.select. Both insert through insert_choice; cancelling leaves a
    -- bare timestamp, like a plain :WorklogInsert.
    if has_telescope and source.search then
      require("worklog.telescope").live_pick(source, {
        initial_items = items,
        prompt = "Worklog: " .. name,
        on_pick = insert_choice,
        on_cancel = function()
          apply_insert_time(time)
        end,
      })
      return
    end

    vim.ui.select(items, {
      prompt = "Worklog: pick " .. name .. " item",
      format_item = function(item)
        return source.format_item(item)
      end,
    }, function(choice)
      if not choice then
        apply_insert_time(time)
        return
      end

      insert_choice(choice)
    end)
  end)
end

-- Refresh the on-disk cache for one source, or every configured source.
function M.sync_source(name)
  if name and name ~= "" then
    if not sources_registry.get(name) then
      warn("worklog: unknown source '" .. name .. "'")
      return
    end

    sources_sync.sync(name, { silent = false })
    return
  end

  local names = sources_registry.names()
  if #names == 0 then
    warn("worklog: no sources configured")
    return
  end

  for _, source_name in ipairs(names) do
    sources_sync.sync(source_name, { silent = false })
  end
end

-- Insert the current time at the cursor and enter insert mode.
function M.insert_now()
  if guard_current_time("insert") then
    return
  end

  apply_insert_time(os.date("%H:%M"))
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
  local result, err = order_worklogs.run(buffer_lines())
  if not result then
    warn(err)
    return
  end

  apply_result(result)

  if result.warnings and #result.warnings > 0 then
    warn(
      "worklog: ordering set the tag/location of order-dependent entries; review: "
        .. table.concat(result.warnings, ", ")
    )
  end
end

function M.log_current()
  run_buffer_usecase(log_current.run, cursor_row())
end

-- Rebuild every existing summary in the current buffer to match its entries.
function M.refresh()
  apply_refresh(false)
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

  -- Only opening today creates and stamps a file. Other offsets are navigation:
  -- open the day if it exists, otherwise an empty unmodified buffer (no file
  -- created).
  if offset ~= 0 then
    if refuse_when_today_has_errors(settings) then
      return
    end

    edit_journal_file(settings, target_date)
    return
  end

  local ok, was_initialized = open_journal_file(settings, target_date)
  if not ok then
    return
  end

  if not was_initialized then
    return
  end

  -- A freshly created today file gets the current time and a summary, so it tracks
  -- the day from the start (live when auto_summary is enabled). The summary refresh
  -- creates it the same way it would self-heal any other summary-less worklog.
  apply_insert_time(os.date("%H:%M", now))
  apply_refresh(false)
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

  if refuse_when_today_has_errors(settings) then
    return
  end

  local anchor = current_buffer_journal_date(settings) or os.time()
  edit_journal_file(settings, journal.offset_date(anchor, step))
end

-- Build the display lines for a report spec, reading each day through
-- journal_lines so open buffers (saved or not) are reflected. Returns the lines
-- and the period label, or nil and an error message.
local function build_report_lines(spec)
  local settings = expanded_journal_settings()
  if settings == nil then
    return nil, "worklog: journal.root is not configured"
  end

  local report, err
  if spec.kind == "week" then
    report, err = week.build_week_report(settings, spec.anchor, journal_lines)
  else
    report, err = week.build_days_report(settings, spec.anchor, spec.count, journal_lines)
  end

  if not report then
    return nil, err
  end

  local options = { aggregate_only = spec.aggregate_only }
  local duration_format = config.get().defaults.duration_format
  local render_report = spec.kind == "week" and render.week_report_lines or render.days_report_lines

  return render_report(report, duration_format, options), report.period_label
end

local function report_buffer_name(spec, label)
  local prefix
  if spec.kind == "week" then
    prefix = spec.aggregate_only and "worklog-week-summary-" or "worklog-week-"
  else
    prefix = spec.aggregate_only and "worklog-days-summary-" or "worklog-days-"
  end

  return prefix .. label .. ".wkl"
end

-- Open a fresh scratch report for a spec and tag the buffer with that spec, so
-- the auto-summary autocmds can rebuild it in place when a dependent journal
-- buffer changes. The anchor is pinned at open time, so the report keeps
-- covering the same period for as long as it stays open.
local function open_report(spec)
  local lines, label_or_err = build_report_lines(spec)
  if not lines then
    warn(label_or_err)
    return
  end

  open_report_buffer(lines, report_buffer_name(spec, label_or_err))
  vim.api.nvim_buf_set_var(0, "worklog_report", spec)
end

-- Rebuild every open report buffer from its stored spec, mirroring how the
-- in-file summaries refresh. A build failure (e.g. a dependent day is mid-edit
-- and invalid) leaves the last good report untouched rather than flicker, and
-- an unchanged report is left alone so the cursor never jumps needlessly.
local function refresh_report_windows()
  local refreshed = {}

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ok, spec = pcall(vim.api.nvim_buf_get_var, buf, "worklog_report")

    if ok and type(spec) == "table" and not refreshed[buf] then
      refreshed[buf] = true
      local lines = build_report_lines(spec)

      if lines and not vim.deep_equal(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
        local cursor = vim.api.nvim_win_get_cursor(win)
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modified = false
        vim.bo[buf].modifiable = false

        local line_count = vim.api.nvim_buf_line_count(buf)
        local row = math.min(cursor[1], line_count)
        local text = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
        vim.api.nvim_win_set_cursor(win, { row, math.min(cursor[2], #text) })
      end
    end
  end
end

function M.open_week(aggregate_only)
  open_report({ kind = "week", anchor = os.time(), aggregate_only = aggregate_only or false })
end

function M.open_days(count, aggregate_only)
  open_report({
    kind = "days",
    anchor = os.time(),
    count = count,
    aggregate_only = aggregate_only or false,
  })
end

-- Wire the autocmds that drive automatic summary refresh for the configured
-- mode. `off` installs nothing (manual :WorklogRefresh still works) but still
-- clears any autocmds a previous setup() left behind.
local function setup_auto_summary(mode)
  local group = vim.api.nvim_create_augroup("WorklogAutoSummary", { clear = true })
  if mode == "off" then
    return
  end

  local function on_worklog_buffer(opts, action)
    if vim.bo[opts.buf].filetype == "worklog" then
      action()
    end
  end

  local function refresh(opts)
    on_worklog_buffer(opts, function()
      apply_refresh(true)
      refresh_report_windows()
    end)
  end

  if mode == "save" then
    vim.api.nvim_create_autocmd("BufWritePre", { group = group, callback = refresh })
  elseif mode == "idle" then
    vim.api.nvim_create_autocmd(
      { "CursorHold", "CursorHoldI", "InsertLeave" },
      { group = group, callback = refresh }
    )
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
              refresh_report_windows()
            end
          end, 200)
        end)
      end,
    })
  end
end

-- Build and register the source objects declared in config, injecting the shell
-- transport, JSON codec, and a lazy token resolver. Clears first so repeated
-- setup() calls (and tests) start from a clean registry.
local function instantiate_sources()
  sources_registry.clear()

  local sources = config.get().sources
  if not sources then
    return
  end

  for name, source_config in pairs(sources) do
    local source, err = sources_registry.instantiate(name, source_config, {
      transport = sources_http,
      json = vim.json,
      token_resolver = function(source_cfg)
        local ok, token = pcall(source_cfg.token)
        if not ok then
          return nil, "worklog: source token() errored: " .. tostring(token)
        end
        if type(token) ~= "string" or token == "" then
          return nil, "worklog: source token() did not return a non-empty string"
        end
        return token
      end,
    })

    if source then
      sources_registry.register(name, source)
    else
      warn(err)
    end
  end
end

function M.setup(options)
  config.setup(options)
  filetype.register()
  instantiate_sources()

  ensure_user_command("WorklogInsert", function(args)
    local name = args.fargs[1]
    if not name then
      M.insert_now()
      return
    end

    M.insert_from_source(name)
  end, {
    nargs = "?",
    complete = function(arglead)
      return source_complete(arglead)
    end,
  })

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

  ensure_user_command("WorklogLog", function()
    M.log_current()
  end)

  ensure_user_command("WorklogRefresh", function()
    M.refresh()
  end)

  ensure_user_command("WorklogSync", function(args)
    M.sync_source(args.fargs[1])
  end, {
    nargs = "?",
    complete = function(arglead)
      return source_complete(arglead)
    end,
  })

  setup_auto_summary(config.get().auto_summary)
end

return M
