-- Day-navigation verbs: today, day, and relative browsing over the daybook (shell).

local buffer = require("daylog.buffer")
local current_time = require("daylog.current_time")
local daybook = require("daylog.daybook")
local daybook_io = require("daylog.daybook_io")
local refresh_summaries = require("daylog.usecases.refresh_summaries")

local M = {}

-- Today's log must be left in a valid state: leaving a broken today (out-of-order
-- entries, an invalid entry, ...) would silently stop tracking the active day, so the
-- day-navigation commands refuse until it is fixed. Only today is guarded -- browsing a
-- past day's old problems is fine -- and only the plugin's own navigation (a raw :edit
-- cannot be vetoed). The problems are published as buffer diagnostics so they show up.
local function refuse_when_today_has_errors(settings)
  local file_date = daybook_io.current_buffer_daybook_date(settings)
  if not file_date or not daybook.same_date(file_date, os.time()) then
    return false
  end

  local warnings = refresh_summaries.run(buffer.buffer_lines()).warnings
  if #warnings == 0 then
    return false
  end

  buffer.publish_diagnostics(warnings)
  buffer.warn("daylog: today's log has errors; fix them before leaving the day")
  return true
end

-- The shared navigation guard: every day verb needs the daybook configured and the current
-- buffer abandonable; `guard_today` additionally refuses to leave a broken today (today()
-- skips it, since it navigates to today). Runs `fn(settings)` once the guards pass.
local function navigate(guard_today, fn)
  local settings = daybook_io.expanded_daybook_settings()
  if settings == nil then
    buffer.warn("daylog: daybook.root is not configured")
    return
  end

  if not daybook_io.can_abandon_current_buffer() then
    buffer.warn("daylog: current buffer has unsaved changes")
    return
  end

  if guard_today and refuse_when_today_has_errors(settings) then
    return
  end

  fn(settings)
end

-- The day verbs build on the shared daybook_io shell helpers (open_daybook_file to create/open,
-- edit_daybook_file to navigate) plus the unified date grammar, which lets day() both backfill
-- a past day and pre-create a future one.

-- Open today's daybook file -- creating it scaffolded when new -- and stamp the current time
-- on a fresh day. The daily "start logging" ritual; bare :Daylog targets this.
function M.today()
  navigate(false, function(settings)
    local now = os.time()
    local ok, was_initialized = daybook_io.open_daybook_file(settings, daybook.offset_date(now, 0))
    if not ok or not was_initialized then
      return
    end

    current_time.apply_insert_time(os.date("%H:%M", now))
    buffer.apply_refresh(false)
  end)
end

-- Open the daybook day named by `when` -- a resolve_date token (today / yesterday / tomorrow /
-- a weekday / +N / -N / YYYY-MM-DD; default today) -- creating it scaffolded when new. Unlike
-- today() it never stamps the time, so it is how to backfill a past day or pre-create a future
-- one.
function M.day(when)
  navigate(true, function(settings)
    local date = daybook.resolve_date((when == nil or when == "") and "today" or when, os.time())
    if not date then
      buffer.warn(
        "daylog: unknown day '" .. tostring(when) .. "' -- try today, monday, -1, +2, 2026-05-10"
      )
      return
    end

    local ok, was_initialized = daybook_io.open_daybook_file(settings, date)
    if not ok or not was_initialized then
      return
    end

    buffer.apply_refresh(false)
  end)
end

-- Jump to the `|step|`-th existing log before (step < 0) or after (step > 0)
-- the current buffer's day, skipping days that have no log. The anchor falls
-- back to today when the buffer is not a canonical daybook file. Pure navigation:
-- it never inserts the current time, even when it lands on today, and it never
-- creates a file (use :Daylog day to start an arbitrary day). When no log
-- exists in that direction it warns and stays put.
function M.open_relative_day(step)
  navigate(true, function(settings)
    local anchor = daybook_io.current_buffer_daybook_date(settings) or os.time()
    local direction = step < 0 and -1 or 1
    local target = daybook.nearest_date(
      daybook_io.existing_daybook_dates(settings),
      anchor,
      direction,
      math.abs(step)
    )
    if not target then
      buffer.warn(direction < 0 and "daylog: no earlier log" or "daylog: no later log")
      return
    end

    daybook_io.edit_daybook_file(settings, target)
  end)
end

-- Browse to the n-th existing log after (next_day) / before (prev_day) the current day,
-- skipping days with no log; never creates or stamps. n defaults to 1.
function M.next_day(count)
  M.open_relative_day(count or 1)
end

function M.prev_day(count)
  M.open_relative_day(-(count or 1))
end

return M
