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

function M.section_header(section, kind)
  return "--- " .. section .. " " .. kind .. " ---"
end

return M
