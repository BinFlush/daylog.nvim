local blocks = require("worklog.blocks")

local M = {}

local NO_WORKLOG_ERROR = "worklog: no worklog block found; first line must be --- worklog --- or --- worklog default=#label ---"

-- Context selection answers "which worklog block should this command use?"
-- The returned table keeps the original buffer lines, the selected block, and
-- the block body together so command code can stay focused on behavior.
local function build_context(lines, parsed, block)
  if not block then
    return nil
  end

  return {
    lines = lines,
    block = block,
    body_lines = blocks.get_body_lines(lines, block),
    default_label = parsed.default_label,
  }
end

function M.get_active_worklog_context(lines)
  local parsed = blocks.parse(lines)
  if parsed.error then
    return nil, parsed.error
  end

  local block = blocks.get_active_worklog(parsed)
  if not block then
    return nil, NO_WORKLOG_ERROR
  end

  return build_context(lines, parsed, block)
end

function M.get_worklog_context_at_row(lines, row)
  local parsed = blocks.parse(lines)
  if parsed.error then
    return nil, parsed.error
  end

  if #parsed == 0 then
    return nil, NO_WORKLOG_ERROR
  end

  local block = blocks.get_worklog_at_row(parsed, row)
  if not block then
    return nil, "worklog: current line is not inside a worklog block"
  end

  return build_context(lines, parsed, block)
end

return M
