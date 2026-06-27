local M = {}

M.LOGGED_TOKEN = "!L"
M.TAG_CLEAR_TOKEN = "#-"
M.LOCATION_CLEAR_TOKEN = "@-"
M.OUT_OF_OFFICE_TAG = "ooo"

M.OPTION_QUANTIZE = "q"
M.OPTION_DURATION = "d"

M.DURATION_DECIMAL = "dec"
M.DURATION_HM = "hm"

M.DURATION_FORMATS = { [M.DURATION_DECIMAL] = true, [M.DURATION_HM] = true }

M.DEFAULT_QUANTIZE_MINUTES = 15
M.END_OF_DAY_MINUTES = 24 * 60

-- Syntax node kinds produced by document.lua and consumed by analyze.lua and
-- entry.lua. Shared so producer and consumers cannot drift on a bare string.
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

-- Block kinds produced by analyze.lua. A log block carries timestamped entries; a
-- generic block is a generated summary/report section header -- the only non-log
-- headers there are, since an unrecognized `--- x ---` is demoted to a note line
-- (document.lua), never a block.
M.BLOCK_KIND = {
  LOG = "log_block",
  GENERIC = "generic_block",
}

-- Metadata token kinds produced by document.lua's token parsers and consumed
-- when interpreting entry and header metadata.
M.TOKEN_KIND = {
  TAG = "tag",
  LOCATION = "location",
  LOGGED = "logged",
  OFFSET = "offset",
  NUDGE = "nudge",
}

-- Generated section-header words fed to section_header(). Shared so render.lua
-- (which produces the headers) and usecases that match them (log_current) agree.
M.SECTION = {
  SUMMARY = "summary",
  TAGS = "tags",
  LOCATIONS = "locations",
  LOGGED = "logged",
  TOTALS = "totals",
}

-- Diagnostic codes shared by the analyzer (producer and classifier) and the
-- diagnostics module (message formatting), so the two never drift apart.
M.DIAGNOSTIC = {
  INVALID_ENTRY = "invalid_entry",
  UNORDERED_TIMESTAMPS = "unordered_timestamps",
  MIDNIGHT_NOT_FINAL = "midnight_not_final",
  MIXED_OFFSET = "mixed_offset",
  INVALID_FIRST_HEADER = "invalid_first_header",
  INVALID_LOG_HEADER_OPTION = "invalid_log_header_option",
  INVALID_LOG_HEADER_METADATA = "invalid_log_header_metadata",
  INVALID_LOG_HEADER_TOKEN = "invalid_log_header_token",
}

-- Diagnostic categories. Structural diagnostics describe a malformed document
-- shape (bad first header, bad header options); block diagnostics describe a
-- problem within one log block's entries that stops it being acted on or summarized.
M.DIAGNOSTIC_CATEGORY = {
  STRUCTURAL = "structural",
  BLOCK = "block",
}

