local body = require("daylog.body")
local entry = require("daylog.entry")
local render = require("daylog.render")
local summary = require("daylog.summary")
local support = require("daylog.usecases.support")

local M = {}

-- Build the edit script for appending a normalized copy of the active log,
-- followed by its summary, so the copy is self-describing from the moment it is
-- created (matching how a freshly opened today file already carries a summary).

function M.run(lines)
  local ctx, err = support.get_validated_active(lines)

  if not ctx then
    return nil, err
  end

  local rendered = render.log_lines(
    body.normalized_lines(ctx.block, entry.format),
    ctx.block.header_tag,
    ctx.block.header_location,
    ctx.block.header_offset,
    ctx.block.header_quantize_minutes,
    ctx.block.header_duration_format
  )

  local computed = summary.summarize_block(ctx.block)
  -- Two blank lines separate the body from its generated summary (the canonical
  -- layout the refresh blast emits), so render the summary content-only and prepend
  -- the pair rather than relying on the render's single leading blank.
  local summary_lines = render.summary_lines(
    computed,
    ctx.block.duration_format,
    support.summary_render_options(ctx.block)
  )
  table.insert(rendered, "")
  table.insert(rendered, "")
  for _, line in ipairs(summary_lines) do
    table.insert(rendered, line)
  end

  -- Move the cursor onto the new copy so the window scrolls to it and it is visibly
  -- clear something happened. `render.log_lines` emits a leading blank then the header,
  -- appended at `#lines`, so the new log header sits at `#lines + 2`.
  local result = support.append_edit(lines, rendered)
  result.cursor = { #lines + 2, 0 }
  return result
end

return M
