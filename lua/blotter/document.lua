local syntax = require("blotter.syntax")

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
    return syntax.TOKEN_KIND.TAG, nil, true
  end

  if token == syntax.LOCATION_CLEAR_TOKEN then
    return syntax.TOKEN_KIND.LOCATION, nil, true
  end

  local tag = token:match("^#([%w_%-]+)$")
  if tag then
    return syntax.TOKEN_KIND.TAG, tag, false
  end

  local location = token:match("^@([%w_%-]+)$")
  if location then
    return syntax.TOKEN_KIND.LOCATION, location, false
  end

  -- A `utc±H[:MM]` offset is sticky metadata too; the value is signed minutes and
  -- there is no clear form (you change the offset, you do not unset it). Shared by
  -- the blot trailing-run scan (via parse_blot_control_token) and the header
  -- tokenizer (parse_worklog_tokens), so both recognize it with one grammar.
  local offset = syntax.parse_utc_offset(token)
  if offset ~= nil then
    return syntax.TOKEN_KIND.OFFSET, offset, false
  end

  return nil, nil, false
end

local function parse_blot_control_token(token)
  local kind, value, clear = parse_metadata_token(token)
  if kind then
    return kind, value, clear
  end

  if token == syntax.LOGGED_TOKEN then
    return syntax.TOKEN_KIND.LOGGED, true, false
  end

  -- A `round±N` rounding-balance marker is per-blot and non-sticky (like !L), so it
  -- is recognized here in the blot trailing run only -- never in the worklog header
  -- (parse_worklog_tokens uses parse_metadata_token, which does not see it).
  local nudge = syntax.parse_round_nudge(token)
  if nudge ~= nil then
    return syntax.TOKEN_KIND.NUDGE, nudge, false
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

local function parse_blot_metadata(text)
  local tokens = {}
  local result = {
    text = "",
    explicit_tag = nil,
    explicit_tag_clear = nil,
    explicit_location = nil,
    explicit_location_clear = nil,
    explicit_offset = nil,
    nudge = nil,
    logged = nil,
  }
  local has_tag = false
  local has_location = false
  local has_offset = false
  local has_nudge = false
  local has_logged = false

  if text == "" then
    return result
  end

  for token in text:gmatch("%S+") do
    table.insert(tokens, token)
  end

  local split_index = #tokens

  while split_index > 0 do
    local kind = parse_blot_control_token(tokens[split_index])

    if not kind then
      break
    end

    split_index = split_index - 1
  end

  for i = split_index + 1, #tokens do
    local kind, value, clear = parse_blot_control_token(tokens[i])

    if kind == syntax.TOKEN_KIND.TAG then
      if has_tag then
        return nil, "multiple trailing tags are not allowed"
      end

      has_tag = true
      result.explicit_tag = value
      result.explicit_tag_clear = clear or nil
    elseif kind == syntax.TOKEN_KIND.LOCATION then
      if has_location then
        return nil, "multiple trailing locations are not allowed"
      end

      has_location = true
      result.explicit_location = value
      result.explicit_location_clear = clear or nil
    elseif kind == syntax.TOKEN_KIND.OFFSET then
      if has_offset then
        return nil, "multiple trailing utc offsets are not allowed"
      end

      has_offset = true
      result.explicit_offset = value
    elseif kind == syntax.TOKEN_KIND.NUDGE then
      if has_nudge then
        return nil, "multiple trailing round markers are not allowed"
      end

      has_nudge = true
      result.nudge = value
    elseif kind == syntax.TOKEN_KIND.LOGGED then
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
  -- "blots" must be its own word: followed by whitespace (before any options)
  -- or by the closing dashes directly. This rejects "--- blotsx ---" and
  -- "--- blots#sales ---" (they fall through to a generic block header).
  local options_text = line:match("^%-%-%- blots%s+(.-)%s*%-%-%-$")
  if options_text == nil and line:match("^%-%-%- blots%-%-%-$") then
    options_text = ""
  end

  if options_text ~= nil then
    local options = parse_worklog_tokens(options_text)

    return {
      kind = syntax.NODE_KIND.WORKLOG_HEADER,
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
      kind = syntax.NODE_KIND.BLOCK_HEADER,
      row = row,
      raw = line,
      text = text,
    }
  end

  return nil
end

