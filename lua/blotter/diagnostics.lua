local analyze = require("blotter.analyze")
local syntax = require("blotter.syntax")

local M = {}

local NO_BLOTTER_ERROR = "blotter: no blotter block found; first line must be a "
  .. "blotter header such as --- blots --- or "
  .. "--- blots #ClientA @office q=30 ---"

M.NO_BLOTTER_ERROR = NO_BLOTTER_ERROR

function M.invalid_blot_error(diagnostic)
  return string.format("blotter: invalid blot at line %d: %s", diagnostic.row, diagnostic.message)
end

function M.unordered_error(diagnostic)
  return string.format(
    "blotter: unordered timestamps near lines %d and %d; fix manually or run :BlotterOrder",
    diagnostic.row,
    diagnostic.row2
  )
end

function M.message(diagnostic)
  if diagnostic.code == syntax.DIAGNOSTIC.INVALID_BLOT then
    return M.invalid_blot_error(diagnostic)
  end

  if diagnostic.code == syntax.DIAGNOSTIC.UNORDERED_TIMESTAMPS then
    return M.unordered_error(diagnostic)
  end

  -- Some diagnostic messages already carry the "blotter:" prefix; do not add a
  -- second one.
  if diagnostic.message:match("^blotter:") then
    return diagnostic.message
  end

  return "blotter: " .. diagnostic.message
end

-- True when the parsed document has any timestamped blot (valid or not). Lets us
-- flag a missing blotter header only when there is clearly blotter content, not
-- in an empty or prose-only buffer.
local function has_blot_node(parsed)
  for _, node in ipairs(parsed.nodes) do
    if node.kind == syntax.NODE_KIND.BLOT or node.kind == syntax.NODE_KIND.INVALID_BLOT then
      return true
    end
  end

  return false
end

M.has_blot_node = has_blot_node

-- Every problem that prevents a clean summary, as { row, message } blots:
-- whole-document structure (a bad first header, bad header options), one problem
-- per blotter block (out-of-order timestamps, an invalid blot, 24:00 not final),
-- and timestamped lines with no blotter header at all. Used by the live summary
-- refresh, which publishes them as buffer diagnostics.
function M.collect(analysis)
  local warnings = {}

  for _, diagnostic in ipairs(analysis.diagnostics) do
    if diagnostic.category == syntax.DIAGNOSTIC_CATEGORY.STRUCTURAL then
      table.insert(warnings, { row = diagnostic.row, message = M.message(diagnostic) })
    end
  end

  for _, block in ipairs(analysis.blotter_blocks) do
    local diagnostic = analyze.find_block_diagnostic(analysis, block)
    if diagnostic then
      table.insert(warnings, { row = diagnostic.row, message = M.message(diagnostic) })
    end
  end

  if #analysis.blotter_blocks == 0 and has_blot_node(analysis.document) then
    table.insert(warnings, { row = 1, message = NO_BLOTTER_ERROR })
  end

  return warnings
end

function M.structural_or_missing_blotter_error(analysis)
  local structural_error = analyze.structural_error(analysis)
  if structural_error then
    return structural_error
  end

  if #analysis.blotter_blocks == 0 then
    return NO_BLOTTER_ERROR
  end

  return nil
end

return M
