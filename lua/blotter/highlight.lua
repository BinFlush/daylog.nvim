local analyze = require("blotter.analyze")
local document = require("blotter.document")
local syntax = require("blotter.syntax")

local M = {}

-- Parser-driven highlight spans (PURE).
--
-- This module owns no grammar of its own: it maps the parse into highlight spans
-- and nothing more. Every recognition decision comes from the parser layer --
-- node kinds and token spans from document.lua (document.tokens,
-- document.classify_control_token, document.quant_error_spans,
-- document.summary_duration_length, document.is_option_token), header validity and
-- summary-section context from analyze.lua, and the section-header predicate from
-- syntax.lua. There are no patterns here, so there is a single source of truth for
-- what a token is; this file only decides which highlight group each token gets.
--
-- A span is { line, col_start, col_end, group, priority }: 0-based byte columns,
-- end exclusive, matching the extmark API. Whole-line "base" spans (a worklog
-- header, a block header, a note) use a lower priority than the narrower token
-- spans layered over them, so e.g. a #tag inside a header wins at its own cells.

-- Highlight groups and the default highlight they link to. Exposed as data so the
-- shell registers them once; the names match the previous syntax file, so any
-- user `highlight` overrides keep working unchanged.
-- Inline metadata tokens link to bright, mutually distinct standard groups (not
-- Comment): a #tag is cyan-ish (Identifier), an @location blue-ish (Function), a
-- utc±H offset green-ish (Type), a round±N nudge red/orange-ish (Constant), and !L
-- orange-ish (Special). Only genuinely secondary text -- the (+Nm) rounding residual,
-- free notes, and block headers -- stays muted. All are default links, so a user's
-- own `:highlight` overrides still win.
M.GROUPS = {
  WorklogHeader = "Title",
  WorklogBlockHeader = "NonText",
  WorklogTimestamp = "Statement",
  WorklogTag = "Identifier",
  WorklogOoo = "WarningMsg",
  WorklogLocation = "Function",
  BlotLogged = "Special",
  WorklogDuration = "Special",
  WorklogQuantError = "Comment",
  WorklogOption = "PreProc",
  WorklogOffset = "Type",
  WorklogNudge = "Constant",
  WorklogNote = "Comment",
}

local BASE_PRIORITY = 100
local TOKEN_PRIORITY = 110

-- The timestamp is always a zero-padded HH:MM (5 bytes); 24:00 included.
local TIMESTAMP_WIDTH = 5

-- Header-token diagnostics that make a worklog header invalid (so it renders as a
-- plain block header with no token highlighting), as opposed to INVALID_FIRST_HEADER,
-- which is about document position, not the header line's own validity.
local HEADER_TOKEN_DIAGNOSTICS = {
  [syntax.DIAGNOSTIC.INVALID_WORKLOG_HEADER_OPTION] = true,
  [syntax.DIAGNOSTIC.INVALID_WORKLOG_HEADER_METADATA] = true,
  [syntax.DIAGNOSTIC.INVALID_WORKLOG_HEADER_TOKEN] = true,
}

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
    if
      block.kind == syntax.BLOCK_KIND.GENERIC
      and syntax.is_summary_section_header(block.header.raw)
    then
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
  elseif kind == syntax.TOKEN_KIND.OFFSET then
    return "WorklogOffset"
  elseif kind == syntax.TOKEN_KIND.NUDGE then
    return "WorklogNudge"
  elseif kind == syntax.TOKEN_KIND.LOGGED then
    return "BlotLogged"
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
-- each kind at most once) that the parser peels off the end of a line. Shared by
-- blots and summary rows. The caller only invokes it for valid blots and for
-- summary rows, so a run the parser rejects is never reached.
local function push_trailing_metadata(spans, row, line)
  local tokens = document.tokens(line)

  local first = #tokens + 1
  for i = #tokens, 1, -1 do
    if control_group(tokens[i].text) then
      first = i
    else
      break
    end
  end

  for i = first, #tokens do
    push(
      spans,
      row,
      tokens[i].col_start,
      tokens[i].col_end,
      control_group(tokens[i].text),
      TOKEN_PRIORITY
    )
  end
end

-- Every (+Nm) / (-Nm) rounding marker on the line.
local function push_quant_errors(spans, row, line)
  for _, span in ipairs(document.quant_error_spans(line)) do
    push(spans, row, span.col_start, span.col_end, "WorklogQuantError", TOKEN_PRIORITY)
  end
end

-- A row inside a summary section: its leading duration, rounding marker(s), and any
-- trailing #tag / @location the row still carries. The leading field is an blot's
-- timestamp (a `16:00 ...` row that carried no marker) or a rendered duration token.
local function push_summary_row(spans, row, line, kind)
  local duration = kind == syntax.NODE_KIND.ENTRY and TIMESTAMP_WIDTH
    or document.summary_duration_length(line)
  if duration then
    push(spans, row, 0, duration, "WorklogDuration", TOKEN_PRIORITY)
  end
  push_quant_errors(spans, row, line)
  push_trailing_metadata(spans, row, line)
end

-- A free note. A line that merely looks like a summary row (a leading duration and
-- a (+Nm) marker) but is not inside a generated summary section is ambiguous with a
-- note -- and the parser already classifies it as one -- so it is highlighted as a
-- note, never as a summary item, and a comment can't masquerade as one. Summary
-- rows are highlighted only inside a section (see push_summary_row).
local function push_note(spans, row, line)
  push(spans, row, 0, #line, "WorklogNote", BASE_PRIORITY)
end

local function push_worklog_header(spans, row, line)
  push(spans, row, 0, #line, "WorklogHeader", BASE_PRIORITY)

  for _, token in ipairs(document.tokens(line)) do
    local group = control_group(token.text)
    if not group and document.is_option_token(token.text) then
      group = "WorklogOption"
    end
    if group then
      push(spans, row, token.col_start, token.col_end, group, TOKEN_PRIORITY)
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
      local index = row - 1
      local kind = parsed.nodes[row].kind

      if kind == syntax.NODE_KIND.WORKLOG_HEADER and not invalid_headers[row] then
        push_worklog_header(spans, index, line)
      elseif kind == syntax.NODE_KIND.WORKLOG_HEADER or kind == syntax.NODE_KIND.BLOCK_HEADER then
        push(spans, index, 0, #line, "WorklogBlockHeader", BASE_PRIORITY)
      elseif in_summary[row] then
        push_summary_row(spans, index, line, kind)
      elseif kind == syntax.NODE_KIND.ENTRY then
        push(spans, index, 0, TIMESTAMP_WIDTH, "WorklogTimestamp", TOKEN_PRIORITY)
        push_trailing_metadata(spans, index, line)
      else
        -- A NOTE_LINE, or an INVALID_ENTRY whose time the parser rejected (so it is
        -- not a timestamp): a free note. A summary-shaped line outside a summary
        -- section is a note, not a summary row.
        push_note(spans, index, line)
      end
    end
  end

  return spans
end

return M
