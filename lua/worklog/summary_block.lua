local syntax = require("worklog.syntax")

local M = {}

-- Locator for a worklog's generated summary region.
--
-- A worklog has at most one summary. This module recognizes the generated section
-- headers (current kind-less form and legacy exact/quantized) and reports where
-- that single summary lives so the summary usecases can replace it in place. It
-- owns no presentation or reporting logic; it only matches generated headers
-- (built from the same syntax constants render uses) against analyzed blocks.

-- The subsection headers (tags/locations/logged/totals) that continue a summary
-- region: the current kind-less form plus the legacy "exact"/"quantized" forms.
local SUBSECTION_HEADERS = {}

for _, section in pairs(syntax.SECTION) do
  if section ~= syntax.SECTION.SUMMARY then
    SUBSECTION_HEADERS[syntax.section_header(section)] = true
  end
end

for _, kind in ipairs({ "exact", "quantized" }) do
  for _, section in pairs(syntax.SECTION) do
    if section ~= syntax.SECTION.SUMMARY then
      SUBSECTION_HEADERS["--- " .. section .. " " .. kind .. " ---"] = true
    end
  end
end

-- The line that begins a summary region: the current banner
-- "--- summary q=<n> d=<fmt> ---", plus the legacy kind-less and exact/quantized
-- forms (v0.1.0) -- recognized but never emitted, so an older file's summary is
-- still located and rewritten to the current form on the next refresh.
local LEGACY_SUMMARY_HEADERS = {
  [syntax.section_header(syntax.SECTION.SUMMARY)] = true,
  ["--- summary exact ---"] = true,
  ["--- summary quantized ---"] = true,
}

local function is_summary_header(line)
  return line ~= nil
    and (LEGACY_SUMMARY_HEADERS[line] or line:match("^%-%-%- summary q=%d+ d=%w+ %-%-%-$") ~= nil)
end

local function header_line(block)
  return block.header and block.header.raw
end

-- Find the generated summary region for `worklog_block`: the run of generated
-- summary section blocks that follow it, up to the next worklog header or
-- end of buffer. Returns { start_row, end_row } (rows 1-based, end_row
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

    if is_summary_header(header_line(block)) then
      local end_row = block.end_row

      for next_index = index + 1, #analysis.blocks do
        local next_block = analysis.blocks[next_index]
        if SUBSECTION_HEADERS[header_line(next_block)] then
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
      }
    end
  end

  return nil
end

return M
