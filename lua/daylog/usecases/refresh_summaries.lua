local analyze = require("daylog.analyze")
local diagnostics = require("daylog.diagnostics")
local document = require("daylog.document")
local recover_headers = require("daylog.usecases.recover_headers")
local summary = require("daylog.summary")
local support = require("daylog.usecases.support")

local M = {}

-- Refresh every valid log's summary so it matches its entries -- creating one
-- where missing -- and report the problems that stop a log from being summarized.
--
-- Edits are conservative: a valid log's summary is created when missing and
-- rewritten when it exists but has drifted from its source; it is never removed. A
-- structurally broken document and currently-invalid logs are left untouched,
-- so editing cannot churn or corrupt output, and an already-current summary yields
-- no edit (which keeps the shell's auto-refresh idempotent and loop-free).
--
-- Warnings are not conservative: an unrefreshed summary is otherwise a silent
-- stall, so run also returns `warnings` for every problem the analyzer can see --
-- a broken or absent header, out-of-order timestamps, an invalid entry, 24:00 not
-- final -- whether or not a summary exists yet. Each warning is { row, message };
-- the shell publishes them as buffer diagnostics so they clear when fixed.

-- A frozen `!L<minutes>` value records what was committed externally, and the
-- quantizer holds the row there. That stays honest only while the value still fits a
-- bucket: it must be a non-negative multiple of the block's q. A q change or an edit
-- inside a logged interval can leave it off-grid; warn so the user re-runs :Daylog log
-- to recommit. (There is no "exceeds the log's total" failure: the un-frozen rows round
-- to their OWN total around the commitments, so frozen values never share a budget.) The
-- summary still renders around the stale value; this only surfaces the drift.
local function frozen_drift_warnings(block)
  local rows, bucket_minutes = summary.fine_grained_quantized(block.entries, block.quantize_minutes)

  local warnings = {}
  for _, row in ipairs(rows) do
    if row.logged_minutes ~= nil then
      if row.logged_minutes < 0 or row.logged_minutes % bucket_minutes ~= 0 then
        local at = row.source_entry_rows and row.source_entry_rows[1]
        if at then
          warnings[#warnings + 1] = {
            row = at,
            message = string.format(
              "daylog: a frozen !L value no longer fits q=%d; re-run :Daylog log to recommit",
              bucket_minutes
            ),
          }
        end
      end
    end
  end

  return warnings
end

-- A manual `round±N` marker is honest only while the row can absorb it. A round-down can be
-- demanded past what the row holds -- typed too large by hand, or left stale by an edit that
-- shrank the activity -- which would carry the displayed duration below zero. The quantizer
-- clamps the display to 0 and records `nudge_below_zero`; surface that as a diagnostic so the
-- out-of-range marker is corrected rather than silently honored. The summary still renders
-- (clamped), mirroring the frozen-drift surfacing above.
local function nudge_range_warnings(block)
  local rows = summary.fine_grained_quantized(block.entries, block.quantize_minutes)

  local warnings = {}
  for _, row in ipairs(rows) do
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

  -- A structurally broken document is never rewritten (so editing cannot churn or
  -- corrupt output) until it parses cleanly again; its problems still warn.
  if analyze.structural_error(analysis) then
    return { edits = {}, warnings = diagnostics.collect(analysis) }
  end

  -- Recover corrupted/missing log headers first, on a working copy, then re-analyze
  -- so the recovered logs are summarized in this same pass (keeping refresh
  -- idempotent). Recovery edits are applied highest-row-first; a synthesized header is an
  -- insertion, so the summary edits are computed in the WORKING copy's coordinates and
  -- emitted after all recovery edits (the shell applies the list in order).
  local recover_edits = recover_headers.edits(analysis)
  table.sort(recover_edits, function(a, b)
    return a.start_index > b.start_index
  end)
  local work_analysis = analysis
  if #recover_edits > 0 then
    local work = support.apply_edits(lines, recover_edits)
    work_analysis = analyze.analyze(document.parse(work))
  end

  local warnings = diagnostics.collect(work_analysis)
  local summary_edits = {}

  for _, block in ipairs(work_analysis.log_blocks) do
    -- For a valid daylog: blast-regenerate its whole summary zone, or create one when
    -- missing. The summary is entirely generated, so the located zone is discarded
    -- wholesale and rewritten -- nothing inside it is authored -- while the body above
    -- the boundary is left untouched.
    if not analyze.find_block_diagnostic(work_analysis, block) then
      for _, warning in ipairs(frozen_drift_warnings(block)) do
        warnings[#warnings + 1] = warning
      end

      for _, warning in ipairs(nudge_range_warnings(block)) do
        warnings[#warnings + 1] = warning
      end

      for _, conflict in ipairs(summary.logged_value_conflicts(block.entries)) do
        warnings[#warnings + 1] = {
          row = conflict.row,
          message = "daylog: logged entries for this activity disagree on their "
            .. "!L value; re-run :Daylog log to recommit",
        }
      end

      -- Rebuild this valid log's summary from its entries -- creating one when missing --
      -- through the one canonical zone writer. An already-canonical zone yields no edit.
      local edit = support.summary_zone_edit(work_analysis, block, block.entries, true)
      if edit then
        table.insert(summary_edits, edit)
      end
    end
  end

  table.sort(summary_edits, function(a, b)
    return a.start_index > b.start_index
  end)

  -- Recovery edits transform `lines` -> `work`; the summary edits are in `work`
  -- coordinates. The shell applies the list in order, so every recovery (which may insert
  -- a line) runs before any summary edit, keeping both coordinate systems valid.
  local edits = {}
  for _, edit in ipairs(recover_edits) do
    edits[#edits + 1] = edit
  end
  for _, edit in ipairs(summary_edits) do
    edits[#edits + 1] = edit
  end

  return { edits = edits, warnings = warnings }
end

return M
