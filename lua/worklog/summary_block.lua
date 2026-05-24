local syntax = require("worklog.syntax")

local M = {}

-- Locator for a worklog's generated summary region.
--
-- A worklog has at most one summary, either exact or quantized. This module
-- recognizes the generated section headers and reports where that single summary
-- lives so the summary usecases can replace it in place. It owns no presentation
-- or reporting logic; it only matches generated headers (built from the same
-- syntax constants render uses) against analyzed blocks.

-- Header of the leading `--- summary <kind> ---` block, mapped to its kind.
local SUMMARY_HEADER_KIND = {}
-- Per kind, the set of every generated subsection header in that summary group.
local SUBSECTION_HEADERS = {}

for _, kind in pairs(syntax.REPORT_KIND) do
  SUMMARY_HEADER_KIND[syntax.section_header(syntax.SECTION.SUMMARY, kind)] = kind
  SUBSECTION_HEADERS[kind] = {}

  for _, section in pairs(syntax.SECTION) do
    SUBSECTION_HEADERS[kind][syntax.section_header(section, kind)] = true
  end
end

local function header_line(block)
  return block.header and block.header.raw
end

-- Find the generated summary region for `worklog_block`: the run of generated
-- summary section blocks that follow it, up to the next worklog header or
-- end of buffer. Returns { start_row, end_row, kind } (rows 1-based, end_row
-- exclusive), or nil when the worklog has no summary.
function M.find(analysis, worklog_block)
  local start_index
  for index, block in ipairs(analysis.blocks) do
    if block == worklog_block then
      start_index = index
      break
    end
  end

  if not start_index then
    return nil
  end

  for index = start_index + 1, #analysis.blocks do
    local block = analysis.blocks[index]

    if block.kind == syntax.BLOCK_KIND.WORKLOG then
      break
    end

    local kind = SUMMARY_HEADER_KIND[header_line(block)]
    if kind then
      local end_row = block.end_row

      for next_index = index + 1, #analysis.blocks do
        local next_block = analysis.blocks[next_index]
        if SUBSECTION_HEADERS[kind][header_line(next_block)] then
          end_row = next_block.end_row
        else
          break
        end
      end

      -- Trim trailing blank lines (e.g. the separator before the next worklog)
      -- so the region covers only the generated summary content; the rendered
      -- summary never ends with a blank line.
      local nodes = analysis.document.nodes
      while
        end_row - 1 > block.start_row
        and nodes[end_row - 1]
        and nodes[end_row - 1].kind == syntax.NODE_KIND.BLANK_LINE
      do
        end_row = end_row - 1
      end

      return {
        start_row = block.start_row,
        end_row = end_row,
        kind = kind,
      }
    end
  end

  return nil
end

return M
