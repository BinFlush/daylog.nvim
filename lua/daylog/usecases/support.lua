local analyze = require("daylog.analyze")
local body = require("daylog.body")
local context = require("daylog.context")
local diagnostics = require("daylog.diagnostics")
local document = require("daylog.document")
local entry = require("daylog.entry")
local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_block = require("daylog.summary_block")
local syntax = require("daylog.syntax")

local M = {}

-- Shared use-case helpers: the use-case layer works from analyzed log context and returns edit
-- scripts plus cursor actions; these centralize context lookup, validation, and edit-building so
-- command modules stay small.

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

-- The block's entry item on `row`, or nil. An entry item's start_row equals its semantic entry's
-- row (a timestamped entry is a single line).
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

-- The UTC offset to stamp on a current-time insert, or nil. Stamps the live OS offset only when it
-- is known, the insertion point already carries a baseline (`current_offset ~= nil`), and that
-- baseline has drifted (DST or travel). An offset-naive day is left untouched, since a lone token
-- there has no baseline to delta from; a fresh day gets its baseline from the header (see daybook_io).
function M.offset_stamp(current_offset, auto_offset)
  if auto_offset ~= nil and current_offset ~= nil and auto_offset ~= current_offset then
    return auto_offset
  end
  return nil
end

-- Build the edit inserting `inserted_line` (effective tag/location/offset = `ins_tag`/`ins_loc`/
-- `ins_offset`) at `minutes` in `block`. When it changes the sticky tag/location/offset the following
-- entry silently inherited, the follower is rewritten with a compensating token so its effective
-- metadata is preserved (pinning the immediate follower suffices; later entries inherit from it).
-- Placement is by the written local clock (raw minutes), not effective UTC.
function M.insert_entry_edit(block, minutes, inserted_line, ins_tag, ins_loc, ins_offset)
  local insert_index = body.insert_index(block, minutes)
  local pred = body.state_before(block, minutes)

  -- Two followers can inherit the changed sticky state. Tag/location compensation targets the first
  -- NON-blank follower: a blank holds neither and passes sticky state straight through, so the
  -- downstream real entry is what silently inherits the change (a #-/@- on a blank would break the
  -- blank-carries-no-metadata invariant and trip its own diagnostic). Offset compensation targets the
  -- IMMEDIATE follower even when it is a blank -- an offset IS allowed on a blank, and its clock bounds
  -- the interval the insert opens before it.
  local immediate, real_follower
  for _, item in ipairs(block.entry_items) do
    if item.minutes > minutes then
      immediate = immediate or item
      if item.text ~= "" then
        real_follower = item
        break
      end
    end
  end

  local blank_immediate = immediate ~= nil and immediate.text == ""
  local edits = {}

  -- (1) Tag/location on the first non-blank follower -- only a separate edit when a blank comes first
  -- (otherwise the immediate follower IS that entry and its in-place rewrite in (2) covers all three).
  -- Its own offset is unchanged (any offset shift rides the blank between), so pass it to emit no token.
  if blank_immediate and real_follower then
    local needs_tag = not real_follower.explicit_tag
      and not real_follower.explicit_tag_clear
      and ins_tag ~= pred.tag
    local needs_location = not real_follower.explicit_location
      and not real_follower.explicit_location_clear
      and ins_loc ~= pred.location
    if needs_tag or needs_location then
      edits[#edits + 1] = {
        start_index = real_follower.start_row - 1,
        end_index = real_follower.start_row,
        lines = {
          entry.format(analyze.copy_fields(real_follower), ins_tag, ins_loc, real_follower.offset),
        },
      }
    end
  end

  -- (2) The insert, rewriting the immediate follower in place when it silently inherits a change. A
  -- blank immediate takes only an offset (its own tag/location as `current` suppress those tokens); a
  -- non-blank immediate takes all three at once, keeping every marker it carried (round±N, !L).
  local lines = { inserted_line }
  local end_index = insert_index
  if immediate then
    local needs_offset = immediate.explicit_offset == nil and ins_offset ~= pred.offset
    if blank_immediate then
      if needs_offset then
        lines = {
          inserted_line,
          entry.format(
            analyze.copy_fields(immediate),
            immediate.tag,
            immediate.location,
            ins_offset
          ),
        }
        end_index = insert_index + 1
      end
    else
      local needs_tag = not immediate.explicit_tag
        and not immediate.explicit_tag_clear
        and ins_tag ~= pred.tag
      local needs_location = not immediate.explicit_location
        and not immediate.explicit_location_clear
        and ins_loc ~= pred.location
      if needs_tag or needs_location or needs_offset then
        lines = {
          inserted_line,
          entry.format(analyze.copy_fields(immediate), ins_tag, ins_loc, ins_offset),
        }
        end_index = insert_index + 1
      end
    end
  end
  -- The follower edit (higher index, 1-for-1) precedes the insert edit so applying them in order does
  -- not shift the follower's coordinates; the insert then lands correctly beneath it.
  edits[#edits + 1] = { start_index = insert_index, end_index = end_index, lines = lines }

  return { edits = edits }
end

-- Repeating from a SUMMARY row brings in only what the summary shows -- the resolved label (its alias
-- when mapped, else its description) as a plain unmapped entry, never a surprise `lhs => rhs`. Returns a
-- copy of the source item carrying that resolved label as its text with the alias stripped.
function M.resolved_bare_item(item)
  local fields = analyze.copy_fields(item)
  fields.text = summary.entry_summary_text(item)
  fields.alias = nil
  return fields
end

-- Build the edit for a fresh entry repeating `source` at `minutes`: copy the source's metadata
-- (alias included) but take the new time, dropping any logged / round±N marker -- a repeat or
-- carryover is a new entry, not a continuation of the commitment. A drifted live offset
-- (`auto_offset`) overrides the copied source offset, attaching the `offset_change` the shell needs.
-- Shared by :Daylog repeat and the cross-day carryover seed.
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

-- Clone a block's semantic entries through the canonical field set (restoring the source row that
-- copy_fields deliberately drops) and apply `mutate(copy)` to each. The summary-writing usecases
-- share this to recompute a summary with a field flipped (logged, nudge, a rename) without re-parsing.
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

