local analyze = require("worklog.analyze")
local document = require("worklog.document")
local support = require("worklog.usecases.support")

local M = {}

-- Validate the current buffer without modifying it.

function M.run(lines)
  local analysis = analyze.analyze(document.parse(lines))
  local err = support.structural_or_missing_worklog_error(analysis)

  if err then
    return nil, err
  end

  for _, diagnostic in ipairs(analysis.diagnostics) do
    if diagnostic.code == "invalid_entry" then
      return nil, support.invalid_entry_error(diagnostic)
    end

    if diagnostic.code == "unordered_timestamps" then
      return nil, support.unordered_error(diagnostic)
    end
  end

  return {
    message = "worklog: ok",
  }
end

return M
