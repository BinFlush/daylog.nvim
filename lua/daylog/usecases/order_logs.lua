local analyze = require("daylog.analyze")
local body = require("daylog.body")
local diagnostics = require("daylog.diagnostics")
local document = require("daylog.document")
local entry = require("daylog.entry")
local syntax = require("daylog.syntax")

local M = {}

-- Build the edit script for rewriting every log body in sorted order.
-- The use case preserves existing rendering rules while taking structural and
-- invalid-entry diagnostics from semantic analysis.

function M.run(lines)
  local analysis = analyze.analyze(document.parse(lines))
  local err = diagnostics.structural_or_missing_log_error(analysis)
  if err then
    return nil, err
  end

  local edits = {}
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

  local result = { edits = edits }
  if #warnings > 0 then
    result.warnings = warnings
  end

  return result
end

return M
