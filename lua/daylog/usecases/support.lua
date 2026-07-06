local analyze = require("daylog.analyze")
local body = require("daylog.body")
local context = require("daylog.context")
local diagnostics = require("daylog.diagnostics")
local entry = require("daylog.entry")
local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_block = require("daylog.summary_block")
local syntax = require("daylog.syntax")

local M = {}

-- Shared use-case helpers.
--
-- The use-case layer works from fully analyzed log context and returns edit
-- scripts plus cursor actions. These helpers centralize context lookup,
-- validation, and edit-building so individual command modules can stay small
-- and focused on one operation each.

local function validate_context(ctx)
  local diagnostic = analyze.find_block_diagnostic(ctx.analysis, ctx.block)

  if diagnostic then
    return nil, diagnostics.message(diagnostic)
  end

  return ctx
end

function M.get_validated_active(lines)
  local ctx, err = context.get_active_log_context(lines)
  if not ctx then
    return nil, err
  end

  return validate_context(ctx)
end

function M.get_validated_at_row(lines, row)
  local ctx, err = context.get_log_context_at_row(lines, row)
  if not ctx then
    return nil, err
  end

  return validate_context(ctx)
end

-- The block's entry item on `row`, or nil. An entry item's start_row equals its semantic
-- entry's row (a timestamped entry is a single line), so this is the one lookup the call
-- sites spelled either way (`item.start_row` or `item.entry.row`).
function M.entry_item_at_row(block, row)
  for _, item in ipairs(block.entry_items) do
    if item.start_row == row then
      return item
    end
  end
  return nil
end

function M.get_insert_index(block, minutes)
  return body.insert_index(block, minutes)
end

function M.get_insert_state(block, minutes)
  return body.state_before(block, minutes)
end

-- The UTC offset to stamp on a current-time insert, or nil for no token. Stamps the
-- live OS offset (`auto_offset`) only when it is known, the insertion point already
-- carries an offset baseline (`current_offset ~= nil`), and that baseline has drifted
-- -- a DST or travel change. An offset-naive day (no header offset) is left untouched,
-- since a lone token there has no baseline to be a delta from and would distort the
-- one interval; a fresh day gets its baseline from the header (see daybook_io).
function M.offset_stamp(current_offset, auto_offset)
  if auto_offset ~= nil and current_offset ~= nil and auto_offset ~= current_offset then
    return auto_offset
  end
  return nil
end

