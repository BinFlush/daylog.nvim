local M = {}

-- Logging levels S/T/L/W (summary/tag/location/workday), each independently frozen; the letters
-- are the first letter of each summary section, in canonical emission order.
M.LOGGED_LEVELS = { "s", "t", "l", "w" }
local LOGGED_LETTER = { s = "S", t = "T", l = "L", w = "W" }
local LOGGED_LEVEL_OF = { S = "s", T = "t", L = "l", W = "w" }

M.TAG_CLEAR_TOKEN = "#-"
M.LOCATION_CLEAR_TOKEN = "@-"

M.OPTION_QUANTIZE = "q"
M.OPTION_DURATION = "d"

M.DURATION_DECIMAL = "dec"
M.DURATION_HM = "hm"

M.DURATION_FORMATS = { [M.DURATION_DECIMAL] = true, [M.DURATION_HM] = true }

M.DEFAULT_QUANTIZE_MINUTES = 15
M.END_OF_DAY_MINUTES = 24 * 60

-- The `(±Nm)` rounding-error marker a generated summary row carries; the sign is mandatory so an
-- unsigned `(Nm)` in a hand-written note is never read as a row. Shared by every summary-row scan.
M.QUANT_MARKER = "%([%+%-]%d+m%)"

-- Syntax node kinds, shared so producer (document.lua) and consumers cannot drift on a bare string.
M.NODE_KIND = {
  LOG_HEADER = "log_header",
  BLOCK_HEADER = "block_header",
  ENTRY = "entry",
  INVALID_ENTRY = "invalid_entry",
  BLANK_LINE = "blank_line",
  NOTE_LINE = "note_line",
  DOCUMENT = "document",
  ENTRY_ITEM = "entry_item",
  ANALYSIS = "analysis",
}

-- Block kinds: a log block carries entries, a generic block is a generated summary/report header
-- (an unrecognized `--- x ---` is demoted to a note line, never a block).
M.BLOCK_KIND = {
  LOG = "log_block",
  GENERIC = "generic_block",
}

-- Metadata token kinds from document.lua's token parsers.
M.TOKEN_KIND = {
  TAG = "tag",
  LOCATION = "location",
  LOGGED = "logged",
  OFFSET = "offset",
  NUDGE = "nudge",
}

-- Section-header words fed to section_header(); shared so render.lua and the matching usecases agree.
M.SECTION = {
  SUMMARY = "summary",
  TAGS = "tags",
  LOCATIONS = "locations",
  LOGGED = "logged",
  TOTALS = "totals",
}

-- Diagnostic codes shared by the analyzer and the diagnostics module, so the two never drift apart.
M.DIAGNOSTIC = {
  INVALID_ENTRY = "invalid_entry",
  BLANK_ENTRY_METADATA = "blank_entry_metadata",
  UNORDERED_TIMESTAMPS = "unordered_timestamps",
  MIDNIGHT_NOT_FINAL = "midnight_not_final",
  MIXED_OFFSET = "mixed_offset",
  INVALID_FIRST_HEADER = "invalid_first_header",
  INVALID_LOG_HEADER_OPTION = "invalid_log_header_option",
  INVALID_LOG_HEADER_METADATA = "invalid_log_header_metadata",
  INVALID_LOG_HEADER_TOKEN = "invalid_log_header_token",
}

-- Diagnostic categories: structural = a malformed document shape; block = a problem within one
-- log's entries that stops it being acted on or summarized.
M.DIAGNOSTIC_CATEGORY = {
  STRUCTURAL = "structural",
  BLOCK = "block",
}

-- Single source of truth mapping each code to its category, colocated so a new code's category
-- cannot be forgotten; analyze.lua stamps it onto every diagnostic at production time.
M.DIAGNOSTIC_CATEGORY_BY_CODE = {
  [M.DIAGNOSTIC.INVALID_ENTRY] = M.DIAGNOSTIC_CATEGORY.BLOCK,
  [M.DIAGNOSTIC.BLANK_ENTRY_METADATA] = M.DIAGNOSTIC_CATEGORY.BLOCK,
  [M.DIAGNOSTIC.UNORDERED_TIMESTAMPS] = M.DIAGNOSTIC_CATEGORY.BLOCK,
  [M.DIAGNOSTIC.MIDNIGHT_NOT_FINAL] = M.DIAGNOSTIC_CATEGORY.BLOCK,
  [M.DIAGNOSTIC.MIXED_OFFSET] = M.DIAGNOSTIC_CATEGORY.BLOCK,
  [M.DIAGNOSTIC.INVALID_FIRST_HEADER] = M.DIAGNOSTIC_CATEGORY.STRUCTURAL,
  [M.DIAGNOSTIC.INVALID_LOG_HEADER_OPTION] = M.DIAGNOSTIC_CATEGORY.STRUCTURAL,
  [M.DIAGNOSTIC.INVALID_LOG_HEADER_METADATA] = M.DIAGNOSTIC_CATEGORY.STRUCTURAL,
  [M.DIAGNOSTIC.INVALID_LOG_HEADER_TOKEN] = M.DIAGNOSTIC_CATEGORY.STRUCTURAL,
}

