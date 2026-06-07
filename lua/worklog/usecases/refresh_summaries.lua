local analyze = require("worklog.analyze")
local diagnostics = require("worklog.diagnostics")
local document = require("worklog.document")
local render = require("worklog.render")
local summary = require("worklog.summary")
local summary_block = require("worklog.summary_block")

local M = {}

-- Refresh every worklog's existing summary so it matches its entries, and report
-- the problems that stop a worklog from being summarized.
--
-- Edits are conservative: a summary is only rewritten when it already exists, is
-- valid, and has drifted from its source. A structurally
-- broken document and currently-invalid worklogs are never rewritten, so editing
-- cannot churn or corrupt output, and an already-current summary yields no edit
-- (which keeps the shell's auto-refresh idempotent and loop-free).
--
-- Warnings are not conservative: an unrefreshed summary is otherwise a silent
-- stall, so run also returns `warnings` for every problem the analyzer can see --
-- a broken or absent header, out-of-order timestamps, an invalid entry, 24:00 not
-- final -- whether or not a summary exists yet. Each warning is { row, message };
-- the shell publishes them as buffer diagnostics so they clear when fixed.

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
  local warnings = diagnostics.collect(analysis)
  local edits = {}

  -- A structurally broken document is never rewritten (so editing cannot churn
  -- or corrupt output) until it parses cleanly again; its problems still warn
  -- via diagnostics.collect above.
  if not analyze.structural_error(analysis) then
    for _, block in ipairs(analysis.worklog_blocks) do
      -- Only refresh a worklog that is valid and already has a summary.
      if not analyze.find_block_diagnostic(analysis, block) then
        local region = summary_block.find(analysis, block)

        if region then
          local computed = summary.quantized_summarize_block(block)
          local rendered =
            render.summary_lines(computed, block.duration_format, { leading_blank = false })

          if not region_matches(lines, region, rendered) then
            table.insert(edits, {
              start_index = region.start_row - 1,
              end_index = region.end_row - 1,
              lines = rendered,
            })
          end
        end
      end
    end

    -- Apply highest-row-first so multiple region replacements do not shift each
    -- other's indices.
    table.sort(edits, function(a, b)
      return a.start_index > b.start_index
    end)
  end

  return { edits = edits, warnings = warnings }
end

return M
