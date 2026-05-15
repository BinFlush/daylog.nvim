local body = require("worklog.body")
local entry = require("worklog.entry")
local render = require("worklog.render")
local support = require("worklog.usecases.support")

local M = {}

-- Build the edit script for appending a normalized copy of the active worklog.

function M.run(lines)
  local ctx, err = support.get_validated_active(lines)
  local normalized = nil

  if not ctx then
    return nil, err
  end

  normalized, err = body.normalized_lines(ctx.block, entry.format)
  if not normalized then
    return nil, err
  end

  local rendered = render.worklog_lines(
    normalized,
    ctx.block.header_tag,
    ctx.block.header_location
  )
  return support.append_edit(lines, rendered)
end

return M
