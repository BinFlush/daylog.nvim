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
-- The guard that refuses to stamp the current time into a day that is not today,
-- and the two ways it can instead take over: rolling a task across midnight into a
-- fresh today (carryover), and bringing a browsed day's activity into today
-- (cross-day repeat). Also the apply_insert_* stampers the verbs share. This is the
-- subtlest temporal logic in the shell, kept in one place.

local warn = buffer.warn
local buffer_lines = buffer.buffer_lines
local cursor_row = buffer.cursor_row
local apply_result = buffer.apply_result
local apply_refresh = buffer.apply_refresh
local can_abandon_current_buffer = daybook_io.can_abandon_current_buffer
local current_buffer_daybook_date = daybook_io.current_buffer_daybook_date
local expanded_daybook_settings = daybook_io.expanded_daybook_settings
local daybook_lines = daybook_io.daybook_lines
local daybook_path_has_content = daybook_io.daybook_path_has_content
local open_daybook_file = daybook_io.open_daybook_file

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

-- Insert a fully-resolved "HH:MM <text>" entry at the cursor's log and enter
-- insert mode. Mirrors apply_insert_time but carries an activity string (the text
-- is built and sanitized by the source layer before it gets here).
local function apply_insert_entry(time, entry_text)
  local result, err = insert_entry.run(buffer_lines(), cursor_row(), time, entry_text)
  if not result then
    warn(err)
    return false
  end

  apply_result(result)
  return true
end

-- Roll a task that ran across midnight into today: close the previous day at
-- 24:00, open/create today, continue the activity from 00:00, then apply the
-- originating command at the current time. Returns true when it took over the
-- request (carried over, declined, or intentionally refused), false when this is
-- not a carryover situation -- leaving guard_current_time to fall back to the
-- cross-day repeat (:DaylogRepeat) or to hard-block (:DaylogInsert).
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

  -- A today that already holds content has no room for a fresh 00:00 carry-over.
  -- For :DaylogRepeat, decline (return false) so guard_current_time falls through
  -- to the normal cross-day repeat, inserting the cursor activity into the existing
  -- today -- exactly as repeating from any other day does. There is nothing to
  -- carry for :DaylogInsert, so it still points the user at :DaylogToday.
  local today_path = daybook.path_for_date(settings, now)
  if daybook_path_has_content(today_path) then
    if command == "repeat" then
      return false
    end

    warn("daylog: today's log already exists; open it with :DaylogToday")
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

  -- Refresh the previous day's summary so the carried-over 24:00 close is
  -- reflected on disk regardless of the auto_summary mode (apply_result only
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

-- Bring the activity under the cursor into today's log at the current time,
-- used when :DaylogRepeat runs on another day's file. The browsed day is left
-- untouched; today is opened (created if needed) and the window switches to it.
local function run_cross_day_repeat(settings, now)
  -- Capture the activity before open_daybook_file switches the buffer away.
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
    warn("daylog: current buffer has unsaved changes")
    return
  end

  local clock = os.date("*t", now)
  local minutes = clock.hour * 60 + clock.min

  -- If today already holds a log, confirm the activity can be inserted there before
  -- switching to it, so a broken today is reported while staying on the browsed day
  -- rather than yanking the window across and only then failing. A missing/empty (or
  -- whitespace-only) today is initialized fresh by open_daybook_file and always seeds.
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

  local seed, seed_err = carryover.seed_edit(buffer_lines(), activity, minutes)
  if not seed then
    warn(seed_err)
    return
  end

  apply_result(seed)
  apply_refresh(false)
end

-- Refuse to stamp the current time into a day that is not today. When the
-- buffer is not a canonical daybook file the guard stays silent so the plugin
-- keeps working on arbitrary files. Returns true when the request was handled
-- (blocked, carried over, or repeated into today) and the caller should stop.
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

  -- :DaylogRepeat on any other day brings the cursor activity into today instead
  -- of refusing; :DaylogInsert still refuses (there is no activity to carry).
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
