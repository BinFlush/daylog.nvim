local M = {}

local function midday_date(timestamp)
  local date = os.date("*t", timestamp)
  date.hour = 12
  date.min = 0
  date.sec = 0
  return date
end

local function iso_weekday(timestamp)
  return ((os.date("*t", timestamp).wday + 5) % 7) + 1
end

local function trim_trailing_slashes(value)
  return value:gsub("/+$", "")
end

local function trim_directory_slashes(value)
  local trimmed = trim_trailing_slashes(value)
  return trimmed:gsub("^/+", "")
end

function M.directory_path(journal, now)
  local path = trim_trailing_slashes(journal.root)
  local directory = trim_directory_slashes(os.date(journal.directory, now))

  if directory == "" then
    return path
  end

  return path .. "/" .. directory
end

function M.filename(now)
  return M.date_label(now) .. ".wkl"
end

function M.date_label(now)
  return os.date("%Y-%m-%d", now)
end

function M.week_label(now)
  return os.date("%G-W%V", now)
end

function M.date_range_label(first, last)
  return M.date_label(first) .. ".." .. M.date_label(last)
end

function M.path_for_date(journal, now)
  return M.directory_path(journal, now) .. "/" .. M.filename(now)
end

function M.today_path(journal, now)
  return M.path_for_date(journal, now)
end

function M.offset_date(now, offset_days)
  local anchor = midday_date(now)
  local offset = offset_days or 0

  return os.time({
    year = anchor.year,
    month = anchor.month,
    day = anchor.day + offset,
    hour = 12,
    min = 0,
    sec = 0,
  })
end

function M.iso_week_dates(now)
  local anchor = midday_date(now)
  local monday = {
    year = anchor.year,
    month = anchor.month,
    day = anchor.day - (iso_weekday(now) - 1),
    hour = 12,
    min = 0,
    sec = 0,
  }
  local dates = {}

  for offset = 0, 6 do
    table.insert(
      dates,
      os.time({
        year = monday.year,
        month = monday.month,
        day = monday.day + offset,
        hour = 12,
        min = 0,
        sec = 0,
      })
    )
  end

  return dates
end

function M.trailing_dates(now, count)
  local anchor = midday_date(now)
  local dates = {}

  for offset = count - 1, 0, -1 do
    table.insert(
      dates,
      os.time({
        year = anchor.year,
        month = anchor.month,
        day = anchor.day - offset,
        hour = 12,
        min = 0,
        sec = 0,
      })
    )
  end

  return dates
end

return M
