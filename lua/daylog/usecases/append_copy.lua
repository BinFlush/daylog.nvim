local body = require("daylog.body")
local entry = require("daylog.entry")
local render = require("daylog.render")
local summary = require("daylog.summary")
local support = require("daylog.usecases.support")

local M = {}

-- Build the edit script appending a normalized copy of the active log plus its summary, so
-- the copy is self-describing from creation.

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
  -- Two blank lines separate body from summary (the canonical refresh layout), so render the
  -- summary content-only and prepend the pair.
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

  -- The canonical inter-log separator is two blanks. render.log_lines prepends one structural blank;
  -- drop it and own the whole seam here so it lands at exactly two -- topping up from the buffer's tail
  -- (append-only, never removing) rather than adding a third blank when the tail already has two.
  if rendered[1] == "" then
    table.remove(rendered, 1)
  end
  local blanks = math.max(0, 2 - support.trailing_blank_count(lines))
  for _ = 1, blanks do
    table.insert(rendered, 1, "")
  end

  -- Move the cursor onto the new copy (header after the separator blanks) so the window scrolls to it.
  local result = support.append_edit(lines, rendered)
  result.cursor = { #lines + blanks + 1, 0 }
  return result
end

return M
