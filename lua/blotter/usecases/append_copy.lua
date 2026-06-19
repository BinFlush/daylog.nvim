local body = require("blotter.body")
local blot = require("blotter.blot")
local render = require("blotter.render")
local summary = require("blotter.summary")
local support = require("blotter.usecases.support")

local M = {}

-- Build the edit script for appending a normalized copy of the active blotter,
-- followed by its summary, so the copy is self-describing from the moment it is
-- created (matching how a freshly opened today file already carries a summary).

function M.run(lines)
  local ctx, err = support.get_validated_active(lines)

  if not ctx then
    return nil, err
  end

  local rendered = render.blotter_lines(
    body.normalized_lines(ctx.block, blot.format),
    ctx.block.header_tag,
    ctx.block.header_location,
    ctx.block.header_offset,
    ctx.block.header_quantize_minutes,
    ctx.block.header_duration_format
  )

  local computed = summary.summarize_block(ctx.block)
  local summary_lines = render.summary_lines(computed, ctx.block.duration_format, {
    quantize_minutes = ctx.block.quantize_minutes,
  })
  for _, line in ipairs(summary_lines) do
    table.insert(rendered, line)
  end

  return support.append_edit(lines, rendered)
end

return M