-- Re-emit selected entry lines of a block, threading the raw sticky state so each re-emitted line
-- carries the right compensating #-/@-/utc token for its new predecessor. For each entry item,
-- `fn(item, resolved, prev)` (resolved = its effective sticky values, prev = the raw state before it)
-- returns either
--
--   * a non-empty table of field overrides over the entry's canonical fields, re-emitting one line;
--   * a LIST of complete field-sets replacing the line with one per set (split): the first is
--     formatted against the previous sticky state, later sets against the entry's own resolved values
--     so they inherit bare, and the sets must leave the entry's resolved state in effect so the
--     following entry needs no compensating token (an empty list deletes the line);
--   * nil to leave that entry untouched.
--
-- `opts.transform(state)` maps the threaded values at format time only; `opts.skip_unchanged` drops a
-- single-line edit whose re-rendered line equals the source line. Returns one edit per re-emitted
-- entry, in ascending row order.
function M.rewrite_entry_lines(block, fn, opts)
  opts = opts or {}
  local transform = opts.transform or function(state)
    return state
  end

  local edits = {}
  local prev = {
    tag = block.header_tag,
    location = block.header_location,
    offset = block.header_offset,
  }

  for _, item in ipairs(block.entry_items) do
    local resolved = analyze.resolve_sticky(prev, item)
    local result = fn(item, resolved, prev)

    if result then
      local base = transform(prev)
      local lines

      if result[1] ~= nil or next(result) == nil then
        local inherit = transform(resolved)
        lines = {}
        for i, fields in ipairs(result) do
          if i == 1 then
            lines[i] = entry.format(fields, base.tag, base.location, base.offset)
          else
            lines[i] = entry.format(fields, inherit.tag, inherit.location, inherit.offset)
          end
        end
      else
        local fields = analyze.copy_fields(item)
        for key, value in pairs(result) do
          fields[key] = value
        end
        local line = entry.format(fields, base.tag, base.location, base.offset)
        if not (opts.skip_unchanged and line == item.entry.raw) then
          lines = { line }
        end
      end

      if lines then
        edits[#edits + 1] = {
          start_index = item.start_row - 1,
          end_index = item.start_row,
          lines = lines,
        }
      end
    end

    prev = resolved
  end

  return edits
end