-- Single source of truth mapping each code to its category, colocated with the
-- code definitions so a new code's category cannot be forgotten. analyze.lua
-- stamps this onto every diagnostic at production time.
M.DIAGNOSTIC_CATEGORY_BY_CODE = {
  [M.DIAGNOSTIC.INVALID_ENTRY] = M.DIAGNOSTIC_CATEGORY.BLOCK,
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

-- The summary banner echoes the parameters it was generated with (read-only
-- provenance; the log header stays the source of truth).
function M.summary_header(quantize_minutes, duration_format)
  return string.format(
    "--- summary q=%d d=%s ---",
    quantize_minutes or M.DEFAULT_QUANTIZE_MINUTES,
    duration_format or M.DURATION_DECIMAL
  )
end

-- The section words that head a generated summary section. Shared so the
-- highlighter and the summary-region locator recognize the same headers.
M.SUMMARY_SECTION_WORDS = {
  [M.SECTION.SUMMARY] = true,
  [M.SECTION.TAGS] = true,
  [M.SECTION.LOCATIONS] = true,
  [M.SECTION.LOGGED] = true,
  [M.SECTION.TOTALS] = true,
}

-- Whether a line is a generated summary-section header, in-file
-- (`--- summary q=.. d=.. ---`, `--- tags ---`, ...) or in a multi-day report
-- (`--- day summary <label> ---`, `--- week totals <label> ---`, ...): a section
-- word appears as the first or second word, which is exactly what render.lua emits.
-- Used by the highlighter, which highlights report sections too.
function M.is_summary_section_header(raw)
  local content = raw:match("^%-%-%- (.+) %-%-%-$")
  if not content then
    return false
  end

  local first, second = content:match("^(%S+)%s*(%S*)")
  return M.SUMMARY_SECTION_WORDS[first] == true or M.SUMMARY_SECTION_WORDS[second] == true
end

-- Whether a line is one of the bare *in-file* summary-section headers a log's
-- own summary is built from: the `--- summary q=N d=fmt ---` banner, or a bare
-- `--- tags ---` / `--- locations ---` / `--- logged ---` / `--- totals ---`.
-- Stricter than is_summary_section_header on purpose: a labeled report header
-- (`--- day summary <date> ---`, legacy `--- summary exact ---`) is NOT a log's
-- in-file summary, so the summary-region locator must not anchor on one.
function M.is_infile_summary_header(raw)
  if raw:match("^%-%-%- summary q=%d+ d=%a+ %-%-%-$") then
    return true
  end

  local content = raw:match("^%-%-%- (%S+) %-%-%-$")
  return content ~= nil
    and content ~= M.SECTION.SUMMARY
    and M.SUMMARY_SECTION_WORDS[content] == true
end

-- Whether a line has the shape of a generated summary duration row -- a duration
-- token followed by a `(±Nm)` rounding-error marker (`3.00h (+0m) workday`,
-- `9:54 (-13m) design2 !L`). The shape backstop used when no banner survives at
-- all: the surviving generated rows are recognized by this so their span can be
-- located and blasted. The marker's sign is required -- render always emits one via
-- `%+d`, so an unsigned `(Nm)` in a hand-written note is never mistaken for a row.
function M.is_summary_row(raw)
  return raw:match("^%S+ %([%+%-]%d+m%)") ~= nil
end

-- UTC-offset markers: a third sticky dimension alongside #tag / @location.
--
-- A keyword token `utc±H[:MM]` records the absolute UTC offset of a stretch of
-- entries -- `utc+2` (east of UTC), `utc-4` (west), `utc+5:30`, `utc+0` (UTC). The
-- sign is required, so the bare word "utc" in activity text is never captured and a
-- malformed `utc-x` harmlessly stays plain text (fail-safe). The value is signed
-- minutes; entries reconcile durations and ordering by effective UTC time
-- (`local_minutes - offset_minutes`) while display stays the written local clock.

-- Parse the signed body of an offset ("+2", "-4", "+5:30", "+0") into signed
-- minutes, or nil when it is not a well-formed offset. Shared by parse_utc_offset
-- (which strips the `utc` keyword first) and config.lua (which validates a
-- `defaults.utc` string, which has no keyword). The leading sign is mandatory;
-- hours are capped at 14 and minutes at 59, so every real-world offset round-trips
-- and any other token fails to parse rather than being silently misread.
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
  if hours > 14 or minutes > 59 then
    return nil
  end

  local total = hours * 60 + minutes
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

-- Manual rounding-balance markers: a non-sticky, per-entry trailing token
-- `round±N` that forces this entry's quantization row to round N q-steps beyond
-- the largest-remainder baseline (`round+1` = one bucket up, `round-1` = one down).
-- The sign is required, so a bare `round` in activity text is never captured and a
-- malformed `round+x` harmlessly stays plain text. Used to balance residuals so an
-- aggregate (a day, hence a week) lands on a clean total; see usecases/balance_summary.

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

-- Render a signed q-step count back into the canonical token: 1 -> "round+1",
-- -2 -> "round-2". A negative number carries its own "-".
function M.round_nudge_token(n)
  return "round" .. (n < 0 and "" or "+") .. n
end

-- The `!L` logged marker optionally carries a frozen committed value in minutes
-- (`!L60`): the row is held at that exact duration and excluded from the
-- largest-remainder pool, so an external commitment never moves when later entries
-- are appended. Bare `!L` stays "logged but unfrozen" (current behavior); only
-- :DaylogLog writes the number. The minutes ride on the marker itself rather than a
-- separate token, so `round±N` remains the only free-standing rounding knob.

-- Parse a `!L` / `!L<minutes>` marker. Returns (true, minutes) for a frozen marker,
-- (true, nil) for a bare one, or false when the token is not a logged marker.
function M.parse_logged_token(token)
  local digits = token:match("^!L(%d*)$")
  if not digits then
    return false
  end

  if digits == "" then
    return true, nil
  end

  return true, tonumber(digits)
end

-- Render a logged marker: bare `!L`, or `!L<minutes>` when a frozen value is present.
function M.logged_token(minutes)
  if minutes == nil then
    return M.LOGGED_TOKEN
  end

  return M.LOGGED_TOKEN .. minutes
end

return M
