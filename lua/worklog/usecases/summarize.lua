local render = require("worklog.render")
local summary = require("worklog.summary")
local summary_block = require("worklog.summary_block")
local support = require("worklog.usecases.support")
local syntax = require("worklog.syntax")

local M = {}

-- Build the edit script that sets the active worklog's single summary to the
-- requested kind: replace the existing summary in place, or append one when none
-- exists. Switching kind (e.g. a quantized summary over an existing exact one) is
-- just a replace, so a worklog never accumulates more than one summary.

local function summarize_block(block, kind)
  if kind == syntax.REPORT_KIND.QUANTIZED then
    return summary.quantized_summarize_block(block)
  end

  return summary.summarize_block(block)
end

function M.run(lines, kind)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  local computed = summarize_block(ctx.block, kind)
  local region = summary_block.find(ctx.analysis, ctx.block)

  if region then
    local rendered =
      render.summary_lines(computed, kind, ctx.block.duration_format, { leading_blank = false })

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

  return support.append_edit(lines, render.summary_lines(computed, kind, ctx.block.duration_format))
end

return M
