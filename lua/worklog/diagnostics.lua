local analyze = require("worklog.analyze")
local syntax = require("worklog.syntax")

local M = {}

local NO_WORKLOG_ERROR = "worklog: no worklog block found; first line must be a "
  .. "worklog header such as --- worklog --- or "
  .. "--- worklog #ClientA @office quantize=30 ---"

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
    "worklog: unordered timestamps near lines %d and %d; fix manually or run :WorklogOrder",
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

  return "worklog: " .. diagnostic.message
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
