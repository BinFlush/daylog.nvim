local analyze = require("worklog.analyze")
local document = require("worklog.document")
local syntax = require("worklog.syntax")

local M = {}

-- Parser-driven highlight spans (PURE).
--
-- This is the single source of highlighting truth. document.lua / analyze.lua
-- classify the buffer, and this module turns that classification into highlight
-- spans; the shell applies them as extmarks. There is no separate regex grammar
-- to keep in sync: worklog headers, entries, and trailing metadata are
-- highlighted from the very parse the plugin reads a file with (token kinds come
-- from document.classify_control_token), and summary rows -- which are derived
-- output, not source -- are recognized by the shapes render.lua produces.
--
-- A span is { line, col_start, col_end, group, priority }: 0-based byte columns,
-- end exclusive, matching the extmark API. Whole-line "base" spans (a worklog
-- header, a block header, a note) use a lower priority than the narrower token
-- spans layered over them, so e.g. a #tag inside a header wins at its own cells.

-- Highlight groups and the default highlight they link to. Exposed as data so the
-- shell registers them once; the names match the previous syntax file, so any
-- user `highlight` overrides keep working unchanged.
M.GROUPS = {
  WorklogHeader = "Title",
  WorklogBlockHeader = "Comment",
  WorklogTimestamp = "Statement",
  WorklogTag = "Identifier",
  WorklogOoo = "WarningMsg",
  WorklogLocation = "Function",
  WorklogLogged = "Special",
  WorklogDuration = "Special",
  WorklogQuantError = "Comment",
  WorklogOption = "PreProc",
  WorklogNote = "Comment",
}

local BASE_PRIORITY = 100
local TOKEN_PRIORITY = 110

-- The timestamp is always a zero-padded HH:MM (5 bytes); 24:00 included.
local TIMESTAMP_WIDTH = 5

local SECTION_WORDS = {
  [syntax.SECTION.SUMMARY] = true,
  [syntax.SECTION.TAGS] = true,
  [syntax.SECTION.LOCATIONS] = true,
  [syntax.SECTION.LOGGED] = true,
  [syntax.SECTION.TOTALS] = true,
}

-- Header-token diagnostics that make a worklog header invalid (so it renders as a
-- plain block header with no token highlighting), as opposed to INVALID_FIRST_HEADER,
-- which is about document position, not the header line's own validity.
local HEADER_TOKEN_DIAGNOSTICS = {
  [syntax.DIAGNOSTIC.INVALID_WORKLOG_HEADER_OPTION] = true,
  [syntax.DIAGNOSTIC.INVALID_WORKLOG_HEADER_METADATA] = true,
  [syntax.DIAGNOSTIC.INVALID_WORKLOG_HEADER_TOKEN] = true,
}

-- A generated summary-section header, in-file (`--- summary q=.. d=.. ---`,
-- `--- tags ---`, ...) or in a report (`--- day summary <label> ---`,
-- `--- week totals <label> ---`, ...). Recognized by a section word appearing as
-- the first or second word -- exactly the shapes render.lua emits.
local function is_summary_section_header(raw)
  local content = raw:match("^%-%-%- (.+) %-%-%-$")
  if not content then
    return false
  end

  local first, second = content:match("^(%S+)%s*(%S*)")
  return SECTION_WORDS[first] == true or SECTION_WORDS[second] == true
end

-- The worklog header rows the analyzer flagged for bad tokens (so the highlighter
-- demotes them to a block header).
local function invalid_header_rows(analysis)
  local rows = {}
  for _, diagnostic in ipairs(analysis.diagnostics) do
    if HEADER_TOKEN_DIAGNOSTICS[diagnostic.code] then
      rows[diagnostic.row] = true
    end
  end
  return rows
end

-- The rows that sit inside a generated summary section. A section runs from its
-- header to the blank line that ends it (or the next header / EOF), mirroring the
-- rendered layout, so free notes written after a summary are not swept in.
local function summary_section_rows(analysis)
  local nodes = analysis.document.nodes
  local in_summary = {}

  for _, block in ipairs(analysis.blocks) do
    if block.kind == syntax.BLOCK_KIND.GENERIC and is_summary_section_header(block.header.raw) then
      for row = block.body_start_row, block.end_row - 1 do
        if nodes[row].kind == syntax.NODE_KIND.BLANK_LINE then
          break
        end
        in_summary[row] = true
      end
    end
  end

  return in_summary
end

