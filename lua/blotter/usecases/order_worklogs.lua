local analyze = require("blotter.analyze")
local body = require("blotter.body")
local diagnostics = require("blotter.diagnostics")
local document = require("blotter.document")
local blot = require("blotter.blot")
local syntax = require("blotter.syntax")

local M = {}

-- Build the edit script for rewriting every worklog body in sorted order.
-- The use case preserves existing rendering rules while taking structural and
-- invalid-blot diagnostics from semantic analysis.

function M.run(lines)
  local analysis = analyze.analyze(document.parse(lines))
  local err = diagnostics.structural_or_missing_worklog_error(analysis)
  if err then
    return nil, err
  end

  local edits = {}
  local warnings = {}

  for i = #analysis.worklog_blocks, 1, -1 do
    local block = analysis.worklog_blocks[i]
    local diagnostic = analyze.find_block_diagnostic(analysis, block)

    if diagnostic and diagnostic.code == syntax.DIAGNOSTIC.INVALID_ENTRY then
      return nil, diagnostics.invalid_entry_error(diagnostic)
    end

    if diagnostic and diagnostic.code == syntax.DIAGNOSTIC.UNORDERED_TIMESTAMPS then
      for _, changed in ipairs(body.sort_changes_metadata(block)) do
        table.insert(warnings, blot.minutes_string(changed.minutes) .. " " .. changed.text)
      end

      table.insert(edits, {
        start_index = block.body_start_row - 1,
        end_index = block.end_row - 1,
        lines = body.sorted_lines(block, blot.format),
      })
    else
      table.insert(edits, {
        start_index = block.body_start_row - 1,
        end_index = block.end_row - 1,
        lines = body.normalized_lines(block, blot.format),
      })
    end
  end

  local result = { edits = edits }
  if #warnings > 0 then
    result.warnings = warnings
  end

  return result
end

return M
