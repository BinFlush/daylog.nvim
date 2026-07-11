local render = require("daylog.render")
local support = require("daylog.usecases.support")
local text = require("daylog.text")

local M = {}

-- Build the edit script for creating a new log block with optional default
-- header metadata.
function M.run(lines, defaults)
  defaults = defaults or {}

  local header = render.log_header_line(
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

  -- The canonical inter-log separator is two blanks after a summary zone; top up from
  -- whatever the buffer's tail already holds so the next refresh finds nothing to rewrite.
  local appended_lines = {}
  for _ = support.trailing_blank_count(lines) + 1, 2 do
    table.insert(appended_lines, "")
  end
  table.insert(appended_lines, header)

  local result = support.append_edit(lines, appended_lines)
  result.cursor = { #lines + #appended_lines, 0 }
  return result
end

return M
