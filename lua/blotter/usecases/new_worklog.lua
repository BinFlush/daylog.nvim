local render = require("blotter.render")
local text = require("blotter.text")

local M = {}

-- Build the edit script for creating a new worklog block with optional default
-- header metadata.
function M.run(lines, defaults)
  defaults = defaults or {}

  local header = render.worklog_header_line(
    defaults.tag,
    defaults.location,
    defaults.utc,
    defaults.quantize_minutes,
    defaults.duration_format
  )

  -- An empty or whitespace-only buffer is initialized in place rather than appended
  -- to (which would push the header off line 1).
  if text.is_empty(lines) then
    return {
      edits = {
        {
          start_index = 0,
          end_index = #lines,
          lines = { header },
        },
      },
      cursor = { 1, 0 },
    }
  end

  local appended_lines = {}
  if lines[#lines] ~= "" then
    table.insert(appended_lines, "")
  end
  table.insert(appended_lines, header)

  return {
    edits = {
      {
        start_index = #lines,
        end_index = #lines,
        lines = appended_lines,
      },
    },
    cursor = { #lines + #appended_lines, 0 },
  }
end

return M
