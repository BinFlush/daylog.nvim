local analyze = require("daylog.analyze")
local diagnostics = require("daylog.diagnostics")
local document = require("daylog.document")

local M = {}

-- Daylog context selection.
--
-- Commands ask this module for the active log or the log under the
-- cursor. The returned context keeps the semantic analysis and the selected
-- block (whose header carries the sticky tag/location metadata).

local function build_context(analysis, block)
  if not block then
    return nil
  end

  return {
    analysis = analysis,
    block = block,
  }
end

local function analyze_lines(lines)
  local analysis = analyze.analyze(document.parse(lines))
  local err = analyze.structural_error(analysis)

  if err then
    return nil, err
  end

  return analysis, nil
end

function M.get_active_log_context(lines)
  local analysis, err = analyze_lines(lines)
  if err then
    return nil, err
  end

  local block = analyze.get_active_log(analysis)
  if not block then
    return nil, diagnostics.NO_LOG_ERROR
  end

  return build_context(analysis, block)
end

function M.get_log_context_at_row(lines, row)
  local analysis, err = analyze_lines(lines)
  if err then
    return nil, err
  end

  if #analysis.log_blocks == 0 then
    return nil, diagnostics.NO_LOG_ERROR
  end

  local block = analyze.get_log_at_row(analysis, row)
  if not block then
    return nil, "daylog: current line is not inside a log block"
  end

  return build_context(analysis, block)
end

return M
