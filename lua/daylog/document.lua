local syntax = require("daylog.syntax")
local strtext = require("daylog.text")

local M = {}

-- Syntax-preserving document parser.
--
-- Every source line becomes an explicit node so higher layers can derive
-- log meaning without losing original layout, raw text, or source rows.

-- The header-legal sticky metadata a token names -- #tag, @location, or a utc±H offset -- as
-- (kind, value), or nil. No clear form (`#-`/`@-`): those are entry-only, layered on by
-- parse_metadata_token. Shared so log-header recovery reads tags/locations with the parser's grammar.
local function parse_header_metadata_token(token)
  local tag = token:match("^#([%w_%-]+)$")
  if tag then
    return syntax.TOKEN_KIND.TAG, tag
  end

  local location = token:match("^@([%w_%-]+)$")
  if location then
    return syntax.TOKEN_KIND.LOCATION, location
  end

  -- A `utc±H[:MM]` offset is sticky metadata (signed minutes, no clear form) recognized by both
  -- the entry trailing-run scan and the header tokenizer with one grammar.
  local offset = syntax.parse_utc_offset(token)
  if offset ~= nil then
    return syntax.TOKEN_KIND.OFFSET, offset
  end

  return nil
end

local function parse_metadata_token(token)
  if token == syntax.TAG_CLEAR_TOKEN then
    return syntax.TOKEN_KIND.TAG, nil, true
  end

  if token == syntax.LOCATION_CLEAR_TOKEN then
    return syntax.TOKEN_KIND.LOCATION, nil, true
  end

  local kind, value = parse_header_metadata_token(token)
  return kind, value, false
end

local function parse_entry_control_token(token)
  local kind, value, clear = parse_metadata_token(token)
  if kind then
    return kind, value, clear
  end

  local logged_pairs = syntax.parse_logged_token(token)
  if logged_pairs then
    return syntax.TOKEN_KIND.LOGGED, logged_pairs, false
  end

  -- A `round±N` marker is per-entry and non-sticky, recognized here in the entry trailing run only,
  -- never in the log header.
  local nudge = syntax.parse_round_nudge(token)
  if nudge ~= nil then
    return syntax.TOKEN_KIND.NUDGE, nudge, false
  end

  return nil, nil, false
end

local function parse_log_tokens(text)
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

-- At most one trailing token of each kind; the per-kind message for a second. Keyed by TOKEN_KIND.
local DUPLICATE_METADATA = {
  [syntax.TOKEN_KIND.TAG] = "multiple trailing tags are not allowed",
  [syntax.TOKEN_KIND.LOCATION] = "multiple trailing locations are not allowed",
  [syntax.TOKEN_KIND.OFFSET] = "multiple trailing utc offsets are not allowed",
  [syntax.TOKEN_KIND.NUDGE] = "multiple trailing round markers are not allowed",
  -- LOGGED duplicates are reported per level (two `!T`, not `!S` + `!T`) inline in parse_entry_metadata.
}

