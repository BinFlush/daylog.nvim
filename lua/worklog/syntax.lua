local M = {}

M.LOGGED_TOKEN = "!L"
M.TAG_CLEAR_TOKEN = "#-"
M.LOCATION_CLEAR_TOKEN = "@-"
M.OUT_OF_OFFICE_TAG = "ooo"

M.OPTION_QUANTIZE = "quantize"
M.OPTION_DURATION = "duration"

M.DURATION_DECIMAL = "decimal"
M.DURATION_HHMM = "hhmm"

M.OPTIONS = { [M.OPTION_QUANTIZE] = true, [M.OPTION_DURATION] = true }
M.DURATION_FORMATS = { [M.DURATION_DECIMAL] = true, [M.DURATION_HHMM] = true }

M.DEFAULT_QUANTIZE_MINUTES = 15
M.END_OF_DAY_MINUTES = 24 * 60

-- Syntax node kinds produced by document.lua and consumed by analyze.lua and
-- entry.lua. Shared so producer and consumers cannot drift on a bare string.
M.NODE_KIND = {
  WORKLOG_HEADER = "worklog_header",
  BLOCK_HEADER = "block_header",
  ENTRY = "entry",
  INVALID_ENTRY = "invalid_entry",
  BLANK_LINE = "blank_line",
  NOTE_LINE = "note_line",
  DOCUMENT = "document",
  ENTRY_ITEM = "entry_item",
  ANALYSIS = "analysis",
}

-- Block kinds produced by analyze.lua. A worklog block carries timestamped
-- entries; a generic block is any other header-delimited section.
M.BLOCK_KIND = {
  WORKLOG = "worklog_block",
  GENERIC = "generic_block",
}

-- Metadata token kinds produced by document.lua's token parsers and consumed
-- when interpreting entry and header metadata.
M.TOKEN_KIND = {
  TAG = "tag",
  LOCATION = "location",
  LOGGED = "logged",
}

-- Report kinds selecting exact versus quantized summary computation and rendering.
M.REPORT_KIND = {
  EXACT = "exact",
  QUANTIZED = "quantized",
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
  INVALID_FIRST_HEADER = "invalid_first_header",
  INVALID_WORKLOG_HEADER_OPTION = "invalid_worklog_header_option",
  INVALID_WORKLOG_HEADER_METADATA = "invalid_worklog_header_metadata",
  INVALID_WORKLOG_HEADER_TOKEN = "invalid_worklog_header_token",
}

-- Diagnostic categories. Structural diagnostics describe a malformed document
-- shape (bad first header, bad header options); block diagnostics describe a
-- problem within one worklog block's entries.
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
  [M.DIAGNOSTIC.INVALID_FIRST_HEADER] = M.DIAGNOSTIC_CATEGORY.STRUCTURAL,
  [M.DIAGNOSTIC.INVALID_WORKLOG_HEADER_OPTION] = M.DIAGNOSTIC_CATEGORY.STRUCTURAL,
  [M.DIAGNOSTIC.INVALID_WORKLOG_HEADER_METADATA] = M.DIAGNOSTIC_CATEGORY.STRUCTURAL,
  [M.DIAGNOSTIC.INVALID_WORKLOG_HEADER_TOKEN] = M.DIAGNOSTIC_CATEGORY.STRUCTURAL,
}

function M.section_header(section, kind)
  return "--- " .. section .. " " .. kind .. " ---"
end

return M
