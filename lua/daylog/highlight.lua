local analyze = require("daylog.analyze")
local colors = require("daylog.colors")
local document = require("daylog.document")
local summary = require("daylog.summary")
local summary_block = require("daylog.summary_block")
local syntax = require("daylog.syntax")

local M = {}

-- Parser-driven highlight spans (PURE).
--
-- This module owns no grammar: every recognition decision comes from the parser layer (document.lua
-- node kinds/token spans, analyze.lua header validity/section context, syntax.lua predicates), so
-- there is a single source of truth for what a token is; this file only picks each token's group.
--
-- A span is { line, col_start, col_end, group, priority }: 0-based byte columns, end exclusive,
-- matching the extmark API. Whole-line "base" spans use a lower priority than the narrower token
-- spans layered over them, so e.g. a #tag inside a header wins at its own cells.

-- Highlight groups and the default highlight they link to, exposed as data so the shell registers
-- them once. Inline metadata tokens link to bright, mutually distinct standard groups (not Comment);
-- headers are bold so they read as structure in ANY theme; only the (+Nm) residual and free notes
-- stay muted (Comment). A value is a link string or an attribute table, both registered with
-- default = true, so a theme or a user's own `:highlight` still wins.
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
  -- The stray-cursor bar is a fixed soft red; default = true still lets a theme/user override win.
  DaylogStraySign = { fg = "#d28a8a", ctermfg = 167 },
  DaylogBarLabel = "Comment",
  -- A dead period (a blank entry's uncounted interval) in the time bar: a dim marker glyph.
  DaylogBarGap = "NonText",
  -- A hard red for a broken block: the offending source line and the whole untrustworthy summary
  -- it feeds; a theme/user can still restyle it via `:highlight DaylogError`.
  DaylogError = { fg = "#ff5f5f", ctermfg = 203, bold = true },
}

-- The per-activity colour groups DaylogBar{n} (time-bar / legend-swatch background) and DaylogSign{n}
-- (margin-indicator foreground) are generated on demand from `daylog.palette` and defined lazily by
-- their shell consumers (timebar_ui / buffer), so there is no fixed palette size. Each is registered
-- default = true, so a theme or a user's own :highlight still wins.

local BASE_PRIORITY = 100
local TOKEN_PRIORITY = 110
-- Above every token span, so the error red covers the whole line rather than leaving colour gaps.
local ERROR_PRIORITY = 200

-- The timestamp is always a zero-padded HH:MM (5 bytes); 24:00 included.
local TIMESTAMP_WIDTH = 5

-- Header-token diagnostics that make a log header invalid (so it renders as a plain block header),
-- as opposed to INVALID_FIRST_HEADER, which is about document position, not the line's own validity.
local HEADER_TOKEN_DIAGNOSTICS = {
  [syntax.DIAGNOSTIC.INVALID_LOG_HEADER_OPTION] = true,
  [syntax.DIAGNOSTIC.INVALID_LOG_HEADER_METADATA] = true,
  [syntax.DIAGNOSTIC.INVALID_LOG_HEADER_TOKEN] = true,
}

-- The log header rows the analyzer flagged for bad tokens (so the highlighter demotes them).
local function invalid_header_rows(analysis)
  local rows = {}
  for _, diagnostic in ipairs(analysis.diagnostics) do
    if HEADER_TOKEN_DIAGNOSTICS[diagnostic.code] then
      rows[diagnostic.row] = true
    end
  end
  return rows
end

-- The rows inside a generated summary section: from its header to the blank line that ends it (or
-- the next header / EOF), so free notes written after a summary are not swept in.
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

-- Rows to flag red because a block is broken: the offending source line(s) and the whole summary
-- region of any block carrying such an error, so a suspect summary reads as untrustworthy and clears
-- when the error is fixed. Reuses the analyzer's diagnostics, so the red never disagrees with the
-- refresh warning.
local function error_rows(analysis)
  local red = {}
  local nodes = analysis.document.nodes

  for _, block in ipairs(analysis.log_blocks) do
    -- A block-level structural error points at its offending line(s); red them only when they are
    -- entries -- a header problem falls back on its own highlighting and must not be painted red.
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

    if structural then
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

-- The highlight group for a trailing-metadata / header token (a #tag, @location, clear, or !L), or
-- nil when the token is not metadata.
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

-- Highlight the trailing run of metadata tokens the parser peels off a line, shared by entries and
-- summary rows. The caller only invokes it for valid entries and summary rows, so a run the parser
-- rejects is never reached.
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

-- A row inside a summary section: its leading duration, rounding marker(s), and any trailing
-- #tag / @location. The leading field is an entry's timestamp or a rendered duration token.
local function push_summary_row(spans, row, line, kind)
  local duration = kind == syntax.NODE_KIND.ENTRY and TIMESTAMP_WIDTH
    or document.summary_duration_length(line)
  if duration then
    push(spans, row, 0, duration, "DaylogDuration", TOKEN_PRIORITY)
  end
  push_quant_errors(spans, row, line)
  push_trailing_metadata(spans, row, line)
end

-- A free note. A summary-shaped line outside a generated summary section is highlighted as a note,
-- not a summary item, so a comment can't masquerade as one (summary rows are highlighted only inside
-- a section; see push_summary_row).
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

-- Compute the highlight spans for a daylog buffer's lines. `parsed`/`analysis` may be passed so a
-- render pass shares a single analysis; they are computed when omitted.
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
        -- The ` => label` alias sits before the trailing metadata (between description and metadata).
        push_trailing_metadata(spans, index, line)
        local alias = document.alias_span(line)
        if alias then
          push(spans, index, alias.col_start, alias.col_end, "DaylogAlias", TOKEN_PRIORITY)
        end
      else
        -- A NOTE_LINE, or an INVALID_ENTRY whose time the parser rejected: a free note.
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

-- The active log's semantic entries (alias / tag / offset resolved), or nil when there's no log;
-- the time bar lays the day's intervals out from these. `analysis` may be passed to share one parse.
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

-- The left-margin colour indicator for the active log: a map { buffer_row(1-based) -> colour_index }
-- colouring each entry (and the notes beneath it) and each main summary row by its activity (the
-- resolved label), colours by order of appearance. Also returns the active log's start row, for the
-- stray-cursor mark. `analysis` may be passed to share one parse; the map is empty when there is no log.
function M.indicator_rows(lines, analysis)
  analysis = analysis or analyze.analyze(document.parse(lines))
  local active = analyze.get_active_log(analysis)
  if not active then
    return { rows = {} }
  end

  local index = colors.indices(summary.build_intervals(active.entries))
  local rows = {}

  -- Each entry item spans the entry and the notes/blanks beneath it, so one colour runs down the
  -- whole activity.
  for _, item in ipairs(active.entry_items) do
    local label = summary.entry_summary_text(item)
    local color_index = index[label]
    if color_index then
      for row = item.start_row, item.end_row do
        rows[row] = color_index
      end
    end
  end

  -- The main summary rows render consecutively below the banner in item order, so summary_items[j]
  -- sits at start_row + j. Colour only when the located zone really begins at this block's rendered
  -- banner -- a zone found by shape is no reliable anchor, so it is skipped -- and bound each write
  -- to the zone.
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
