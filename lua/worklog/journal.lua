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

function M.same_date(a, b)
  return M.date_label(a) == M.date_label(b)
end

-- Parse a journal filename (`YYYY-MM-DD.wkl`) into a midday timestamp.
-- Returns nil when the name is not a valid dated journal filename. The
-- round-trip label check rejects out-of-range dates such as 2026-02-30.
function M.parse_date_label(name)
  local year, month, day = name:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%.wkl$")
  if not year then
    return nil
  end

  local timestamp = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = 12,
    min = 0,
    sec = 0,
  })

  if M.date_label(timestamp) ~= year .. "-" .. month .. "-" .. day then
    return nil
  end

  return timestamp
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

local function forward_slashes(value)
  return (value:gsub("\\", "/"))
end

-- Resolve the journal date a path represents, or nil when the path is not a
-- canonical journal file. The path is canonical only when it equals the path
-- the configuration would generate for the date in its filename, so the
-- `directory` template is honored and dated files outside the tree are ignored.
-- Both `/` and `\` separators are accepted so Windows buffer paths resolve too.
function M.date_from_path(journal, path)
  local basename = path:match("[^/\\]+$") or path
  local timestamp = M.parse_date_label(basename)
  if not timestamp then
    return nil
  end

  if forward_slashes(M.path_for_date(journal, timestamp)) ~= forward_slashes(path) then
    return nil
  end

  return timestamp
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
