-- Machine-readable export of a report's summary into CSV or JSON (PURE). One row per
-- (day, activity, tag): quantized minutes, decimal hours, and the logged flag; takes a report
-- from week.build_dates_report.

local M = {}

local FIELDS = { "date", "activity", "tag", "minutes", "hours", "logged" }

-- Decimal hours from whole minutes, locale-independently (`%f`'s decimal point could be a comma and corrupt CSV/JSON).
local function decimal_hours(minutes)
  return string.format(
    "%d.%02d",
    math.floor(minutes / 60),
    math.floor((minutes % 60) / 60 * 100 + 0.5)
  )
end

-- Flatten a report into export rows -- one per summary item per day, tagged with that day's date.
local function rows(report)
  local out = {}
  for _, day in ipairs(report.days) do
    for _, item in ipairs(day.summary.summary_items) do
      out[#out + 1] = {
        date = day.date_label,
        activity = item.text,
        tag = item.tag or "",
        minutes = item.duration,
        hours = decimal_hours(item.duration),
        logged = item.logged == true,
      }
    end
  end
  return out
end

-- RFC 4180: quote a field that holds a comma, quote, CR or LF; double any internal quote.
local function csv_field(value)
  local s = tostring(value)
  if s:find('[",\r\n]') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

function M.csv(report)
  local lines = { table.concat(FIELDS, ",") }
  for _, row in ipairs(rows(report)) do
    local cells = {}
    for i, field in ipairs(FIELDS) do
      cells[i] = csv_field(row[field])
    end
    lines[#lines + 1] = table.concat(cells, ",")
  end
  return table.concat(lines, "\n") .. "\n"
end

local JSON_ESCAPES =
  { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function json_string(s)
  return '"'
    .. (s:gsub('[\\"%z\1-\31]', function(c)
      return JSON_ESCAPES[c] or string.format("\\u%04x", string.byte(c))
    end))
    .. '"'
end

-- A field's JSON literal: minutes/hours as bare numbers, the flags as booleans, the rest as strings.
local function json_value(field, value)
  if field == "minutes" then
    return tostring(value)
  elseif field == "hours" then
    return value -- already a locale-safe "N.NN" string -> a JSON number
  elseif field == "logged" then
    return value and "true" or "false"
  end
  return json_string(tostring(value))
end

function M.json(report)
  local items = {}
  for _, row in ipairs(rows(report)) do
    local fields = {}
    for _, field in ipairs(FIELDS) do
      fields[#fields + 1] = json_string(field) .. ": " .. json_value(field, row[field])
    end
    items[#items + 1] = "  { " .. table.concat(fields, ", ") .. " }"
  end
  if #items == 0 then
    return "[]\n"
  end
  return "[\n" .. table.concat(items, ",\n") .. "\n]\n"
end

return M