function M.section_header(section)
  return "--- " .. section .. " ---"
end

-- The summary banner echoes the parameters it was generated with (read-only provenance; the log
-- header stays the source of truth).
function M.summary_header(quantize_minutes, duration_format)
  return string.format(
    "--- summary q=%d d=%s ---",
    quantize_minutes or M.DEFAULT_QUANTIZE_MINUTES,
    duration_format or M.DURATION_DECIMAL
  )
end

-- The section words that head a generated summary section, shared so the highlighter and the
-- summary-region locator agree. `logged` isn't emitted but stays recognized so refresh reclaims
-- and removes a stale `--- logged ---` section.
M.SUMMARY_SECTION_WORDS = {
  [M.SECTION.SUMMARY] = true,
  [M.SECTION.TAGS] = true,
  [M.SECTION.LOCATIONS] = true,
  [M.SECTION.LOGGED] = true,
  [M.SECTION.TOTALS] = true,
}

-- The scope prefixes render.lua puts before a section word in report headers (`day`/`range`;
-- `week` is legacy).
local REPORT_PREFIXES = { day = true, week = true, range = true }

-- Whether a line is a generated summary-section header; a section word in second position counts
-- only after a known report prefix, so prose like `--- meeting summary ---` never fragments a log.
function M.is_summary_section_header(raw)
  local content = raw:match("^%-%-%- (.+) %-%-%-$")
  if not content then
    return false
  end

  local first, second = content:match("^(%S+)%s*(%S*)")
  if M.SUMMARY_SECTION_WORDS[first] == true then
    return true
  end
  return REPORT_PREFIXES[first] == true and M.SUMMARY_SECTION_WORDS[second] == true
end

-- Whether a line is a bare *in-file* summary-section header (the `--- summary q=N d=fmt ---` banner
-- or a bare `--- tags ---`/etc) -- stricter than is_summary_section_header on purpose, so the
-- summary-region locator never anchors on a labeled report header.
function M.is_infile_summary_header(raw)
  if raw:match("^%-%-%- summary q=%d+ d=%a+ %-%-%-$") then
    return true
  end

  local content = raw:match("^%-%-%- (%S+) %-%-%-$")
  return content ~= nil
    and content ~= M.SECTION.SUMMARY
    and M.SUMMARY_SECTION_WORDS[content] == true
end

-- Whether a line has the shape of a generated summary duration row (a duration token then a
-- `(±Nm)` marker) -- the shape backstop when no banner survives. The marker's sign is required
-- (render emits `%+d`), so an unsigned `(Nm)` in a hand-written note is never mistaken for a row.
function M.is_summary_row(raw)
  return raw:match("^%S+ " .. M.QUANT_MARKER) ~= nil
end

-- UTC-offset markers: a third sticky dimension alongside #tag/@location. The `utc±H[:MM]` token is
-- signed minutes (sign required, so bare `utc` in activity text is never captured); entries
-- reconcile durations and ordering by effective UTC (`local_minutes - offset_minutes`) while
-- display stays the written local clock.

-- Parse the signed body of an offset (`+2`, `-4`, `+5:30`, `+0`) into signed minutes, or nil.
-- Shared by parse_utc_offset and config.lua; the leading sign is mandatory and hours are capped
-- at 14 / minutes at 59, so any other token fails to parse rather than being silently misread.
function M.parse_offset_value(value)
  if type(value) ~= "string" then
    return nil
  end

  local sign, hours, minutes = value:match("^([%+%-])(%d+):(%d%d)$")
  if not sign then
    sign, hours = value:match("^([%+%-])(%d+)$")
    minutes = "0"
  end

  if not sign then
    return nil
  end

  hours = tonumber(hours)
  minutes = tonumber(minutes)
  -- Real-world offsets span -12:00..+14:00; cap the total so e.g. +14:59 fails to parse.
  local total = hours * 60 + minutes
  if minutes > 59 or total > 14 * 60 then
    return nil
  end
  if sign == "-" then
    total = -total
  end

  return total
end

-- Parse a `utc±H[:MM]` token into signed minutes, or nil when it is not one.
function M.parse_utc_offset(token)
  local value = token:match("^utc(.+)$")
  if not value then
    return nil
  end

  return M.parse_offset_value(value)
end

-- Render signed minutes back into the canonical token: 0 -> "utc+0",
-- -240 -> "utc-4", 330 -> "utc+5:30" (the :MM part appears only when nonzero).
function M.utc_offset_token(minutes)
  local sign = minutes < 0 and "-" or "+"
  local abs = math.abs(minutes)
  local hours = math.floor(abs / 60)
  local mins = abs % 60

  if mins == 0 then
    return string.format("utc%s%d", sign, hours)
  end

  return string.format("utc%s%d:%02d", sign, hours, mins)
end

