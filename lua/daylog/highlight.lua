local analyze = require("daylog.analyze")
local colors = require("daylog.colors")
local document = require("daylog.document")
local summary = require("daylog.summary")
local summary_block = require("daylog.summary_block")
local syntax = require("daylog.syntax")

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
-- end exclusive, matching the extmark API. Whole-line "base" spans (a log
-- header, a block header, a note) use a lower priority than the narrower token
-- spans layered over them, so e.g. a #tag inside a header wins at its own cells.

-- Highlight groups and the default highlight they link to. Exposed as data so the
-- shell registers them once; the names match the previous syntax file, so any
-- user `highlight` overrides keep working unchanged.
-- Inline metadata tokens link to bright, mutually distinct standard groups (not
-- Comment): a #tag is cyan-ish (Identifier), an @location blue-ish (Function), a
-- utc±H offset green-ish (Type), a round±N nudge red/orange-ish (Constant), and a logged
-- marker (`!S`/`!T`/`!L`/`!W`) orange-ish (Special). Headers (the log header and the summary/report section dividers)
-- are bold, so they read as structure and separate cleanly from a note in ANY theme -- a
-- linked color was too theme-dependent (some themes render it identically to Comment).
-- Only the (+Nm) rounding residual and free notes stay muted (Comment). A value is either a
-- link string or an attribute table; both are registered with default = true, so a theme or
-- a user's own `:highlight` still wins.
M.GROUPS = {
  DaylogHeader = { bold = true },
  DaylogBlockHeader = { bold = true },
  DaylogTimestamp = "Statement",
  DaylogTag = "Identifier",
  DaylogLocation = "Function",
  DaylogLogged = "Special",
  DaylogDuration = "Special",
  DaylogQuantError = "Comment",
  DaylogOption = "PreProc",
  DaylogOffset = "Type",
  DaylogNudge = "Constant",
  -- A mapping alias (` => label`) -- the target an entry resolves to in the summary.
  DaylogAlias = "String",
  DaylogNote = "Comment",
  -- The stray-cursor bar is a fixed soft red (a deliberate accent, not a syntax-role link);
  -- default = true still lets a theme/user override win.
  DaylogStraySign = { fg = "#d28a8a", ctermfg = 167 },
  DaylogBarLabel = "Comment",
  -- A hard red for a broken block: the offending source line AND the whole (now-untrustworthy)
  -- summary it feeds. Overrides the normal token colours so it reads as an error at a glance; a
  -- theme/user can still restyle it (e.g. to a background) via `:highlight DaylogError`.
  DaylogError = { fg = "#ff5f5f", ctermfg = 203, bold = true },
}

-- The per-activity colour groups DaylogBar{n} (time-bar block / legend-swatch background) and
-- DaylogSign{n} (margin-indicator foreground) are generated on demand from `daylog.palette` -- an
-- OkLCH colour wheel giving one distinct colour per activity index -- and defined lazily by their
-- shell consumers (timebar_ui / buffer), so there is no fixed palette size to cycle through. Each is
-- registered default = true, so a theme or a user's own :highlight still wins.

local BASE_PRIORITY = 100
local TOKEN_PRIORITY = 110
-- Above every token span, so the error red covers the whole line rather than leaving colour gaps.
local ERROR_PRIORITY = 200

-- The timestamp is always a zero-padded HH:MM (5 bytes); 24:00 included.
local TIMESTAMP_WIDTH = 5

-- Header-token diagnostics that make a log header invalid (so it renders as a
-- plain block header with no token highlighting), as opposed to INVALID_FIRST_HEADER,
-- which is about document position, not the header line's own validity.
local HEADER_TOKEN_DIAGNOSTICS = {
  [syntax.DIAGNOSTIC.INVALID_LOG_HEADER_OPTION] = true,
  [syntax.DIAGNOSTIC.INVALID_LOG_HEADER_METADATA] = true,
  [syntax.DIAGNOSTIC.INVALID_LOG_HEADER_TOKEN] = true,
}