local function parse_blot(line, row)
  local hh, mm, rest = line:match("^(%d%d):(%d%d)(.*)$")
  if not hh then
    return nil
  end

  -- A summary row ("16:00 (+0m) workday") is byte-for-byte an blot timestamp plus a
  -- (+Nm) rounding marker; treat it as a note, not an blot. This keeps a d=hm summary
  -- row that leaks into a worklog body (e.g. after its summary header is deleted) from
  -- being miscounted as a real blot; the highlighter (highlight.lua) shares the rule.
  if rest:match("^%s+%([%+%-]%d+m%)") then
    return nil
  end

  if rest ~= "" and not rest:match("^%s") then
    return {
      kind = syntax.NODE_KIND.INVALID_ENTRY,
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
      kind = syntax.NODE_KIND.INVALID_ENTRY,
      row = row,
      raw = line,
      message = "invalid time",
    }
  end

  local text = normalize_text(rest:gsub("^%s+", ""))
  local metadata, err = parse_blot_metadata(text)
  if err then
    return {
      kind = syntax.NODE_KIND.INVALID_ENTRY,
      row = row,
      raw = line,
      message = err,
    }
  end

  return {
    kind = syntax.NODE_KIND.ENTRY,
    row = row,
    raw = line,
    minutes = hh * 60 + mm,
    text = metadata.text,
    explicit_tag = metadata.explicit_tag,
    explicit_tag_clear = metadata.explicit_tag_clear,
    explicit_location = metadata.explicit_location,
    explicit_location_clear = metadata.explicit_location_clear,
    explicit_offset = metadata.explicit_offset,
    nudge = metadata.nudge,
    logged = metadata.logged,
  }
end

local function parse_line(line, row)
  local header = parse_header(line, row)
  if header then
    return header
  end

  local blot = parse_blot(line, row)
  if blot then
    return blot
  end

  if line == "" then
    return {
      kind = syntax.NODE_KIND.BLANK_LINE,
      row = row,
      raw = line,
    }
  end

  return {
    kind = syntax.NODE_KIND.NOTE_LINE,
    row = row,
    raw = line,
    text = line,
  }
end

-- Classify a single whitespace-delimited token as worklog metadata: returns
-- (kind, value, clear) for a #tag / @location / #- / @- / !L, or nil otherwise.
-- Exposed so the highlighter (highlight.lua) classifies trailing-run and header
-- tokens with the very same grammar the parser uses, rather than a second copy.
M.classify_control_token = parse_blot_control_token

-- The remaining functions expose this parser's token grammar with byte positions,
-- so the highlighter is a pure projection of the parse and owns no patterns of its
-- own -- there is one grammar, here.

-- The whitespace-delimited tokens of a line, each with 0-based byte spans:
-- { col_start, col_end, text }. The split matches every other token scan here.
function M.tokens(line)
  local result = {}
  for start, text in line:gmatch("()(%S+)") do
    result[#result + 1] = { col_start = start - 1, col_end = start - 1 + #text, text = text }
  end
  return result
end

-- The (+Nm) / (-Nm) rounding markers on a line as 0-based byte spans. This is the
-- same marker shape parse_blot refuses to read as an blot (so a summary row never
-- counts as one); reusing it keeps the reader and the highlighter in lockstep.
function M.quant_error_spans(line)
  local spans = {}
  for start, text in line:gmatch("()(%([%+%-]%d+m%))") do
    spans[#spans + 1] = { col_start = start - 1, col_end = start - 1 + #text }
  end
  return spans
end

-- The byte length of a line's leading summary-duration token, or nil. A decimal
-- ("2.00h") or a single-digit-hour h:mm ("0:30") is always a duration (neither can
-- be an blot timestamp, which is a zero-padded HH:MM). A two-digit-hour HH:MM
-- ("16:00") is a duration only immediately before a rounding marker -- otherwise it
-- is an blot timestamp -- mirroring the blot/summary split parse_blot makes.
function M.summary_duration_length(line)
  local decimal = line:match("^%d+%.%d+h")
  if decimal then
    return #decimal
  end

  local hhmm = line:match("^%d+:%d%d")
  if hhmm and (line:match("^%d:%d%d") or line:match("^%d+:%d%d%s+%([%+%-]%d+m%)")) then
    return #hhmm
  end

  return nil
end

-- Whether a token is a key=value option (only meaningful in a worklog header).
function M.is_option_token(text)
  return text:match("^[%w_%-]+=") ~= nil
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
    kind = syntax.NODE_KIND.DOCUMENT,
    row_count = #lines,
    nodes = nodes,
  }
end

return M
