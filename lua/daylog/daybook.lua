local M = {}

local function midday_date(timestamp)
  local date = os.date("*t", timestamp)
  date.hour = 12
  date.min = 0
  date.sec = 0
  return date
end

-- A timestamp at midday on the given calendar date. Anchoring at 12:00 keeps day arithmetic clear
-- of DST edges, and os.time normalizes out-of-range days (day 32 -> next month).
local function midday_time(year, month, day)
  return os.time({ year = year, month = month, day = day, hour = 12, min = 0, sec = 0 })
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

function M.directory_path(daybook, now)
  local path = trim_trailing_slashes(daybook.root)
  local directory = trim_directory_slashes(os.date(daybook.directory, now))

  if directory == "" then
    return path
  end

  return path .. "/" .. directory
end

function M.filename(now)
  return M.date_label(now) .. ".day"
end

function M.date_label(now)
  return os.date("%Y-%m-%d", now)
end

function M.same_date(a, b)
  return M.date_label(a) == M.date_label(b)
end

-- Parse a `YYYY-MM-DD` date string into a midday timestamp, or nil when it is not a
-- valid calendar date. The round-trip label check rejects out-of-range dates such as
-- 2026-02-30 (os.time would otherwise normalize them silently into the next month).
function M.parse_date(value)
  if type(value) ~= "string" then
    return nil
  end

  local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not year then
    return nil
  end

  local timestamp = midday_time(tonumber(year), tonumber(month), tonumber(day))

  if M.date_label(timestamp) ~= year .. "-" .. month .. "-" .. day then
    return nil
  end

  return timestamp
end

-- Parse a daybook filename (`YYYY-MM-DD.day`) into a midday timestamp, or nil when the
-- name is not a valid dated daybook filename.
function M.parse_date_label(name)
  local date = name:match("^(.+)%.day$")
  if not date then
    return nil
  end

  return M.parse_date(date)
end

function M.date_range_label(first, last)
  return M.date_label(first) .. ".." .. M.date_label(last)
end

function M.path_for_date(daybook, now)
  return M.directory_path(daybook, now) .. "/" .. M.filename(now)
end

local function forward_slashes(value)
  return (value:gsub("\\", "/"))
end

-- Resolve the daybook date a path represents, or nil when it is not a canonical daybook file
-- (equal to the path the config would generate, so the `directory` template is honored). Both `/`
-- and `\` separators are accepted so Windows buffer paths resolve.
function M.date_from_path(daybook, path)
  local basename = path:match("[^/\\]+$") or path
  local timestamp = M.parse_date_label(basename)
  if not timestamp then
    return nil
  end

  if forward_slashes(M.path_for_date(daybook, timestamp)) ~= forward_slashes(path) then
    return nil
  end

  return timestamp
end

function M.offset_date(now, offset_days)
  local anchor = midday_date(now)
  local offset = offset_days or 0

  return midday_time(anchor.year, anchor.month, anchor.day + offset)
end

-- Named-date tokens for range bounds. A weekday resolves to its most recent occurrence on or
-- before today (`friday` on a Friday is today). Case-insensitive, full names and 3-letter abbrevs.
local WEEKDAYS = {
  monday = 1,
  mon = 1,
  tuesday = 2,
  tue = 2,
  wednesday = 3,
  wed = 3,
  thursday = 4,
  thu = 4,
  friday = 5,
  fri = 5,
  saturday = 6,
  sat = 6,
  sunday = 7,
  sun = 7,
}

-- Resolve a date token to a midday timestamp, or nil unless it is a known name, a SIGNED offset
-- (`+N`/`-N`), or a `YYYY-MM-DD` literal. A bare number is deliberately NOT an offset -- it is a
-- day count in the report grammar -- so the vocabulary stays unambiguous.
function M.resolve_date(token, now)
  if type(token) ~= "string" then
    return nil
  end

  local key = token:lower()
  if key == "today" then
    return M.offset_date(now, 0)
  elseif key == "yesterday" then
    return M.offset_date(now, -1)
  elseif key == "tomorrow" then
    return M.offset_date(now, 1)
  end

  local weekday = WEEKDAYS[key]
  if weekday then
    return M.offset_date(now, -((iso_weekday(now) - weekday) % 7))
  end

  if token:match("^[+-]%d+$") then
    return M.offset_date(now, tonumber(token))
  end

  return M.parse_date(token)
end

function M.trailing_dates(now, count)
  local anchor = midday_date(now)
  local dates = {}

  for offset = count - 1, 0, -1 do
    table.insert(dates, midday_time(anchor.year, anchor.month, anchor.day - offset))
  end

  return dates
end

-- Parse a report range: a bare count ("7") -> { count = N }, or "FROM..TO" -> { from, to } (either
-- side may be empty). A bare number is a count here, never an offset (resolve_date owns signed
-- offsets), so the two never overlap.
function M.parse_report_range(value)
  if type(value) ~= "string" then
    return nil
  end

  if value:match("^%d+$") then
    local count = tonumber(value)
    return count >= 1 and { count = count } or nil
  end

  local from, to = value:match("^(.-)%.%.(.-)$")
  if not from then
    return nil
  end

  return { from = from ~= "" and from or nil, to = to ~= "" and to or nil }
end

-- The inclusive list of midday timestamps from `from_ts` to `to_ts`, one per calendar
-- day. Empty when `from_ts` is after `to_ts`. Compares by date label (chronological as
-- strings) so an off-midday endpoint still bounds the range by its calendar day.
function M.range_dates(from_ts, to_ts)
  local anchor = midday_date(from_ts)
  local to_label = M.date_label(to_ts)
  local dates = {}
  local offset = 0

  while true do
    local stamp = midday_time(anchor.year, anchor.month, anchor.day + offset)
    if M.date_label(stamp) > to_label then
      break
    end

    table.insert(dates, stamp)
    offset = offset + 1
  end

  return dates
end

-- The `count`-th existing daybook date strictly past `anchor` in `direction` (+1 later, -1
-- earlier), or nil when fewer exist. Dates are de-duplicated by `date_label` (so a day present
-- twice counts once) and sort lexically, which for `YYYY-MM-DD` is chronological.
function M.nearest_date(dates, anchor, direction, count)
  count = count or 1
  local anchor_label = M.date_label(anchor)
  local by_label = {}
  local labels = {}

  for _, date in ipairs(dates) do
    local label = M.date_label(date)
    if by_label[label] == nil then
      by_label[label] = date
      table.insert(labels, label)
    end
  end

  table.sort(labels, function(a, b)
    -- Order so the closest candidate in `direction` is visited first.
    if direction < 0 then
      return a > b
    end
    return a < b
  end)

  local found = 0
  for _, label in ipairs(labels) do
    local past
    if direction < 0 then
      past = label < anchor_label
    else
      past = label > anchor_label
    end

    if past then
      found = found + 1
      if found == count then
        return by_label[label]
      end
    end
  end

  return nil
end

return M
