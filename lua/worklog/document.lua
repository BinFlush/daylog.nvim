local M = {}

-- Syntax-preserving document parser.
--
-- Every source line becomes an explicit node so higher layers can derive
-- worklog meaning without losing original layout, raw text, or source rows.

local function normalize_text(text)
  text = text:gsub("%s+", " ")
  text = text:gsub("^%s+", "")
  text = text:gsub("%s+$", "")
  return text
end

local function parse_metadata_token(token)
  if token == "#-" then
    return "tag", nil, true
  end

  if token == "@-" then
    return "location", nil, true
  end

  local tag = token:match("^#([%w_%-]+)$")
  if tag then
    return "tag", tag, false
  end

  local location = token:match("^@([%w_%-]+)$")
  if location then
    return "location", location, false
  end

  return nil, nil, false
end

local function parse_worklog_tokens(text)
  local result = {
    metadata_tokens = {},
    option_tokens = {},
    invalid_tokens = {},
  }

  if text == "" then
    return result
  end

  for token in text:gmatch("%S+") do
    local kind, value, clear = parse_metadata_token(token)

    if kind then
      table.insert(result.metadata_tokens, {
        kind = kind,
        value = value,
        clear = clear or nil,
        raw = token,
      })
    else
      local key, option_value = token:match("^([%w_%-]+)=(.*)$")

      if key then
        table.insert(result.option_tokens, {
          key = key,
          value = option_value,
          raw = token,
        })
      else
        table.insert(result.invalid_tokens, token)
      end
    end
  end

  return result
end

local function parse_entry_metadata(text)
  local tokens = {}
  local tag = nil
  local tag_clear = nil
  local has_tag = false
  local location = nil
  local location_clear = nil
  local has_location = false
  local split_index = 0

  if text == "" then
    return "", nil, nil, nil, nil
  end

  for token in text:gmatch("%S+") do
    table.insert(tokens, token)
  end

  split_index = #tokens

  while split_index > 0 do
    local kind = parse_metadata_token(tokens[split_index])

    if not kind then
      break
    end

    split_index = split_index - 1
  end

  for i = split_index + 1, #tokens do
    local kind, value, clear = parse_metadata_token(tokens[i])

    if kind == "tag" then
      if has_tag then
        return nil, nil, nil, nil, nil, "multiple trailing tags are not allowed"
      end

      has_tag = true
      tag = value
      tag_clear = clear or nil
    elseif kind == "location" then
      if has_location then
        return nil, nil, nil, nil, nil, "multiple trailing locations are not allowed"
      end

      has_location = true
      location = value
      location_clear = clear or nil
    end
  end

  local text_tokens = {}

  for i = 1, split_index do
    table.insert(text_tokens, tokens[i])
  end

  return table.concat(text_tokens, " "), tag, tag_clear, location, location_clear
end

local function parse_header(line, row)
  local options_text = line:match("^%-%-%- worklog%s*(.-)%s*%-%-%-$")
  if options_text ~= nil then
    local options = parse_worklog_tokens(options_text)

    return {
      kind = "worklog_header",
      row = row,
      raw = line,
      metadata_tokens = options.metadata_tokens,
      option_tokens = options.option_tokens,
      invalid_tokens = options.invalid_tokens,
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
  local explicit_tag, explicit_tag_clear, explicit_location, explicit_location_clear, err

  text, explicit_tag, explicit_tag_clear, explicit_location, explicit_location_clear, err =
    parse_entry_metadata(text)
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
    explicit_tag = explicit_tag,
    explicit_tag_clear = explicit_tag_clear,
    explicit_location = explicit_location,
    explicit_location_clear = explicit_location_clear,
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

function M.parse_line(line, row)
  return parse_line(line, row or 1)
end

-- Parse a worklog file into syntax-preserving line nodes.
-- The returned document keeps every input line as an explicit node so later
-- semantic analysis can preserve source layout while deriving worklog meaning.
function M.parse(lines)
  local nodes = {}

  for row, line in ipairs(lines) do
    table.insert(nodes, M.parse_line(line, row))
  end

  return {
    kind = "document",
    row_count = #lines,
    nodes = nodes,
  }
end

return M
