-- Machine-readable export of a report's summary into CSV or JSON (PURE). One row per
-- (day, activity, tag, location): quantized minutes, decimal hours, whether the slice is logged, and the
-- `!S` recipient names it was reported to; takes a report from week.build_dates_report (each day carries
-- `activity_rows`, the location-split projection).

local M = {}

local FIELDS = { "date", "activity", "tag", "location", "minutes", "hours", "logged", "logged_to" }

-- The `!S` recipients an activity row was reported to: its name-set minus the unnamed `""` sentinel (the
-- `logged` flag already conveys "reported"), in the canonical sorted order the names already carry. A
-- list, emitted comma-joined in CSV and as an array in JSON; empty for unlogged or logged-to-no-one.
local function recipients(names)
  local out = {}
  if names then
    for _, name in ipairs(names) do
      if name ~= "" then
        out[#out + 1] = name
      end
    end
  end
  return out
end

-- Decimal hours from whole minutes, locale-independently (`%f`'s decimal point could be a comma and corrupt CSV/JSON).
local function decimal_hours(minutes)
  return string.format(
    "%d.%02d",
    math.floor(minutes / 60),
    math.floor((minutes % 60) / 60 * 100 + 0.5)
  )
end

-- Flatten a report into export rows -- one per (day, activity, tag, location) slice. Uses each day's
-- `activity_rows` (the location-split, display-consistent projection), so an activity logged at two
-- locations becomes one row per location. Sorted deterministically so the export is stable/diffable.
local function rows(report)
  local out = {}
  for _, day in ipairs(report.days) do
    for _, item in ipairs(day.activity_rows) do
      out[#out + 1] = {
        date = day.date_label,
        activity = item.text,
        tag = item.tag or "",
        location = item.location or "",
        minutes = item.duration,
        hours = decimal_hours(item.duration),
        logged = item.logged == true,
        logged_to = recipients(item.names),
      }
    end
  end
  table.sort(out, function(a, b)
    if a.date ~= b.date then
      return a.date < b.date
    end
    if a.activity ~= b.activity then
      return a.activity < b.activity
    end
    if a.tag ~= b.tag then
      return a.tag < b.tag
    end
    if a.location ~= b.location then
      return a.location < b.location
    end
    if a.logged ~= b.logged then
      return not a.logged -- unlogged before logged
    end
    if a.minutes ~= b.minutes then
      return a.minutes > b.minutes
    end
    return table.concat(a.logged_to, ",") < table.concat(b.logged_to, ",")
  end)
  return out
end

-- A leading =, +, -, @ (or TAB/CR) makes a spreadsheet treat the cell as a formula; free-form activity
-- text can start with any of them (e.g. `-2h round`). Prefix a `'` to neutralize it (OWASP mitigation).
local FORMULA_PREFIX =
  { ["="] = true, ["+"] = true, ["-"] = true, ["@"] = true, ["\t"] = true, ["\r"] = true }

-- RFC 4180: quote a field that holds a comma, quote, CR or LF; double any internal quote. Formula
-- prefixes are neutralized first, so the guard survives the quoting.
local function csv_field(value)
  local s = tostring(value)
  if s ~= "" and FORMULA_PREFIX[s:sub(1, 1)] then
    s = "'" .. s
  end
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
      local value = row[field]
      -- A list field (logged_to) becomes one comma-joined cell -- csv_field then quotes it (RFC 4180).
      cells[i] = csv_field(type(value) == "table" and table.concat(value, ",") or value)
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

local function json_array(list)
  local items = {}
  for i, value in ipairs(list) do
    items[i] = json_string(value)
  end
  return "[" .. table.concat(items, ", ") .. "]"
end

-- A field's JSON literal: minutes/hours as bare numbers, the flags as booleans, logged_to as an array of
-- strings, the rest as strings.
local function json_value(field, value)
  if field == "minutes" then
    return tostring(value)
  elseif field == "hours" then
    return value -- already a locale-safe "N.NN" string -> a JSON number
  elseif field == "logged" then
    return value and "true" or "false"
  elseif field == "logged_to" then
    return json_array(value)
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
