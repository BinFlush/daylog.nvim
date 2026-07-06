local buffer = require("daylog.buffer")
local carryover = require("daylog.usecases.carryover")
local insert_entry = require("daylog.usecases.insert_entry")
local insert_now = require("daylog.usecases.insert_now")
local daybook = require("daylog.daybook")
local daybook_io = require("daylog.daybook_io")
local text = require("daylog.text")

local M = {}

-- Current-time stamping + cross-day carryover (shell).
--
-- The guard that refuses to stamp the current time into a non-today day, and the two ways it can
-- take over instead: rolling a task across midnight into a fresh today (carryover), and bringing
-- a browsed day's activity into today (cross-day repeat). Plus the apply_insert_* stampers.

local warn = buffer.warn
local buffer_lines = buffer.buffer_lines
local cursor_row = buffer.cursor_row
local apply_result = buffer.apply_result
local apply_refresh = buffer.apply_refresh
local run_buffer_usecase = buffer.run_buffer_usecase
local can_abandon_current_buffer = daybook_io.can_abandon_current_buffer
local current_buffer_daybook_date = daybook_io.current_buffer_daybook_date
local expanded_daybook_settings = daybook_io.expanded_daybook_settings
local daybook_lines = daybook_io.daybook_lines
local daybook_path_has_content = daybook_io.daybook_path_has_content
local open_daybook_file = daybook_io.open_daybook_file
local live_offset = daybook_io.live_offset

local function apply_insert_time(time, auto_offset)
  return run_buffer_usecase(insert_now.run, cursor_row(), time, auto_offset)
end

-- Insert a fully-resolved "HH:MM <text>" entry at the cursor's log (text already sanitized by the
-- source layer). Mirrors apply_insert_time but carries an activity string.
local function apply_insert_entry(time, entry_text, auto_offset)
  return run_buffer_usecase(insert_entry.run, cursor_row(), time, entry_text, auto_offset)
end

-- Roll a task that ran across midnight into today: close the previous day at 24:00, open/create
-- today, continue from 00:00, then apply the originating command. Returns true when it took over
-- the request, false when this is not a carryover situation (guard_current_time falls back).
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

  -- A today that already holds content has no room for a fresh 00:00 carry-over. :Daylog repeat
  -- declines (return false) so guard falls through to the normal cross-day repeat; :Daylog insert
  -- points the user at :Daylog today.
  local today_path = daybook.path_for_date(settings, now)
  if daybook_path_has_content(today_path) then
    if command == "repeat" then
      return false
    end

    warn("daylog: today's log already exists; open it with :Daylog today")
    return true
  end

  local prompt = string.format("Past midnight: carry '%s' over to today's log?", carried.text)
  if vim.fn.confirm(prompt, "&Yes\n&No", 1) ~= 1 then
    return true
  end

  local close, close_err = carryover.close_edit(lines)
  if not close then
    warn(close_err)
    return true
  end
  apply_result(close)

  -- Refresh the previous day's summary so the 24:00 close reaches disk (apply_result only
  -- republishes diagnostics; it does not recompute summaries).
  apply_refresh(false)

  if not pcall(vim.cmd, "silent write") then
    warn("daylog: failed to save the previous day before carrying over")
    return true
  end

  if not open_daybook_file(settings, now) then
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

-- Bring the cursor activity into today's log at the current time (:Daylog repeat on another day's
-- file). The browsed day is left untouched; today is opened and the window switches to it.
local function run_cross_day_repeat(settings, now)
  -- Capture the activity before open_daybook_file switches the buffer away.
  local activity, err = carryover.entry_at_row(buffer_lines(), cursor_row())
  if not activity then
    warn(err)
    return
  end

  -- Refuse cleanly when the browsed buffer can't be abandoned (unsaved with 'hidden' off) rather
  -- than surfacing a raw E37. Unlike carryover, the browsed day is not saved on the user's behalf.
  if not can_abandon_current_buffer() then
    warn("daylog: current buffer has unsaved changes")
    return
  end

  local clock = os.date("*t", now)
  local minutes = clock.hour * 60 + clock.min

  -- If today already holds a log, validate the insert before switching, so a broken today is
  -- reported while staying on the browsed day. A missing/empty today is initialized fresh.
  local today_lines = daybook_lines(daybook.path_for_date(settings, now))
  if today_lines and not text.is_empty(today_lines) then
    local ok, validate_err = carryover.seed_edit(today_lines, activity, minutes)
    if not ok then
      warn(validate_err)
      return
    end
  end

  if not open_daybook_file(settings, now) then
    return
  end

  -- Repeating into an existing today is the one path where the live zone may have drifted since
  -- the day was opened, so it passes live_offset() to track it.
  local seed, seed_err = carryover.seed_edit(buffer_lines(), activity, minutes, live_offset())
  if not seed then
    warn(seed_err)
    return
  end

  apply_result(seed)
  apply_refresh(false)
end

-- Refuse to stamp the current time into a non-today day; stays silent on non-daybook files so the
-- plugin still works on arbitrary files. Returns true when the request was handled and the caller
-- should stop.
local function guard_current_time(command)
  local settings = expanded_daybook_settings()
  if settings == nil then
    return false
  end

  local file_date = current_buffer_daybook_date(settings)
  if file_date == nil then
    return false
  end

  local now = os.time()
  if daybook.same_date(file_date, now) then
    return false
  end

  if
    daybook.same_date(file_date, daybook.offset_date(now, -1))
    and run_carryover(settings, command, now)
  then
    return true
  end

  -- :Daylog repeat on any other day brings the cursor activity into today; :Daylog insert refuses.
  if command == "repeat" then
    run_cross_day_repeat(settings, now)
    return true
  end

  warn(
    string.format(
      "daylog: this file is dated %s, not today (%s); refusing to insert the current time",
      daybook.date_label(file_date),
      daybook.date_label(now)
    )
  )
  return true
end

M.apply_insert_time = apply_insert_time
M.apply_insert_entry = apply_insert_entry
M.guard_current_time = guard_current_time

return M
