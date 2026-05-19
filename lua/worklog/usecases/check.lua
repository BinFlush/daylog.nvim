local analyze = require("worklog.analyze")
local diagnostics = require("worklog.diagnostics")
local document = require("worklog.document")

local M = {}

-- Validate the current buffer without modifying it.

function M.run(lines)
  local analysis = analyze.analyze(document.parse(lines))
  local err = diagnostics.structural_or_missing_worklog_error(analysis)

  if err then
    return nil, err
  end

  for _, diagnostic in ipairs(analysis.diagnostics) do
    if diagnostic.code == "invalid_entry" or diagnostic.code == "unordered_timestamps" then
      return nil, diagnostics.message(diagnostic)
    end
  end

  return {
    message = "worklog: ok",
  }
end

return M