-- The block's entry rows within a [r1, r2] line range (a visual selection), in source order. A blank
-- entry is uncounted (no report identity), so it is skipped like a structural line.
function M.entry_rows_in_range(block, r1, r2)
  local lo, hi = math.min(r1, r2), math.max(r1, r2)
  local rows = {}
  for _, item in ipairs(block.entry_items) do
    if item.start_row >= lo and item.start_row <= hi and not summary.is_blank_entry(item) then
      rows[#rows + 1] = item.start_row
    end
  end
  return rows
end

-- The render options for a log's in-file summary: no leading blank (the region starts at its header)
-- plus the block's quantize bucket. Named once so every in-place render stays in step.
function M.summary_render_options(block)
  return { leading_blank = false, quantize_minutes = block.quantize_minutes }
end

-- Locate a log block's existing summary region alongside the freshly recomputed summary; the region
-- is found from the summary banner in the block's tail (see summary_block.find), nil when no summary
-- exists yet.
function M.locate_summary(analysis, block)
  local computed = summary.summarize_block(block)
  local region = summary_block.find(analysis, block)
  return region, computed
end

-- Resolve a by-value target in `lines`' active log: run `find(recomputed)` over the freshly recomputed
-- summary and return { ctx = ctx, item = item }. nil, nil when the active log has no summary yet or
-- `find` returns nothing (a multi-day fan-out skips that day); nil + err on an invalid log.
function M.resolve_active_summary_item(lines, find)
  local ctx, err = M.get_validated_active(lines)
  if not ctx then
    return nil, err
  end
  local region, recomputed = M.locate_summary(ctx.analysis, ctx.block)
  if not region then
    return nil, nil
  end
  local item = find(recomputed)
  if not item then
    return nil, nil
  end
  return { ctx = ctx, item = item }
end

-- Assemble an entry-changing command's edit list: the rebuilt-summary edit ahead of the source-entry
-- Sort edits highest-start-first, so applying them in order never shifts the lower rows as earlier edits
-- change line counts. The one place this load-bearing ordering invariant is named.
function M.sort_edits_descending(edits)
  table.sort(edits, function(a, b)
    return a.start_index > b.start_index
  end)
  return edits
end

-- Re-analyze in the coordinate system left by `primary_edits`, so summaries rebuild against the changed
-- line counts. Reuses `analysis` (no reparse) when no primary edit applies -- refresh's common case.
-- Sorts `primary_edits` highest-first, since apply_edits needs that to keep indices valid.
function M.reanalyze_after(lines, analysis, primary_edits)
  if #primary_edits == 0 then
    return analysis
  end
  M.sort_edits_descending(primary_edits)
  return analyze.analyze(document.parse(M.apply_edits(lines, primary_edits)))
end

-- The two-coordinate rebuild order refresh and order_logs share: primary edits (in `lines` coords) run
-- before summary edits (in the post-primary coords from reanalyze_after), each highest-first, so the
-- shell applies the list in one valid pass. Summary edits are sorted here; primary already is.
function M.ordered_rebuild_edits(primary_edits, summary_edits)
  M.sort_edits_descending(summary_edits)
  local edits = {}
  for _, edit in ipairs(primary_edits) do
    edits[#edits + 1] = edit
  end
  for _, edit in ipairs(summary_edits) do
    edits[#edits + 1] = edit
  end
  return edits
end

-- edits, sorted highest-start-first so applying the rebuild never shifts the lower rows as it changes
-- size. `source_edits` is every non-summary edit the command makes.
function M.entry_change_edits(summary_edit, source_edits)
  local edits = {}
  if summary_edit then
    edits[#edits + 1] = summary_edit
  end
  for _, edit in ipairs(source_edits) do
    edits[#edits + 1] = edit
  end
  return M.sort_edits_descending(edits)
end

-- The summary zone's separator: exactly two blank lines between body and content. The blanks belong
-- to the zone (never render or the body), so the separator is normalized however an edit mangled it;
-- a following log gets two trailing blanks, at EOF none.
local SEPARATOR = { "", "" }

-- The block's last timestamped entry row, or its header when entry-less: the hard floor for the
-- body/summary boundary search, so the boundary never sweeps past it into an entry.
local function last_entry_row(block)
  local row = block.start_row
  for _, node in ipairs(block.body_nodes or {}) do
    if node.kind == syntax.NODE_KIND.ENTRY then
      row = node.row
    end
  end
  return row
end

-- The body's last authored line above the summary, scanned upward skipping blanks and generated-
-- shaped lines, floored at the last entry -- so authored notes are kept while generated debris below
-- them is swept into the blast.
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

-- The log's summary zone bounds (tail_start, stop_row): past the last entry, up to the next log /
-- EOF. The create path blasts to `stop_row` so a fresh summary replaces stray trailing blanks.
local function summary_zone_bounds(analysis, block)
  return summary_block.tail_bounds(analysis, block)
end

-- THE one way a log's summary is written into a buffer: blast its zone -- replace from the body
-- boundary through the zone end with the two-blank separator + the summary rendered from
-- `modified_entries`. Returns the 0-based edit (and rebuilt summary), or nil when already canonical or
-- when the log has no summary and `allow_create` is false. Only the refresh pass creates a missing
-- summary; the body never owns the separator, so a command may restructure the body freely. See
-- docs/architecture.md.
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

-- Apply a per-entry field override across both halves of an entry-changing command: rewrite each
-- overridden source line AND rebuild the summary from the same overrides, so the two walks cannot
-- disagree. `overrides` maps a semantic entry row to field overrides ({ alias = v } for :Daylog map,
-- { nudge = n } for :Daylog balance). Returns the assembled edits plus the rebuilt summary and region.
-- A nil-clearing override (log_current's unmark) cannot ride a pairs()-applied table, so it stays
-- bespoke.
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

-- Apply a list of replace edits ({ start_index, end_index, lines }, 0-based, disjoint, sorted
-- highest-start-first) to a plain line list -- the pure mirror of the shell's nvim_buf_set_lines
-- apply. Highest-first ordering keeps each edit's indexes valid as earlier edits change the line
-- count, so a caller building edits in another order must sort first.
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