-- Build the edit that inserts `inserted_line` (whose effective tag/location/offset
-- are `ins_tag`/`ins_loc`/`ins_offset`) at `minutes` in `block`. When the inserted
-- entry changes the sticky tag/location/offset the following entry was silently
-- inheriting, the follower is rewritten with a compensating token (#tag/@location,
-- #-/@-, or utc±H) so its effective metadata is preserved. Pinning the immediate
-- follower suffices, since later entries inherit from it. Placement is by the
-- written local clock (raw minutes), so the predecessor and follower are found by
-- raw time, not effective UTC.
function M.insert_entry_edit(block, minutes, inserted_line, ins_tag, ins_loc, ins_offset)
  local insert_index = body.insert_index(block, minutes)
  local pred = body.state_before(block, minutes)

  local follower
  for _, item in ipairs(block.entry_items) do
    if item.minutes > minutes then
      follower = item
      break
    end
  end

  local lines = { inserted_line }
  local end_index = insert_index

  if follower then
    local needs_tag = not follower.explicit_tag
      and not follower.explicit_tag_clear
      and ins_tag ~= pred.tag
    local needs_location = not follower.explicit_location
      and not follower.explicit_location_clear
      and ins_loc ~= pred.location
    -- The offset has no clear token, so a follower with no explicit offset is the
    -- only one that can silently inherit a changed offset.
    local needs_offset = follower.explicit_offset == nil and ins_offset ~= pred.offset

    if needs_tag or needs_location or needs_offset then
      -- Re-emit the follower from the canonical field set so it keeps every marker it
      -- carried (a round±N balance, an !L), gaining only the compensating sticky token
      -- for its new predecessor. Building an ad-hoc subset here previously dropped the
      -- follower's round±N marker on an unrelated insertion.
      lines = {
        inserted_line,
        entry.format(analyze.copy_fields(follower), ins_tag, ins_loc, ins_offset),
      }
      end_index = insert_index + 1
    end
  end

  return {
    edits = {
      {
        start_index = insert_index,
        end_index = end_index,
        lines = lines,
      },
    },
  }
end

-- Build the edit for a fresh entry repeating a `source` activity at `minutes`: copy the
-- source's metadata (its alias included, when it has one) but take the new time, dropping
-- any logged / round±N marker -- a repeat or a carryover is a new entry, not a continuation
-- of the source's commitment. A drifted live offset (`auto_offset`, from auto_timezone)
-- overrides the copied source offset so the entry records the zone it is happening in now,
-- attaching the `offset_change` the shell needs. `source` is any copy_fields-compatible
-- activity (an entry item, or a hand-built carryover activity); its tag/location/offset
-- drive the sticky placement. Shared by :Daylog repeat and the cross-day carryover seed.
function M.fresh_entry_edit(block, source, minutes, auto_offset)
  local state = M.get_insert_state(block, minutes)

  local fields = analyze.copy_fields(source)
  fields.minutes = minutes
  fields.logged = nil
  fields.nudge = nil

  local stamp = M.offset_stamp(state.offset, auto_offset)
  local ins_offset = source.offset
  if stamp ~= nil then
    fields.offset = stamp
    ins_offset = stamp
  end

  local line = entry.format(fields, state.tag, state.location, state.offset)
  local result = M.insert_entry_edit(block, minutes, line, source.tag, source.location, ins_offset)

  if stamp ~= nil then
    result.offset_change = { from = state.offset, to = stamp }
  end

  return result
end

-- Clone a block's semantic entries through the canonical field set (restoring the
-- source row that copy_fields deliberately drops) and apply `mutate(copy)` to each,
-- returning the new list. The summary-writing usecases recompute a summary from
-- entries with a field flipped (logged, nudge, a rename) without re-parsing the
-- buffer, so they share one clone with consistent semantics rather than three
-- hand-rolled copies.
function M.modified_entries(block, mutate)
  local entries = {}

  for _, semantic_entry in ipairs(block.entries) do
    local copy = analyze.copy_fields(semantic_entry)
    copy.row = semantic_entry.row
    if mutate then
      mutate(copy)
    end
    entries[#entries + 1] = copy
  end

  return entries
end

-- Re-emit selected entry lines of a block, threading the raw sticky state so each
-- re-emitted line carries the right compensating #-/@-/utc token for its new
-- predecessor. For each entry item, `fn(item)` returns a table of field overrides to
-- apply over the entry's canonical fields (e.g. a flipped logged, a new nudge), or
-- nil to leave that entry untouched. Returns one single-line edit per re-emitted
-- entry, in ascending row order. The summary-writing usecases share this so the
-- sticky-advance bookkeeping lives in one place (mirrors insert_entry_edit's follower).
function M.rewrite_entry_lines(block, fn)
  local edits = {}
  local current_tag = block.header_tag
  local current_location = block.header_location
  local current_offset = block.header_offset

  for _, item in ipairs(block.entry_items) do
    local overrides = fn(item)
    if overrides then
      local fields = analyze.copy_fields(item)
      for key, value in pairs(overrides) do
        fields[key] = value
      end

      edits[#edits + 1] = {
        start_index = item.start_row - 1,
        end_index = item.start_row,
        lines = { entry.format(fields, current_tag, current_location, current_offset) },
      }
    end

    current_tag = item.tag
    current_location = item.location
    current_offset = item.offset
  end

  return edits
end

-- The render options for a log's in-file summary: no leading blank (the region
-- starts at its header) plus the block's quantize bucket. Named once so every
-- in-place summary render stays in step on this single fact.
function M.summary_render_options(block)
  return { leading_blank = false, quantize_minutes = block.quantize_minutes }
end

-- Locate a log block's existing summary region, returning it alongside the freshly
-- recomputed summary. The region is found from the summary banner in the block's tail
-- (see summary_block.find), not by aligning a rendered summary. Returns nil region when
-- no summary exists yet. Callers take what they need -- summary_zone_edit the region to
-- blast, summary_cursor / rename the recomputed summary to map a cursor onto a row.
function M.locate_summary(analysis, block)
  local computed = summary.summarize_block(block)
  local region = summary_block.find(analysis, block)
  return region, computed
end

-- Assemble an entry-changing command's edit list: the rebuilt-summary edit (when there is
-- one) ahead of the source-entry edits, sorted highest-start-first so applying the summary
-- rebuild never shifts the lower entry rows as it changes size. `source_edits` is every
-- non-summary edit the command makes (rewritten entries, and e.g. rename's header edit).
function M.entry_change_edits(summary_edit, source_edits)
  local edits = {}
  if summary_edit then
    edits[#edits + 1] = summary_edit
  end
  for _, edit in ipairs(source_edits) do
    edits[#edits + 1] = edit
  end
  table.sort(edits, function(a, b)
    return a.start_index > b.start_index
  end)
  return edits
end

-- The summary zone's separator: exactly two blank lines between the body and the rendered
-- content. The blanks belong to the zone (emitted by the zone writer below, never by render
-- or the body), so the separator is normalized however an edit mangled it; a following log
-- gets the same two blanks as a trailing separator, at EOF none.
local SEPARATOR = { "", "" }

-- The block's last timestamped entry row, or its header when entry-less: the hard floor for
-- the body/summary boundary search, so the boundary never sweeps past it into an entry.
local function last_entry_row(block)
  local row = block.start_row
  for _, node in ipairs(block.body_nodes or {}) do
    if node.kind == syntax.NODE_KIND.ENTRY then
      row = node.row
    end
  end
  return row
end

-- The body's last authored (prose or entry) line above the summary, scanned upward from the
-- summary boundary skipping blanks and generated-shaped lines (separator blanks, stranded
-- summary rows), floored at the last entry. So authored notes are kept while generated debris
-- below them is swept into the blast.
local function body_end_above(nodes, block, start_row)
  local floor = last_entry_row(block)
  for row = start_row - 1, floor + 1, -1 do
    local raw = (nodes[row] and nodes[row].raw) or ""
    if
      raw ~= ""
      and not syntax.is_infile_summary_header(raw)
      and not syntax.is_summary_row(raw)
    then
      return row
    end
  end
  return floor
end

-- The 0-based edit replacing [body_end .. zone_end) with the canonical separator + content
-- (+ a trailing separator when another log follows), and whether that zone is already exactly
-- canonical (so no edit need be emitted).
local function canonical_edit(nodes, body_end, zone_end, content, trailing)
  local want = {}
  for _, line in ipairs(SEPARATOR) do
    want[#want + 1] = line
  end
  for _, line in ipairs(content) do
    want[#want + 1] = line
  end
  if trailing then
    for _, line in ipairs(SEPARATOR) do
      want[#want + 1] = line
    end
  end

  local matches = (zone_end - 1 - body_end) == #want
  if matches then
    for index, line in ipairs(want) do
      local node = nodes[body_end + index]
      if (node and node.raw) ~= line then
        matches = false
        break
      end
    end
  end

  return {
    start_index = body_end,
    end_index = zone_end - 1,
    lines = want,
  }, matches
end

-- The log's summary zone bounds (tail_start, stop_row): the window past the last
-- entry, up to the next log / EOF. The create path blasts to `stop_row` so a fresh
-- summary replaces any stray trailing blanks instead of stacking below them.
local function summary_zone_bounds(analysis, block)
  return summary_block.tail_bounds(analysis, block)
end

-- THE one way a log's summary is written into a buffer: blast its zone -- replace from the
-- body boundary through the end of the zone with the canonical two-blank separator + the
-- summary rendered from `modified_entries`. Returns the 0-based edit (and the rebuilt summary,
-- for a caller that follows a row), or nil when the zone is already canonical, or when the log
-- has no summary and `allow_create` is false. Only the refresh pass creates a missing summary
-- (`allow_create`); an entry-changing command rebuilds an existing one. The body never owns
-- the separator, so a command may restructure the body freely. See docs/architecture.md.
function M.summary_zone_edit(analysis, block, modified_entries, allow_create)
  local region = M.locate_summary(analysis, block)
  local nodes = analysis.document.nodes

  local body_end, zone_end
  if region then
    body_end = body_end_above(nodes, block, region.start_row)
    zone_end = region.end_row
  elseif allow_create then
    body_end = body.last_content_row(block)
    local _, stop = summary_zone_bounds(analysis, block)
    zone_end = stop
  else
    return nil
  end

  local rebuilt = summary.summarize_entries(modified_entries, block.quantize_minutes)
  local content =
    render.summary_lines(rebuilt, block.duration_format, M.summary_render_options(block))
  local trailing = zone_end <= analysis.document.row_count
  local edit, already_canonical = canonical_edit(nodes, body_end, zone_end, content, trailing)
  if already_canonical then
    return nil
  end
  return edit, rebuilt, region
end

-- Apply a per-entry field override across both halves of an entry-changing command: rewrite
-- each overridden entry's source line AND rebuild the summary from the same overrides, so the
-- two walks cannot disagree (the divergence class the code has been bitten by). `overrides`
-- maps a semantic entry row to a table of field overrides ({ alias = v } for :Daylog map,
-- { nudge = n } for :Daylog balance); the row's source edit and its projected entry both take
-- exactly those fields. Returns the assembled edits (summary rebuild ahead of the source edits)
-- plus the rebuilt summary and region, for a caller that follows a row to its new line (balance).
-- A nil-clearing override (log_current's unmark) cannot ride a pairs()-applied table, so it
-- stays bespoke.
function M.apply_entry_overrides(analysis, block, overrides)
  local source_edits = M.rewrite_entry_lines(block, function(item)
    return overrides[item.start_row]
  end)

  local modified = M.modified_entries(block, function(copy)
    local override = overrides[copy.row]
    if override then
      for key, value in pairs(override) do
        copy[key] = value
      end
    end
  end)

  local summary_edit, rebuilt, region = M.summary_zone_edit(analysis, block, modified, false)
  return { edits = M.entry_change_edits(summary_edit, source_edits) }, rebuilt, region
end

function M.parse_clock_minutes(time)
  local parsed, err = entry.parse(time)

  if not parsed then
    return nil, "daylog: invalid current time: " .. (err or tostring(time))
  end

  return parsed.minutes
end

function M.append_edit(lines, appended_lines)
  return {
    edits = {
      {
        start_index = #lines,
        end_index = #lines,
        lines = appended_lines,
      },
    },
  }
end

-- Blank lines already at the buffer's tail, so appenders can top the inter-log separator
-- up to the canonical two blanks instead of emitting a seam the next refresh rewrites.
function M.trailing_blank_count(lines)
  local count = 0
  while count < #lines and lines[#lines - count] == "" do
    count = count + 1
  end
  return count
end

-- Apply a list of replace edits ({ start_index, end_index, lines }, 0-based, disjoint,
-- sorted highest-start-first) to a plain line list, returning the new list -- the pure
-- mirror of the shell's nvim_buf_set_lines apply. Highest-first ordering keeps each edit's
-- indexes valid as earlier (higher) edits change the line count, so a caller that builds
-- edits in another order must sort before applying. Lets a usecase build a repaired copy
-- in memory (refresh) and the rename shell rewrite an off-screen day file, both off-buffer.
function M.apply_edits(lines, edits)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line
  end

  for _, edit in ipairs(edits) do
    local next_out = {}
    for i = 1, edit.start_index do
      next_out[#next_out + 1] = out[i]
    end
    for _, line in ipairs(edit.lines) do
      next_out[#next_out + 1] = line
    end
    for i = edit.end_index + 1, #out do
      next_out[#next_out + 1] = out[i]
    end
    out = next_out
  end

  return out
end

return M
