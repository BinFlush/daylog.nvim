local analyze = require("worklog.analyze")
local diagnostics = require("worklog.diagnostics")
local document = require("worklog.document")

local M = {}

-- Validate the current buffer without modifying it. Returns the full set of
-- problems as { row, message } warnings (so the shell can publish them as inline
-- diagnostics) plus a one-line summary for a transient message.

function M.run(lines)
  local analysis = analyze.analyze(document.parse(lines))
  local warnings = diagnostics.collect(analysis)

  local ok = #analysis.worklog_blocks > 0 and #warnings == 0

  local summary
  if #analysis.worklog_blocks == 0 then
    summary = diagnostics.NO_WORKLOG_ERROR
  elseif ok then
    summary = "worklog: ok"
  else
    summary = string.format(
      "worklog: %d problem%s; see diagnostics",
      #warnings,
      #warnings == 1 and "" or "s"
    )
  end

  return { warnings = warnings, summary = summary, ok = ok }
end

return M
