local render = require("worklog.render")

local M = {}

local function empty_buffer(lines)
  return #lines == 0 or (#lines == 1 and lines[1] == "")
end

-- Build the edit script for creating a new worklog block with optional default
-- header metadata.
function M.run(lines, defaults)
  defaults = defaults or {}

  local header =
    render.worklog_header_line(defaults.tag, defaults.location, defaults.quantize_minutes)

  if empty_buffer(lines) then
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
