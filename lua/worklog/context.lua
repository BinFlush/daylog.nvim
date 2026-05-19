local analyze = require("worklog.analyze")
local diagnostics = require("worklog.diagnostics")
local document = require("worklog.document")

local M = {}

-- Worklog context selection.
--
-- Commands ask this module for the active worklog or the worklog under the
-- cursor. The returned context keeps only the semantic analysis, selected
-- block, and the block's sticky header metadata.

local function build_context(analysis, block)
  if not block then
    return nil
  end

  return {
    analysis = analysis,
    block = block,
    header_tag = block.header_tag,
    header_location = block.header_location,
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

function M.get_active_worklog_context(lines)
  local analysis, err = analyze_lines(lines)
  if err then
    return nil, err
  end

  local block = analyze.get_active_worklog(analysis)
  if not block then
    return nil, diagnostics.NO_WORKLOG_ERROR
  end

  return build_context(analysis, block)
end

function M.get_worklog_context_at_row(lines, row)
  local analysis, err = analyze_lines(lines)
  if err then
    return nil, err
  end

  if #analysis.worklog_blocks == 0 then
    return nil, diagnostics.NO_WORKLOG_ERROR
  end

  local block = analyze.get_worklog_at_row(analysis, row)
  if not block then
    return nil, "worklog: current line is not inside a worklog block"
  end

  return build_context(analysis, block)
end

return M
