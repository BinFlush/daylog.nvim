local syntax = require("worklog.syntax")

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
  if token == syntax.TAG_CLEAR_TOKEN then
    return "tag", nil, true
  end

  if token == syntax.LOCATION_CLEAR_TOKEN then
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

local function parse_entry_control_token(token)
  local kind, value, clear = parse_metadata_token(token)
  if kind then
    return kind, value, clear
  end

  if token == syntax.LOGGED_TOKEN then
    return "logged", true, false
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
  local result = {
    text = "",
    explicit_tag = nil,
    explicit_tag_clear = nil,
    explicit_location = nil,
    explicit_location_clear = nil,
    logged = nil,
  }
  local has_tag = false
  local has_location = false
  local has_logged = false

  if text == "" then
    return result
  end

  for token in text:gmatch("%S+") do
    table.insert(tokens, token)
  end

  local split_index = #tokens

  while split_index > 0 do
    local kind = parse_entry_control_token(tokens[split_index])

    if not kind then
      break
    end

    split_index = split_index - 1
  end

  for i = split_index + 1, #tokens do
    local kind, value, clear = parse_entry_control_token(tokens[i])

    if kind == "tag" then
      if has_tag then
        return nil, "multiple trailing tags are not allowed"
      end

      has_tag = true
      result.explicit_tag = value
      result.explicit_tag_clear = clear or nil
    elseif kind == "location" then
      if has_location then
        return nil, "multiple trailing locations are not allowed"
      end

      has_location = true
      result.explicit_location = value
      result.explicit_location_clear = clear or nil
    elseif kind == "logged" then
      if has_logged then
        return nil, "duplicate trailing !L markers are not allowed"
      end

      has_logged = true
      result.logged = true
    end
  end

  local text_tokens = {}

  for i = 1, split_index do
    table.insert(text_tokens, tokens[i])
  end

  result.text = table.concat(text_tokens, " ")
  return result
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

  -- 24:00 is a valid end-of-day boundary; it lets a worklog close its final
  -- task at midnight, contiguous with the next day's 00:00.
  local valid_time = (hh <= 23 and mm <= 59) or (hh == 24 and mm == 0)
  if not valid_time then
    return {
      kind = "invalid_entry",
      row = row,
      raw = line,
      message = "invalid time",
    }
  end

  local text = normalize_text(rest:gsub("^%s+", ""))
  local metadata, err = parse_entry_metadata(text)
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
    text = metadata.text,
    explicit_tag = metadata.explicit_tag,
    explicit_tag_clear = metadata.explicit_tag_clear,
    explicit_location = metadata.explicit_location,
    explicit_location_clear = metadata.explicit_location_clear,
    logged = metadata.logged,
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
