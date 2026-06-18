local body = require("worklog.body")
local entry = require("worklog.entry")
local render = require("worklog.render")
local summary = require("worklog.summary")
local support = require("worklog.usecases.support")

local M = {}

-- Build the edit script for appending a normalized copy of the active worklog,
-- followed by its summary, so the copy is self-describing from the moment it is
-- created (matching how a freshly opened today file already carries a summary).

function M.run(lines)
  local ctx, err = support.get_validated_active(lines)

  if not ctx then
    return nil, err
  end

  local rendered = render.worklog_lines(
    body.normalized_lines(ctx.block, entry.format),
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