-- The log header rows the analyzer flagged for bad tokens (so the highlighter
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

-- Rows to flag red because a block is broken: the offending source line(s) -- an out-of-order or
-- invalid entry, or a logging error (a conflicting or off-grid `!S`) -- AND the whole
-- summary region of any block carrying such an error, so a stale/suspect summary reads as
-- untrustworthy at a glance and clears the instant the error is fixed. Reuses the analyzer's own
-- diagnostics plus the one shared `summary.logging_diagnostics`, so the red never disagrees with the
-- refresh warning.
local function error_rows(analysis)
  local red = {}
  local nodes = analysis.document.nodes

  for _, block in ipairs(analysis.log_blocks) do
    local logging = summary.logging_diagnostics(block)
    for _, diagnostic in ipairs(logging) do
      red[diagnostic.row] = true
    end

    -- A block-level structural error (out-of-order / invalid entry) points at its offending
    -- line(s); red them, but only when they are entries -- a header problem falls back on its own
    -- header highlighting and must not be painted red.
    local structural = analyze.find_block_diagnostic(analysis, block)
    if structural then
      for _, at in ipairs({ structural.row, structural.row2 }) do
        local node = at and nodes[at]
        if
          node
          and (node.kind == syntax.NODE_KIND.ENTRY or node.kind == syntax.NODE_KIND.INVALID_ENTRY)
        then
          red[at] = true
        end
      end
    end

    if #logging > 0 or structural then
      local region = summary_block.find(analysis, block)
      if region then
        for row = region.start_row, region.end_row - 1 do
          red[row] = true
        end
      end
    end
  end

  return red
end

-- The highlight group for a trailing-metadata / header token (a #tag, @location,
-- clear, or !L), or nil when the token is not metadata.
local function control_group(token)
  local kind = document.classify_control_token(token)
  if kind == syntax.TOKEN_KIND.TAG then
    return "DaylogTag"
  elseif kind == syntax.TOKEN_KIND.LOCATION then
    return "DaylogLocation"
  elseif kind == syntax.TOKEN_KIND.OFFSET then
    return "DaylogOffset"
  elseif kind == syntax.TOKEN_KIND.NUDGE then
    return "DaylogNudge"
  elseif kind == syntax.TOKEN_KIND.LOGGED then
    return "DaylogLogged"
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
-- entries and summary rows. The caller only invokes it for valid entries and for
-- summary rows, so a run the parser rejects is never reached.
local function push_trailing_metadata(spans, row, line)
  local tokens = document.tokens(line)
  local first = document.trailing_metadata_start(tokens)

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
    push(spans, row, span.col_start, span.col_end, "DaylogQuantError", TOKEN_PRIORITY)
  end
end

-- A row inside a summary section: its leading duration, rounding marker(s), and any
-- trailing #tag / @location the row still carries. The leading field is an entry's
-- timestamp (a `16:00 ...` row that carried no marker) or a rendered duration token.
local function push_summary_row(spans, row, line, kind)
  local duration = kind == syntax.NODE_KIND.ENTRY and TIMESTAMP_WIDTH
    or document.summary_duration_length(line)
  if duration then
    push(spans, row, 0, duration, "DaylogDuration", TOKEN_PRIORITY)
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
  push(spans, row, 0, #line, "DaylogNote", BASE_PRIORITY)
end

local function push_log_header(spans, row, line)
  push(spans, row, 0, #line, "DaylogHeader", BASE_PRIORITY)

  for _, token in ipairs(document.tokens(line)) do
    local group = control_group(token.text)
    if not group and document.is_option_token(token.text) then
      group = "DaylogOption"
    end
    if group then
      push(spans, row, token.col_start, token.col_end, group, TOKEN_PRIORITY)
    end
  end
end

-- Compute the highlight spans for a daylog buffer's lines. `parsed`/`analysis` (one parse + analyze)
-- may be passed so a render pass shares a single analysis; they are computed when omitted.
function M.spans(lines, parsed, analysis)
  parsed = parsed or document.parse(lines)
  analysis = analysis or analyze.analyze(parsed)
  local in_summary = summary_section_rows(analysis)
  local invalid_headers = invalid_header_rows(analysis)
  local red_rows = error_rows(analysis)
  local spans = {}

  for row, line in ipairs(lines) do
    if line ~= "" then
      local index = row - 1
      local kind = parsed.nodes[row].kind

      if kind == syntax.NODE_KIND.LOG_HEADER and not invalid_headers[row] then
        push_log_header(spans, index, line)
      elseif kind == syntax.NODE_KIND.LOG_HEADER or kind == syntax.NODE_KIND.BLOCK_HEADER then
        push(spans, index, 0, #line, "DaylogBlockHeader", BASE_PRIORITY)
      elseif in_summary[row] then
        push_summary_row(spans, index, line, kind)
      elseif kind == syntax.NODE_KIND.ENTRY then
        push(spans, index, 0, TIMESTAMP_WIDTH, "DaylogTimestamp", TOKEN_PRIORITY)
        -- Metadata trails the line as usual; the ` => label` alias sits before it (between
        -- the description and the metadata) and is colored on its own.
        push_trailing_metadata(spans, index, line)
        local alias = document.alias_span(line)
        if alias then
          push(spans, index, alias.col_start, alias.col_end, "DaylogAlias", TOKEN_PRIORITY)
        end
      else
        -- A NOTE_LINE, or an INVALID_ENTRY whose time the parser rejected (so it is
        -- not a timestamp): a free note. A summary-shaped line outside a summary
        -- section is a note, not a summary row.
        push_note(spans, index, line)
      end

      -- Overlay the whole line in error red when the block is broken (offending line or its
      -- untrustworthy summary); the high priority covers the token spans pushed above.
      if red_rows[row] then
        push(spans, index, 0, #line, "DaylogError", ERROR_PRIORITY)
      end
    end
  end

  return spans
end

-- The active log's semantic entries (alias / tag / offset resolved), or nil when there's no log.
-- The time bar lays the day's intervals out from these. `analysis` may be passed to share one parse.
function M.active_entries(lines, analysis)
  analysis = analysis or analyze.analyze(document.parse(lines))
  local active = analyze.get_active_log(analysis)
  return active and active.entries or nil
end

-- One parse + analyze for a render pass, returned together so the shell analyses once and shares it
-- across spans / indicator_rows / active_entries instead of repeating the work per consumer.
function M.parse_and_analyze(lines)
  local parsed = document.parse(lines)
  return parsed, analyze.analyze(parsed)
end

-- Pure: the left-margin colour indicator for the active log -- a map { buffer_row(1-based) ->
-- colour_index } colouring each entry (and the notes beneath it, so an activity reads as one
-- connected run) and each main summary row by its activity (the resolved label), with colours by
-- order of appearance. Also returns the active log's start row, for the stray-cursor mark. `analysis`
-- (one parse + analyze) may be passed so a render pass shares a single analysis; it is computed when
-- omitted. The map is empty when there is no log.
function M.indicator_rows(lines, analysis)
  analysis = analysis or analyze.analyze(document.parse(lines))
  local active = analyze.get_active_log(analysis)
  if not active then
    return { rows = {} }
  end

  local index = colors.indices(summary.build_intervals(active.entries))
  local rows = {}

  -- Each entry item spans the entry and the notes/blanks beneath it (up to the next entry), so one
  -- colour runs down the whole activity.
  for _, item in ipairs(active.entry_items) do
    local label = (item.alias ~= nil and item.alias ~= "") and item.alias or item.text
    local color_index = index[label]
    if color_index then
      for row = item.start_row, item.end_row do
        rows[row] = color_index
      end
    end
  end

  -- The main summary rows render consecutively right below the summary banner, in item order, so
  -- summary_items[j] sits at start_row + j. Colour only when the located zone really begins at this
  -- block's rendered banner -- a zone found by shape (a deleted/mangled banner) is no reliable anchor,
  -- so it is skipped rather than risk colouring the wrong rows -- and bound each write to the zone.
  local zone = summary_block.find(analysis, active)
  local banner = syntax.summary_header(active.quantize_minutes, active.duration_format)
  if zone and lines[zone.start_row] == banner then
    for j, sitem in ipairs(summary.summarize_block(active).summary_items) do
      local color_index = index[sitem.text]
      local row = zone.start_row + j
      if color_index and row < zone.end_row then
        rows[row] = color_index
      end
    end
  end

  return { rows = rows, active_start = active.start_row }
end

return M
