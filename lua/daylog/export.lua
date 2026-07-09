-- Machine-readable export of a report's generated summary block into CSV or JSON (PURE). One row per
-- summary-block row, tagged by a `level` column (activity / tag / location / workday): the quantized
-- minutes + hours, the residual (real elapsed minutes and the `(±Nm)` rounding delta), whether the slice
-- is logged, and the recipient names it was reported to. Takes a report from week.build_dates_report
-- (each day carries `activity_rows`, the location-split projection, plus `summary` totals sections).

local M = {}

local FIELDS = {
  "date",
  "level",
  "activity",
  "tag",
  "location",
  "minutes",
  "hours",
  "unrounded_minutes",
  "error_minutes",
  "logged",
  "logged_to",
}

-- Sort order for the level discriminator.
local LEVEL_RANK = { activity = 1, tag = 2, location = 3, workday = 4 }

-- The recipients a row was reported to: its name-set minus the unnamed `""` sentinel (the `logged` flag
-- already conveys "reported"), in the canonical sorted order the names already carry. A list, emitted
-- comma-joined in CSV and as an array in JSON; empty for unlogged or logged-to-no-one.
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

-- One export row for a summary-block `item` at `level`; `keys` fills the activity/tag/location columns
-- the level applies to (the rest stay empty).
local function row_of(date, level, keys, item)
  return {
    date = date,
    level = level,
    activity = keys.activity or "",
    tag = keys.tag or "",
    location = keys.location or "",
    minutes = item.duration,
    hours = decimal_hours(item.duration),
    unrounded_minutes = item.unrounded_duration or item.duration,
    error_minutes = item.error_minutes or 0,
    logged = item.logged == true,
    logged_to = recipients(item.names),
  }
end

-- Flatten a report into export rows: for each day, the four summary-block sections in turn -- activity
-- (location-split), tag, location, and workday totals -- each carrying its own level's logged state and
-- minutes. Sorted deterministically so the export is stable/diffable.
local function rows(report)
  local out = {}
  for _, day in ipairs(report.days) do
    local date = day.date_label
    for _, item in ipairs(day.activity_rows or {}) do
      out[#out + 1] = row_of(
        date,
        "activity",
        { activity = item.text, tag = item.tag, location = item.location },
        item
      )
    end
    local summary = day.summary or {}
    for _, item in ipairs(summary.tag_totals or {}) do
      out[#out + 1] = row_of(date, "tag", { tag = item.tag }, item)
    end
    for _, item in ipairs(summary.location_totals or {}) do
      out[#out + 1] = row_of(date, "location", { location = item.location }, item)
    end
    for _, item in ipairs(summary.total_rows or {}) do
      out[#out + 1] = row_of(date, "workday", {}, item)
    end
  end
  table.sort(out, function(a, b)
    if a.date ~= b.date then
      return a.date < b.date
    end
    if a.level ~= b.level then
      return LEVEL_RANK[a.level] < LEVEL_RANK[b.level]
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
-- prefixes are neutralized first, so the guard survives the quoting. Applied only to text/list cells --
-- numbers (incl. a negative error_minutes) bypass it so `-10` is not rewritten to `'-10`.
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

-- The number of data rows the export emits (all levels), for the "exported N rows" notice.
function M.row_count(report)
  return #rows(report)
end

function M.csv(report)
  local lines = { table.concat(FIELDS, ",") }
  for _, row in ipairs(rows(report)) do
    local cells = {}
    for i, field in ipairs(FIELDS) do
      local value = row[field]
      local kind = type(value)
      if kind == "number" or kind == "boolean" then
        cells[i] = tostring(value) -- numeric/flag cells skip the formula guard (keeps a signed number)
      elseif kind == "table" then
        cells[i] = csv_field(table.concat(value, ",")) -- logged_to: one comma-joined, then quoted
      else
        cells[i] = csv_field(value)
      end
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

-- A field's JSON literal: the minute counts as bare numbers, hours as a bare number, the flag as a
-- boolean, logged_to as an array of strings, the rest as strings.
local function json_value(field, value)
  if field == "minutes" or field == "unrounded_minutes" or field == "error_minutes" then
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
