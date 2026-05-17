local render = require("worklog.render")
local summary = require("worklog.summary")
local support = require("worklog.usecases.support")

local M = {}

-- Build the edit script for appending an exact summary of the active worklog.

function M.run(lines)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  local rendered =
    render.summary_lines(summary.summarize_block(ctx.block), "exact", ctx.block.duration_format)
  return support.append_edit(lines, rendered)
end

return M
