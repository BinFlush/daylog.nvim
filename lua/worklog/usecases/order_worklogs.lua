local analyze = require("worklog.analyze")
local body = require("worklog.body")
local diagnostics = require("worklog.diagnostics")
local document = require("worklog.document")
local entry = require("worklog.entry")
local syntax = require("worklog.syntax")

local M = {}

-- Build the edit script for rewriting every worklog body in sorted order.
-- The use case preserves existing rendering rules while taking structural and
-- invalid-entry diagnostics from semantic analysis.

function M.run(lines)
  local analysis = analyze.analyze(document.parse(lines))
  local err = diagnostics.structural_or_missing_worklog_error(analysis)
  if err then
    return nil, err
  end

  local edits = {}

  for i = #analysis.worklog_blocks, 1, -1 do
    local block = analysis.worklog_blocks[i]
    local diagnostic = analyze.find_block_diagnostic(analysis, block)

    if diagnostic and diagnostic.code == syntax.DIAGNOSTIC.INVALID_ENTRY then
      return nil, diagnostics.invalid_entry_error(diagnostic)
    end

    if diagnostic and diagnostic.code == syntax.DIAGNOSTIC.UNORDERED_TIMESTAMPS then
      table.insert(edits, {
        start_index = block.body_start_row - 1,
        end_index = block.end_row - 1,
        lines = body.sorted_lines(block, entry.format),
      })
    else
      table.insert(edits, {
        start_index = block.body_start_row - 1,
        end_index = block.end_row - 1,
        lines = body.normalized_lines(block, entry.format),
      })
    end
  end

  return {
    edits = edits,
  }
end

return M