-- The whitespace-delimited tokens of a line with 0-based byte spans.
local function tokens_with_spans(line)
  local tokens = {}
  for start, text in line:gmatch("()(%S+)") do
    tokens[#tokens + 1] = { start = start - 1, stop = start - 1 + #text, text = text }
  end
  return tokens
end

-- The highlight group for a trailing-metadata / header token (a #tag, @location,
-- clear, or !L), or nil when the token is not metadata. #ooo is distinguished.
local function control_group(token)
  local kind, value = document.classify_control_token(token)
  if kind == syntax.TOKEN_KIND.TAG then
    if value == syntax.OUT_OF_OFFICE_TAG then
      return "WorklogOoo"
    end
    return "WorklogTag"
  elseif kind == syntax.TOKEN_KIND.LOCATION then
    return "WorklogLocation"
  elseif kind == syntax.TOKEN_KIND.LOGGED then
    return "WorklogLogged"
  end
  return nil
end

local function push(spans, line, col_start, col_end, group, priority)
  spans[#spans + 1] = {
    line = line,
    col_start = col_start,
    col_end = col_end,
    group = group,
    priority = priority,
  }
end

-- Highlight the trailing run of metadata tokens (#tag / @location / !L, any order,
-- each kind at most once) that the parser would peel off the end of a line. Shared
-- by entries and summary rows. A run that the parser rejects is never reached: the
-- caller only invokes this for valid entries and for summary rows.
local function push_trailing_metadata(spans, row, line)
  local tokens = tokens_with_spans(line)

  local first = #tokens + 1
  for i = #tokens, 1, -1 do
    if control_group(tokens[i].text) then
      first = i
    else
      break
    end
  end

  for i = first, #tokens do
    push(spans, row, tokens[i].start, tokens[i].stop, control_group(tokens[i].text), TOKEN_PRIORITY)
  end
end

-- Every (+Nm) / (-Nm) rounding marker on the line.
local function push_quant_errors(spans, row, line)
  for start, text in line:gmatch("()(%([%+%-]%d+m%))") do
    push(spans, row, start - 1, start - 1 + #text, "WorklogQuantError", TOKEN_PRIORITY)
  end
end

-- The byte length of a leading duration: decimal "2.00h" or hh:mm "16:00"/"2:00".
local function leading_duration_length(line)
  local decimal = line:match("^%d+%.%d+h")
  if decimal then
    return #decimal
  end

  local hhmm = line:match("^%d+:%d%d")
  return hhmm and #hhmm or nil
end

-- A row inside a summary section: a leading duration, its rounding marker(s), and
-- any trailing #tag / @location the row still carries (e.g. a disambiguated row).
local function push_summary_row(spans, row, line)
  local duration = leading_duration_length(line)
  if duration then
    push(spans, row, 0, duration, "WorklogDuration", TOKEN_PRIORITY)
  end
  push_quant_errors(spans, row, line)
  push_trailing_metadata(spans, row, line)
end

-- A free note. A summary row that has leaked outside a section (a decimal
-- duration, a single-digit-hour hh:mm that can never be an entry, or any hh:mm
-- directly before a (+Nm) marker) still gets its duration/marker highlighted over
-- the note base, matching how such rows read inside a section.
local function push_note(spans, row, line)
  push(spans, row, 0, #line, "WorklogNote", BASE_PRIORITY)

  local decimal = line:match("^%d+%.%d+h")
  local hhmm = line:match("^%d+:%d%d")
  if decimal then
    push(spans, row, 0, #decimal, "WorklogDuration", TOKEN_PRIORITY)
  elseif hhmm and (line:match("^%d:%d%d") or line:match("^%d+:%d%d%s+%([%+%-]%d+m%)")) then
    push(spans, row, 0, #hhmm, "WorklogDuration", TOKEN_PRIORITY)
  end

  push_quant_errors(spans, row, line)
end

local function push_worklog_header(spans, row, line)
  push(spans, row, 0, #line, "WorklogHeader", BASE_PRIORITY)

  for _, token in ipairs(tokens_with_spans(line)) do
    local group = control_group(token.text)
    if not group and token.text:match("^[%w_%-]+=") then
      group = "WorklogOption"
    end
    if group then
      push(spans, row, token.start, token.stop, group, TOKEN_PRIORITY)
    end
  end
end

-- Compute the highlight spans for a worklog buffer's lines.
function M.spans(lines)
  local parsed = document.parse(lines)
  local analysis = analyze.analyze(parsed)
  local in_summary = summary_section_rows(analysis)
  local invalid_headers = invalid_header_rows(analysis)
  local spans = {}

  for row, line in ipairs(lines) do
    if line ~= "" then
      local kind = parsed.nodes[row].kind

      if kind == syntax.NODE_KIND.WORKLOG_HEADER and not invalid_headers[row] then
        push_worklog_header(spans, row - 1, line)
      elseif kind == syntax.NODE_KIND.WORKLOG_HEADER or kind == syntax.NODE_KIND.BLOCK_HEADER then
        push(spans, row - 1, 0, #line, "WorklogBlockHeader", BASE_PRIORITY)
      elseif in_summary[row] then
        push_summary_row(spans, row - 1, line)
      elseif kind == syntax.NODE_KIND.ENTRY then
        push(spans, row - 1, 0, TIMESTAMP_WIDTH, "WorklogTimestamp", TOKEN_PRIORITY)
        push_trailing_metadata(spans, row - 1, line)
      else
        -- A NOTE_LINE, or an INVALID_ENTRY whose time the parser rejected (so it is
        -- not a timestamp): a free note, with any leaked duration shape highlighted.
        push_note(spans, row - 1, line)
      end
    end
  end

  return spans
end

return M
