local M = {}

local MISSING_LABEL_MESSAGE = "missing label; add a trailing #label or declare a default label in the first worklog header"

-- Clean and normalize the text part of a worklog entry.
-- - collapses whitespace
-- - trims leading/trailing spaces
local function normalize_text(text)
  text = text:gsub("%s+", " ")
  text = text:gsub("^%s+", "")
  text = text:gsub("%s+$", "")
  return text
end

local function ends_with_label(text)
  return text:match("^#([%w_%-]+)$") ~= nil or text:match("%s+#([%w_%-]+)$") ~= nil
end

local function parse_trailing_label(text)
  local prefix, label = text:match("^(.-)%s+#([%w_%-]+)$")

  if not label then
    label = text:match("^#([%w_%-]+)$")
    if label then
      return "", label
    end

    return text, nil
  end

  prefix = normalize_text(prefix)

  if ends_with_label(prefix) then
    return nil, nil, "multiple trailing labels are not allowed"
  end

  return prefix, label
end

function M.minutes_string(minutes)
  return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

function M.format_time_line(entry, default_label)
  local parts = { M.minutes_string(entry.minutes) }

  if entry.text ~= "" then
    table.insert(parts, entry.text)
  end

  if entry.label == "ooo" then
    table.insert(parts, "#ooo")
  elseif entry.label and entry.label ~= default_label then
    table.insert(parts, "#" .. entry.label)
  end

  return table.concat(parts, " ")
end

-- Parse a single worklog line into structured data.
-- Exactly one trailing `#label` is allowed. If no explicit label is present,
-- the file's default label applies. `#ooo` is exclusive and does not inherit
-- the default label.
function M.parse_time_line(line, default_label)
  local hh, mm, rest = line:match("^(%d%d):(%d%d)(.*)$")
  if not hh then
    return nil
  end

  if rest ~= "" and not rest:match("^%s") then
    return false, "expected whitespace after the time"
  end

  hh = tonumber(hh)
  mm = tonumber(mm)

  if hh > 23 or mm > 59 then
    return false, "invalid time"
  end

  local minutes = hh * 60 + mm
  local text = normalize_text(rest:gsub("^%s+", ""))
  local label, err

  text, label, err = parse_trailing_label(text)
  if err then
    return false, err
  end

  label = label or default_label

  return {
    minutes = minutes,
    text = text,
    label = label,
    excluded = label == "ooo",
  }
end

-- Parse all semantic worklog lines from a list of lines.
-- -- Returns a list of entries in chronological order:
-- {
--   { minutes = number, text = string, label = string|nil, excluded = boolean },
--   ...
-- }
function M.parse_lines(lines, default_label)
  local entries = {}
  local entry_rows = {}

  for i, line in ipairs(lines) do
    local entry, err = M.parse_time_line(line, default_label)

    if entry == false then
      return nil, {
        row = i,
        message = err,
      }
    end

    if entry then
      table.insert(entries, entry)
      table.insert(entry_rows, i)
    end
  end

  for i = 1, #entries - 1 do
    if entries[i].label == nil then
      return nil, {
        row = entry_rows[i],
        message = MISSING_LABEL_MESSAGE,
      }
    end
  end

  return entries
end

function M.missing_label_message()
  return MISSING_LABEL_MESSAGE
end

return M
