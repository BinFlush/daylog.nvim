local analyze = require("daylog.analyze")
local body = require("daylog.body")
local diagnostics = require("daylog.diagnostics")
local document = require("daylog.document")
local entry = require("daylog.entry")
local support = require("daylog.usecases.support")
local syntax = require("daylog.syntax")

local M = {}

-- Rewrite every log body in sorted order, then rebuild each log's existing summary from the
-- sorted bodies (the rule: a command that changes a log's entries rebuilds its summary; see
-- docs/architecture.md). A log with no summary is left alone (creation stays refresh's job).

function M.run(lines)
  local analysis = analyze.analyze(document.parse(lines))
  local err = diagnostics.structural_or_missing_log_error(analysis)
  if err then
    return nil, err
  end

  -- Body edits, highest block first so they stay valid as earlier ones change line counts.
  local body_edits = {}
  local warnings = {}

  for i = #analysis.log_blocks, 1, -1 do
    local block = analysis.log_blocks[i]
    local diagnostic = analyze.find_block_diagnostic(analysis, block)

    if diagnostic and diagnostic.code == syntax.DIAGNOSTIC.INVALID_ENTRY then
      return nil, diagnostics.invalid_entry_error(diagnostic)
    end

    if diagnostic and diagnostic.code == syntax.DIAGNOSTIC.UNORDERED_TIMESTAMPS then
      for _, changed in ipairs(body.sort_changes_metadata(block)) do
        table.insert(warnings, entry.minutes_string(changed.minutes) .. " " .. changed.text)
      end

      table.insert(body_edits, {
        start_index = block.body_start_row - 1,
        end_index = block.end_row - 1,
        lines = body.sorted_lines(block, entry.format),
      })
    else
      table.insert(body_edits, {
        start_index = block.body_start_row - 1,
        end_index = block.end_row - 1,
        lines = body.normalized_lines(block, entry.format),
      })
    end
  end

  -- Body edits change line counts, so rebuild summaries in post-reorder coordinates: apply body
  -- edits to a copy, re-analyze, blast each summary zone. The shell applies body edits before
  -- summary edits, keeping both coordinate systems valid.
  local work = support.apply_edits(lines, body_edits)
  local work_analysis = analyze.analyze(document.parse(work))

  local summary_edits = {}
  for _, block in ipairs(work_analysis.log_blocks) do
    local edit = support.summary_zone_edit(work_analysis, block, block.entries, false)
    if edit then
      summary_edits[#summary_edits + 1] = edit
    end
  end
  table.sort(summary_edits, function(a, b)
    return a.start_index > b.start_index
  end)

  local edits = {}
  for _, edit in ipairs(body_edits) do
    edits[#edits + 1] = edit
  end
  for _, edit in ipairs(summary_edits) do
    edits[#edits + 1] = edit
  end

  local result = { edits = edits }
  if #warnings > 0 then
    result.warnings = warnings
  end

  return result
end

return M