local function parse_entry_metadata(text)
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

  local seen = {}
  for i = split_index + 1, #tokens do
    local kind, value, clear = parse_entry_control_token(tokens[i])

    if kind == syntax.TOKEN_KIND.LOGGED then
      -- Logging is per-level and one token may carry several (`!S225T525W525`); a repeated level is
      -- the duplicate error. `logged` is keyed by level, each a `{ minutes, names }` table (both
      -- optional; a bare marker is `{}`).
      for _, pair in ipairs(value) do
        local dup_key = "logged:" .. pair.level
        if seen[dup_key] then
          return nil, "duplicate trailing !" .. pair.level:upper() .. " markers are not allowed"
        end
        -- A frozen value can't exceed a day; a larger one is a hand-edit that would drive a
        -- multi-second surplus-inflation loop and print absurd totals, so refuse it here.
        if pair.minutes and pair.minutes > syntax.END_OF_DAY_MINUTES then
          return nil, "a logged !" .. pair.level:upper() .. " value can't exceed 1440 minutes"
        end
        seen[dup_key] = true
        result.logged = result.logged or {}
        result.logged[pair.level] = { minutes = pair.minutes, names = pair.names }
      end
    else
      -- Every other trailing control token is per-kind: at most one tag, location, offset, or nudge.
      if seen[kind] then
        return nil, DUPLICATE_METADATA[kind]
      end
      seen[kind] = true

      if kind == syntax.TOKEN_KIND.TAG then
        result.explicit_tag = value
        result.explicit_tag_clear = clear or nil
      elseif kind == syntax.TOKEN_KIND.LOCATION then
        result.explicit_location = value
        result.explicit_location_clear = clear or nil
      elseif kind == syntax.TOKEN_KIND.OFFSET then
        result.explicit_offset = value
      elseif kind == syntax.TOKEN_KIND.NUDGE then
        result.nudge = value
      end
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
  -- "log" must be its own word (whitespace or the closing dashes after it), rejecting "--- logx ---".
  local options_text = line:match("^%-%-%- log%s+(.-)%s*%-%-%-$")
  if options_text == nil and line:match("^%-%-%- log%-%-%-$") then
    options_text = ""
  end

  if options_text ~= nil then
    local options = parse_log_tokens(options_text)

    return {
      kind = syntax.NODE_KIND.LOG_HEADER,
      row = row,
      raw = line,
      metadata_tokens = options.metadata_tokens,
      option_tokens = options.option_tokens,
      invalid_tokens = options.invalid_tokens,
    }
  end

  -- Only a recognized header (a log header, or a generated summary/report section header) is a
  -- structural boundary; an unrecognized `--- x ---` falls through to a NOTE_LINE so it can never
  -- silently fragment a log.
  local text = line:match("^%-%-%- (.+) %-%-%-$")
  if text and syntax.is_summary_section_header(line) then
    return {
      kind = syntax.NODE_KIND.BLOCK_HEADER,
      row = row,
      raw = line,
      text = text,
    }
  end

  return nil
end

-- Split an entry's optional ` => label` alias off `description => label` on the LAST ` => `
-- (metadata already peeled, text already whitespace-normalized). Returns (description, alias) or
-- (text, nil).
local function split_alias(text)
  local before, alias = text:match("^(.+) => (.+)$")
  if not before then
    return text, nil
  end

  return before, alias
end

