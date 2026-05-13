local M = {}

local WORKLOG_HEADER = "--- worklog ---"

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

local function parse_header(line, row)
  local default_label = line:match("^%-%-%- worklog default=#([%w_%-]+) %-%-%-$")
  if default_label then
    return {
      kind = "worklog_header",
      row = row,
      raw = line,
      default_label = default_label,
    }
  end

  if line == WORKLOG_HEADER then
    return {
      kind = "worklog_header",
      row = row,
      raw = line,
      default_label = nil,
    }
  end

  local text = line:match("^%-%-%- (.+) %-%-%-$")
  if text then
    return {
      kind = "block_header",
      row = row,
      raw = line,
      text = text,
    }
  end

  return nil
end

local function parse_entry(line, row)
  local hh, mm, rest = line:match("^(%d%d):(%d%d)(.*)$")
  if not hh then
    return nil
  end

  if rest ~= "" and not rest:match("^%s") then
    return {
      kind = "invalid_entry",
      row = row,
      raw = line,
      message = "expected whitespace after the time",
    }
  end

  hh = tonumber(hh)
  mm = tonumber(mm)

  if hh > 23 or mm > 59 then
    return {
      kind = "invalid_entry",
      row = row,
      raw = line,
      message = "invalid time",
    }
  end

  local text = normalize_text(rest:gsub("^%s+", ""))
  local explicit_label, err

  text, explicit_label, err = parse_trailing_label(text)
  if err then
    return {
      kind = "invalid_entry",
      row = row,
      raw = line,
      message = err,
    }
  end

  return {
    kind = "entry",
    row = row,
    raw = line,
    minutes = hh * 60 + mm,
    text = text,
    explicit_label = explicit_label,
    excluded = explicit_label == "ooo",
  }
end

local function parse_line(line, row)
  local header = parse_header(line, row)
  if header then
    return header
  end

  local entry = parse_entry(line, row)
  if entry then
    return entry
  end

  if line == "" then
    return {
      kind = "blank_line",
      row = row,
      raw = line,
    }
  end

  return {
    kind = "note_line",
    row = row,
    raw = line,
    text = line,
  }
end

-- Parse a worklog file into syntax-preserving line nodes.
-- The returned document keeps every input line as an explicit node so later
-- semantic analysis can preserve source layout while deriving worklog meaning.
function M.parse(lines)
  local nodes = {}

  for row, line in ipairs(lines) do
    table.insert(nodes, parse_line(line, row))
  end

  return {
    kind = "document",
    row_count = #lines,
    nodes = nodes,
  }
end

return M
