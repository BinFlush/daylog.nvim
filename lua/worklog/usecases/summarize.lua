local render = require("worklog.render")
local summary = require("worklog.summary")
local summary_block = require("worklog.summary_block")
local support = require("worklog.usecases.support")

local M = {}

-- Build the edit script that sets the active worklog's single summary: replace
-- the existing summary in place, or append one when none exists. A worklog never
-- accumulates more than one summary.

function M.run(lines)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  local computed = summary.quantized_summarize_block(ctx.block)
  local region = summary_block.find(ctx.analysis, ctx.block)

  if region then
    local rendered =
      render.summary_lines(computed, ctx.block.duration_format, { leading_blank = false })

    return {
      edits = {
        {
          start_index = region.start_row - 1,
          end_index = region.end_row - 1,
          lines = rendered,
        },
      },
    }
  end

  return support.append_edit(lines, render.summary_lines(computed, ctx.block.duration_format))
end

return M