local function parse_entry(line, row)
  local hh, mm, rest = line:match("^(%d%d):(%d%d)(.*)$")
  if not hh then
    return nil
  end

  -- A summary row ("16:00 (+0m) workday") is an entry timestamp plus a (+Nm) marker; treat it as a
  -- silent note so a leaked summary row is never miscounted as an entry (the highlighter shares the
  -- rule). This MUST stay a note, not an invalid entry: when a banner is corrupted its d=hm rows leak
  -- into the log body, and a diagnostic there would mark the log invalid and block banner reclaim.
  if rest:match("^%s+" .. syntax.QUANT_MARKER) then
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

  -- 24:00 is a valid end-of-day boundary, letting a log close its final task at midnight.
  local valid_time = (hh <= 23 and mm <= 59) or (hh == 24 and mm == 0)
  if not valid_time then
    return {
      kind = syntax.NODE_KIND.INVALID_ENTRY,
      row = row,
      raw = line,
      message = "invalid time",
    }
  end

  local text = strtext.normalize(rest:gsub("^%s+", ""))
  -- Peel the trailing metadata run first, then split the remaining `description => label`.
  local metadata, err = parse_entry_metadata(text)
  if err then
    return {
      kind = syntax.NODE_KIND.INVALID_ENTRY,
      row = row,
      raw = line,
      message = err,
    }
  end

  local before, alias = split_alias(metadata.text)

  return {
    kind = syntax.NODE_KIND.ENTRY,
    row = row,
    raw = line,
    minutes = hh * 60 + mm,
    text = before,
    explicit_tag = metadata.explicit_tag,
    explicit_tag_clear = metadata.explicit_tag_clear,
    explicit_location = metadata.explicit_location,
    explicit_location_clear = metadata.explicit_location_clear,
    explicit_offset = metadata.explicit_offset,
    nudge = metadata.nudge,
    logged = metadata.logged,
    alias = alias,
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

  -- A near-miss timestamp ("9:00 standup") would silently become a note; flag it instead. A single-digit
  -- H:MM followed by a (±Nm) marker is an hm-format summary row (e.g. "1:00 (+0m) foo"), not an entry.
  -- (A single-digit clock followed by non-space -- "9:00am-ish" -- stays prose, by design.)
  local near_mm = line:match("^%d:(%d%d)$") or line:match("^%d:(%d%d)%s")
  if near_mm and not line:match("^%d:%d%d%s+" .. syntax.QUANT_MARKER) then
    -- Suggest the two-digit fix only when the minutes are themselves valid; otherwise the padded
    -- suggestion ("09:75") would still be an invalid time, so report that instead.
    local message = tonumber(near_mm) <= 59
        and ("entry timestamps use two-digit hours (write 0" .. line:sub(1, 4) .. ")")
      or "invalid time"
    return {
      kind = syntax.NODE_KIND.INVALID_ENTRY,
      row = row,
      raw = line,
      message = message,
    }
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

-- Classify a whitespace-delimited token as log metadata, returning (kind, value, clear) or nil.
-- Exposed so the highlighter uses the parser's grammar rather than a second copy.
M.classify_control_token = parse_entry_control_token
M.classify_header_metadata_token = parse_header_metadata_token

-- The remaining functions expose this parser's token grammar with byte positions, so the
-- highlighter is a pure projection of the parse and owns no patterns of its own.

-- The whitespace-delimited tokens of a line, each with 0-based byte spans:
-- { col_start, col_end, text }. The split matches every other token scan here.
function M.tokens(line)
  local result = {}
  for start, text in line:gmatch("()(%S+)") do
    result[#result + 1] = { col_start = start - 1, col_end = start - 1 + #text, text = text }
  end
  return result
end

-- The 1-based index where a line's trailing metadata run begins (#tokens + 1 when none), scanning
-- `tokens` backward -- one definition of where trailing metadata starts, for parser and highlighter.
function M.trailing_metadata_start(tokens)
  local start = #tokens + 1
  for i = #tokens, 1, -1 do
    if parse_entry_control_token(tokens[i].text) then
      start = i
    else
      break
    end
  end
  return start
end

-- The 0-based byte span { col_start, col_end } of an entry's ` => label` alias (end exclusive),
-- or nil. Mirrors the parser so the highlighter colors exactly what it reads as the alias.
function M.alias_span(line)
  local tokens = M.tokens(line)

  -- The trailing run of metadata tokens is not part of the alias.
  local last_label = M.trailing_metadata_start(tokens) - 1

  -- The alias opens at the last `=>` token at or before the final label word.
  local arrow
  for i = last_label - 1, 1, -1 do
    if tokens[i].text == "=>" then
      arrow = i
      break
    end
  end

  -- A real alias needs a description before the arrow: index 3 is the earliest valid arrow (after
  -- timestamp + description), so `08:00 => foo` is none.
  if not arrow or arrow < 3 then
    return nil
  end

  return { col_start = tokens[arrow].col_start, col_end = tokens[last_label].col_end }
end

-- The (+Nm) / (-Nm) rounding markers on a line as 0-based byte spans -- the same shape parse_entry
-- refuses to read as an entry, keeping reader and highlighter in lockstep.
function M.quant_error_spans(line)
  local spans = {}
  for start, text in line:gmatch("()(" .. syntax.QUANT_MARKER .. ")") do
    spans[#spans + 1] = { col_start = start - 1, col_end = start - 1 + #text }
  end
  return spans
end

-- The byte length of a line's leading summary-duration token, or nil. A decimal ("2.00h") or a
-- single-digit-hour h:mm ("0:30") is always a duration; a two-digit HH:MM ("16:00") only when it
-- precedes a rounding marker -- else it is an entry timestamp, mirroring parse_entry's split.
function M.summary_duration_length(line)
  local decimal = line:match("^%d+%.%d+h")
  if decimal then
    return #decimal
  end

  local hhmm = line:match("^%d+:%d%d")
  if hhmm and (line:match("^%d:%d%d") or line:match("^%d+:%d%d%s+" .. syntax.QUANT_MARKER)) then
    return #hhmm
  end

  return nil
end

-- Whether a token is a key=value option (only meaningful in a log header).
function M.is_option_token(text)
  return text:match("^[%w_%-]+=") ~= nil
end

function M.parse_line(line, row)
  return parse_line(line, row or 1)
end

-- Parse a daylog file into syntax-preserving line nodes, one per input line.
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