-- Manual rounding-balance markers: a non-sticky, per-entry `round±N` forcing this entry's
-- quantization row N q-steps beyond the largest-remainder baseline (sign required, so a bare
-- `round` in activity text is never captured). Balances residuals so an aggregate lands on a clean
-- total; see usecases/balance_summary.

-- Parse a `round±N` token into a signed integer of q-steps, or nil when it is not one.
function M.parse_round_nudge(token)
  local sign, digits = token:match("^round([%+%-])(%d+)$")
  if not sign then
    return nil
  end

  local n = tonumber(digits)
  if sign == "-" then
    n = -n
  end

  return n
end

-- Render a signed q-step count back into the canonical token: 1 -> "round+1", -2 -> "round-2".
function M.round_nudge_token(n)
  return "round" .. (n < 0 and "" or "+") .. n
end

-- A logged marker optionally carries a frozen committed value in minutes (`!S60`): the row is held
-- at that exact duration and excluded from the largest-remainder pool, so an external commitment
-- never moves as later entries are appended. A bare marker (`!S`) is logged-but-unfrozen; only
-- :Daylog log writes the number.

-- Parse a bracket body (`a,b`) into a canonical (deduped, sorted) name list, or nil when it is empty
-- or holds an empty or illegally-charactered element. Names use the tag charset and are case-sensitive.
local function parse_name_list(inner)
  if inner == "" then
    return nil
  end

  local seen, names = {}, {}
  local start = 1
  while true do
    local comma = inner:find(",", start, true)
    local element = inner:sub(start, comma and comma - 1 or #inner)
    if element:match("^[%w_%-]+$") == nil then
      return nil
    end
    if not seen[element] then
      seen[element] = true
      names[#names + 1] = element
    end
    if not comma then
      break
    end
    start = comma + 1
  end

  table.sort(names)
  return names
end

-- Parse a compact logged marker (`!` then level pairs, e.g. `!S[a]225T[a,b]525W525`; the separated
-- `!S225 !T525` also parses). Each pair is a level letter, an optional bracketed name list, then an
-- optional frozen value. Returns an ORDERED list of { level, minutes, names } (minutes/names nil when
-- absent), keeping repeats so the caller can reject a duplicated level, or nil when the token is not
-- a logged marker.
function M.parse_logged_token(token)
  if token:sub(1, 1) ~= "!" then
    return nil
  end
  local body = token:sub(2)
  if body == "" then
    return nil
  end

  local pairs_out = {}
  local pos, len = 1, #body
  while pos <= len do
    local level = LOGGED_LEVEL_OF[body:sub(pos, pos)]
    if not level then
      return nil
    end
    pos = pos + 1

    local names
    if body:sub(pos, pos) == "[" then
      local close = body:find("]", pos + 1, true)
      if not close then
        return nil
      end
      names = parse_name_list(body:sub(pos + 1, close - 1))
      if not names then
        return nil
      end
      pos = close + 1
    end

    local digits = body:match("^%d*", pos)
    -- A pathological digit run would overflow to `inf` and poison quantization; cap the length and
    -- treat anything longer as not a marker.
    if #digits > 9 then
      return nil
    end
    pos = pos + #digits

    pairs_out[#pairs_out + 1] = {
      level = level,
      minutes = digits ~= "" and tonumber(digits) or nil,
      names = names,
    }
  end

  return pairs_out
end

-- The frozen committed minutes of a per-level logged value, or nil when unfrozen.
function M.committed_minutes(v)
  return type(v) == "table" and v.minutes or nil
end

-- A `\0`-joined canonical key of a per-level logged value's names, `""` when it carries none.
function M.names_key(v)
  if type(v) == "table" and v.names and #v.names > 0 then
    return table.concat(v.names, "\0")
  end
  return ""
end

-- The display suffix for a per-level logged value's names (`"[a,b]"`), `""` when it carries none.
function M.format_names(v)
  if type(v) == "table" and v.names and #v.names > 0 then
    return "[" .. table.concat(v.names, ",") .. "]"
  end
  return ""
end

-- Render an entry's `logged` table as one compact token (`!` + each present level's letter, name
-- list, and frozen value in canonical S/T/L/W order), or nil when nothing is logged.
function M.format_logged(logged)
  if not logged then
    return nil
  end

  local body = {}
  for _, level in ipairs(M.LOGGED_LEVELS) do
    local committed = logged[level]
    if committed ~= nil then
      body[#body + 1] = LOGGED_LETTER[level]
        .. M.format_names(committed)
        .. (M.committed_minutes(committed) or "")
    end
  end

  if #body == 0 then
    return nil
  end
  return "!" .. table.concat(body)
end

-- Render a single-level display marker (`!S`/`!T[a,b]`/...) for a summary row; bare when `names` is
-- nil or empty, else carrying the (already canonical) name list.
function M.logged_token(level, names)
  local token = "!" .. LOGGED_LETTER[level]
  if not names or #names == 0 then
    return token
  end

  return token .. "[" .. table.concat(names, ",") .. "]"
end

return M
