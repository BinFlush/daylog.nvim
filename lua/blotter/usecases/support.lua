local analyze = require("blotter.analyze")
local body = require("blotter.body")
local context = require("blotter.context")
local diagnostics = require("blotter.diagnostics")
local blot = require("blotter.blot")
local render = require("blotter.render")
local summary = require("blotter.summary")
local summary_block = require("blotter.summary_block")

local M = {}

-- Shared use-case helpers.
--
-- The use-case layer works from fully analyzed blotter context and returns edit
-- scripts plus cursor actions. These helpers centralize context lookup,
-- validation, and edit-building so individual command modules can stay small
-- and focused on one operation each.

function M.validate_context(ctx)
  local diagnostic = analyze.find_block_diagnostic(ctx.analysis, ctx.block)

  if diagnostic then
    return nil, diagnostics.message(diagnostic)
  end

  return ctx
end

function M.get_validated_active(lines)
  local ctx, err = context.get_active_blotter_context(lines)
  if not ctx then
    return nil, err
  end

  return M.validate_context(ctx)
end

function M.get_validated_at_row(lines, row)
  local ctx, err = context.get_blotter_context_at_row(lines, row)
  if not ctx then
    return nil, err
  end

  return M.validate_context(ctx)
end

function M.get_insert_index(block, minutes)
  return body.insert_index(block, minutes)
end

function M.get_insert_state(block, minutes)
  return body.state_before(block, minutes)
end

-- Build the edit that inserts `inserted_line` (whose effective tag/location/offset
-- are `ins_tag`/`ins_loc`/`ins_offset`) at `minutes` in `block`. When the inserted
-- blot changes the sticky tag/location/offset the following blot was silently
-- inheriting, the follower is rewritten with a compensating token (#tag/@location,
-- #-/@-, or utc±H) so its effective metadata is preserved. Pinning the immediate
-- follower suffices, since later blots inherit from it. Placement is by the
-- written local clock (raw minutes), so the predecessor and follower are found by
-- raw time, not effective UTC.
function M.insert_blot_edit(block, minutes, inserted_line, ins_tag, ins_loc, ins_offset)
  local insert_index = body.insert_index(block, minutes)
  local pred = body.state_before(block, minutes)

  local follower
  for _, item in ipairs(block.blot_items) do
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
        blot.format(analyze.copy_fields(follower), ins_tag, ins_loc, ins_offset),
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

-- Clone a block's semantic blots through the canonical field set (restoring the
-- source row that copy_fields deliberately drops) and apply `mutate(copy)` to each,
-- returning the new list. The summary-writing usecases recompute a summary from
-- blots with a field flipped (logged, nudge, a rename) without re-parsing the
-- buffer, so they share one clone with consistent semantics rather than three
-- hand-rolled copies.
function M.modified_entries(block, mutate)
  local blots = {}

  for _, semantic_entry in ipairs(block.blots) do
    local copy = analyze.copy_fields(semantic_entry)
    copy.row = semantic_entry.row
    if mutate then
      mutate(copy)
    end
    blots[#blots + 1] = copy
  end

  return blots
end

-- Re-emit selected blot lines of a block, threading the raw sticky state so each
-- re-emitted line carries the right compensating #-/@-/utc token for its new
-- predecessor. For each blot item, `fn(item)` returns a table of field overrides to
-- apply over the blot's canonical fields (e.g. a flipped logged, a new nudge), or
-- nil to leave that blot untouched. Returns one single-line edit per re-emitted
-- blot, in ascending row order. The summary-writing usecases share this so the
-- sticky-advance bookkeeping lives in one place (mirrors insert_blot_edit's follower).
function M.rewrite_entry_lines(block, fn)
  local edits = {}
  local current_tag = block.header_tag
  local current_location = block.header_location
  local current_offset = block.header_offset

  for _, item in ipairs(block.blot_items) do
    local overrides = fn(item)
    if overrides then
      local fields = analyze.copy_fields(item)
      for key, value in pairs(overrides) do
        fields[key] = value
      end

      edits[#edits + 1] = {
        start_index = item.start_row - 1,
        end_index = item.start_row,
        lines = { blot.format(fields, current_tag, current_location, current_offset) },
      }
    end

    current_tag = item.tag
    current_location = item.location
    current_offset = item.offset
  end

  return edits
end

-- The render options for a blotter's in-file summary: no leading blank (the region
-- starts at its header) plus the block's quantize bucket. Named once so every
-- in-place summary render stays in step on this single fact.
function M.summary_render_options(block)
  return { leading_blank = false, quantize_minutes = block.quantize_minutes }
end

-- Locate a blotter block's existing summary region, returning it alongside the
-- freshly computed summary and its rendered (in-file) lines. The region is found by
-- rendering the current summary and matching it against the block's tail (see
-- summary_block). Returns nil region when no summary exists yet; callers reuse
-- whichever values they need -- the summary-acting usecases the region, refresh the
-- computed/rendered to rewrite or create.
function M.locate_summary(analysis, block)
  local computed = summary.summarize_block(block)
  local rendered =
    render.summary_lines(computed, block.duration_format, M.summary_render_options(block))
  local region = summary_block.find(analysis, block, rendered)
  return region, computed, rendered
end

function M.parse_clock_minutes(time)
  local parsed, err = blot.parse(time)

  if not parsed then
    return nil, "blotter: invalid current time: " .. (err or tostring(time))
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

return M
