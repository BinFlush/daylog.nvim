local analyze = require("blotter.analyze")
local syntax = require("blotter.syntax")

local M = {}

local NO_WORKLOG_ERROR = "worklog: no worklog block found; first line must be a "
  .. "worklog header such as --- blots --- or "
  .. "--- blots #ClientA @office q=30 ---"

M.NO_WORKLOG_ERROR = NO_WORKLOG_ERROR

function M.invalid_entry_error(diagnostic)
  return string.format(
    "worklog: invalid worklog entry at line %d: %s",
    diagnostic.row,
    diagnostic.message
  )
end

function M.unordered_error(diagnostic)
  return string.format(
    "worklog: unordered timestamps near lines %d and %d; fix manually or run :BlotterOrder",
    diagnostic.row,
    diagnostic.row2
  )
end

function M.message(diagnostic)
  if diagnostic.code == syntax.DIAGNOSTIC.INVALID_ENTRY then
    return M.invalid_entry_error(diagnostic)
  end

  if diagnostic.code == syntax.DIAGNOSTIC.UNORDERED_TIMESTAMPS then
    return M.unordered_error(diagnostic)
  end

  -- Some diagnostic messages already carry the "worklog:" prefix; do not add a
  -- second one.
  if diagnostic.message:match("^worklog:") then
    return diagnostic.message
  end

  return "worklog: " .. diagnostic.message
end

-- True when the parsed document has any timestamped entry (valid or not). Lets us
-- flag a missing worklog header only when there is clearly worklog content, not
-- in an empty or prose-only buffer.
local function has_entry_node(parsed)
  for _, node in ipairs(parsed.nodes) do
    if node.kind == syntax.NODE_KIND.ENTRY or node.kind == syntax.NODE_KIND.INVALID_ENTRY then
      return true
    end
  end

  return false
end

M.has_entry_node = has_entry_node

-- Every problem that prevents a clean summary, as { row, message } entries:
-- whole-document structure (a bad first header, bad header options), one problem
-- per worklog block (out-of-order timestamps, an invalid entry, 24:00 not final),
-- and timestamped lines with no worklog header at all. Used by the live summary
-- refresh, which publishes them as buffer diagnostics.
function M.collect(analysis)
  local warnings = {}

  for _, diagnostic in ipairs(analysis.diagnostics) do
    if diagnostic.category == syntax.DIAGNOSTIC_CATEGORY.STRUCTURAL then
      table.insert(warnings, { row = diagnostic.row, message = M.message(diagnostic) })
    end
  end

  for _, block in ipairs(analysis.worklog_blocks) do
    local diagnostic = analyze.find_block_diagnostic(analysis, block)
    if diagnostic then
      table.insert(warnings, { row = diagnostic.row, message = M.message(diagnostic) })
    end
  end

  if #analysis.worklog_blocks == 0 and has_entry_node(analysis.document) then
    table.insert(warnings, { row = 1, message = NO_WORKLOG_ERROR })
  end

  return warnings
end

function M.structural_or_missing_worklog_error(analysis)
  local structural_error = analyze.structural_error(analysis)
  if structural_error then
    return structural_error
  end

  if #analysis.worklog_blocks == 0 then
    return NO_WORKLOG_ERROR
  end

  return nil
end

return M
