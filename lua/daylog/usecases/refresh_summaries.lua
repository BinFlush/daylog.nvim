local analyze = require("daylog.analyze")
local diagnostics = require("daylog.diagnostics")
local document = require("daylog.document")
local recover_headers = require("daylog.usecases.recover_headers")
local summary = require("daylog.summary")
local support = require("daylog.usecases.support")

local M = {}

-- Refresh every valid log's summary to match its entries (creating one where missing) and report the
-- problems that stop a log from being summarized. PURE. Edits are conservative: a summary is created or
-- rewritten but never removed, a broken document and invalid logs are left untouched, and an
-- already-current summary yields no edit (keeping the shell's auto-refresh idempotent and loop-free).
-- Warnings are not: run returns `warnings` ({ row, message }) for every analyzer-visible problem
-- whether or not a summary exists, since an unrefreshed summary is otherwise a silent stall.

-- A round-down `round±N` can be demanded past what the row holds; the quantizer clamps the display to 0
-- and records `nudge_below_zero`, surfaced here so the out-of-range marker is corrected not silently
-- honored (the summary still renders clamped).
local function nudge_range_warnings(block)
  -- Judge on the rows the displayed summary shows, so warning and row agree on the clamp.
  local warnings = {}
  for _, row in ipairs(summary.summarize_block(block).summary_items) do
    if row.nudge_below_zero then
      local at = row.source_entry_rows and row.source_entry_rows[1]
      if at then
        warnings[#warnings + 1] = {
          row = at,
          message = string.format(
            "daylog: round%+d rounds this item below zero; clear or reduce the nudge",
            row.nudge
          ),
        }
      end
    end
  end

  return warnings
end

function M.run(lines)
  local analysis = analyze.analyze(document.parse(lines))

  -- A structurally broken document is never rewritten until it parses cleanly; its problems still warn.
  if analyze.structural_error(analysis) then
    return { edits = {}, warnings = diagnostics.collect(analysis) }
  end

  -- Recover corrupted/missing headers on a working copy, then re-analyze so the recovered logs are
  -- summarized in the same pass; the summary edits (in the recovered copy's coordinates) are emitted
  -- after the recovery edits.
  local recover_edits = recover_headers.edits(analysis)
  local work_analysis = support.reanalyze_after(lines, analysis, recover_edits)

  local warnings = diagnostics.collect(work_analysis)
  local summary_edits = {}
  for _, block in ipairs(work_analysis.log_blocks) do
    -- The summary is entirely generated, so a valid log's whole zone is discarded and rewritten (or
    -- created when missing) while the body above the boundary is left untouched.
    if not analyze.find_block_diagnostic(work_analysis, block) then
      for _, warning in ipairs(nudge_range_warnings(block)) do
        warnings[#warnings + 1] = warning
      end
      -- Rebuild through the one canonical zone writer; an already-canonical zone yields no edit.
      local edit = support.summary_zone_edit(work_analysis, block, block.entries, true)
      if edit then
        table.insert(summary_edits, edit)
      end
    end
  end

  return { edits = support.ordered_rebuild_edits(recover_edits, summary_edits), warnings = warnings }
end

return M
