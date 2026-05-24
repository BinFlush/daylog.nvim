local analyze = require("worklog.analyze")
local document = require("worklog.document")
local render = require("worklog.render")
local summary = require("worklog.summary")
local summary_block = require("worklog.summary_block")
local syntax = require("worklog.syntax")

local M = {}

-- Refresh every worklog's existing summary so it matches its entries.
--
-- This is the pure core of live-updating summaries. It never creates or removes a
-- summary; it only rewrites ones that already exist and have drifted from their
-- source, in their existing kind. Worklogs that are currently invalid (a
-- transient mid-edit state) and structurally broken documents are left
-- untouched, so editing never churns or corrupts the output. It returns no edits
-- for summaries that are already current, which keeps the shell's auto-refresh
-- idempotent and loop-free.

local function summarize_block(block, kind)
  if kind == syntax.REPORT_KIND.QUANTIZED then
    return summary.quantized_summarize_block(block)
  end

  return summary.summarize_block(block)
end

local function region_matches(lines, region, rendered)
  if (region.end_row - region.start_row) ~= #rendered then
    return false
  end

  for index, line in ipairs(rendered) do
    if lines[region.start_row + index - 1] ~= line then
      return false
    end
  end

  return true
end

function M.run(lines)
  local analysis = analyze.analyze(document.parse(lines))

  -- A structurally broken document (e.g. the first line is not a worklog header)
  -- is left entirely alone until it parses cleanly again.
  if analyze.structural_error(analysis) then
    return { edits = {} }
  end

  local edits = {}

  for _, block in ipairs(analysis.worklog_blocks) do
    local region = summary_block.find(analysis, block)

    -- Only refresh worklogs that already have a summary and are currently valid.
    if region and not analyze.find_block_diagnostic(analysis, block) then
      local computed = summarize_block(block, region.kind)
      local rendered = render.summary_lines(
        computed,
        region.kind,
        block.duration_format,
        { leading_blank = false }
      )

      if not region_matches(lines, region, rendered) then
        table.insert(edits, {
          start_index = region.start_row - 1,
          end_index = region.end_row - 1,
          lines = rendered,
        })
      end
    end
  end

  -- Apply highest-row-first so multiple region replacements do not shift each
  -- other's indices.
  table.sort(edits, function(a, b)
    return a.start_index > b.start_index
  end)

  return { edits = edits }
end

return M
