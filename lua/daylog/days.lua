-- Day-navigation verbs: today, day, and relative browsing over the daybook (shell).

local buffer = require("daylog.buffer")
local current_time = require("daylog.current_time")
local daybook = require("daylog.daybook")
local daybook_io = require("daylog.daybook_io")
local refresh_summaries = require("daylog.usecases.refresh_summaries")

local M = {}

-- A broken today (out-of-order/invalid entries) would silently stop tracking the active day,
-- so navigation refuses until fixed; only today is guarded, and only the plugin's own
-- navigation (a raw :edit can't be vetoed). Problems publish as buffer diagnostics.
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

-- Shared navigation guard: needs the daybook configured and the buffer abandonable;
-- guard_today additionally refuses to leave a broken today. Runs fn(settings) once guards pass.
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

-- The day verbs build on the daybook_io shell helpers plus the unified date grammar.

-- Open today's daybook file (scaffolding a new one) and stamp the current time on a fresh
-- day; bare :Daylog targets this.
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

-- Open the daybook day named by `when` (a resolve_date token; default today), scaffolding a
-- new one; unlike today() it never stamps the time, so it backfills a past or pre-creates a future day.
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

-- Jump to the |step|-th existing log before (step<0) or after (step>0) the current day,
-- skipping logless days; the anchor falls back to today off a non-daybook buffer. Never
-- stamps or creates a file; warns and stays put when none exists in that direction.
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

-- Browse to the n-th existing log after/before the current day, skipping logless days;
-- never creates or stamps (n defaults to 1).
function M.next_day(count)
  M.open_relative_day(count or 1)
end

function M.prev_day(count)
  M.open_relative_day(-(count or 1))
end

return M
