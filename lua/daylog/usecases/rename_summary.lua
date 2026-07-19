local entry = require("daylog.entry")
local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")

local M = {}

-- Rename a single entry's text, or a #tag / @location, propagating into the log.
--
-- Rename edits the journal at the source. It deliberately does NOT act on an activity
-- summary row: that row groups entries resolving to one string by different means (a bare
-- description or a mapped `=> alias`), so a bulk rename through it is ambiguous and would
-- overwrite the distinct descriptions a mapping keeps -- relabel for the report with
-- :Daylog map instead. A cursor resolves to:
--
--   * an entry line -> that one entry's activity text;
--   * a tag-total row -> that #tag everywhere it is effective;
--   * a location-total row -> that @location everywhere it is effective;
--   * an activity summary row -> refused (M.REFUSE_ACTIVITY_ROW).
--
-- Tag/location renames are value substitutions: only the header token and the explicit
-- tokens naming the old value are rewritten, and sticky inheritance is preserved (an entry
-- that inherited the old value inherits the new from the same rewritten source). Only lines
-- whose canonical rendering changes are edited.

M.NOT_A_ROW = "daylog: put the cursor on an entry, or a tag or location row, to rename it"
M.REFUSE_ACTIVITY_ROW = "daylog: rename an entry to fix its text, or :Daylog map to relabel "
  .. "an activity for the report"
M.CANNOT_TOTALS = "daylog: a totals row cannot be renamed"
M.CANNOT_UNTAGGED = "daylog: the (untagged) group cannot be renamed; tag the entries first"
M.CANNOT_NO_LOCATION =
  "daylog: the (no location) group cannot be renamed; set a location on the entries first"
M.INVALID_NAME = "daylog: a tag or location name must be letters, digits, underscores, or hyphens"
M.EMPTY_TEXT = "daylog: the activity text cannot be empty"
M.SAME_NAME = "daylog: the new name matches the current name"
M.NO_ENTRIES_IN_RANGE = "daylog: no entries in the selection to rename"
M.REFUSE_LOGGED = "daylog: refusing to rename a logged entry; unlog it first"
M.REFUSE_BLANK = "daylog: a blank entry is uncounted and cannot be renamed"

-- A claim names the identity it was logged under, so relabelling one would rewrite a ledger entry
-- after the fact: refuse when an affected entry is marked at a level this rename rewrites the cell of
-- (an activity rename touches `s`; a tag rename `s` and `t`; a location rename `s` and `l`). Markers
-- at the other levels record neither, and ride through untouched.
local function refuse_logged(block, affected, levels)
  for _, entry_item in ipairs(block.entry_items) do
    if entry_item.logged and affected(entry_item) then
      for _, level in ipairs(levels) do
        if entry_item.logged[level] then
          return M.REFUSE_LOGGED
        end
      end
    end
  end
  return nil
end

-- Classify a summary layout row into a rename target { kind, current } -- a #tag or
-- @location total; an activity row (SUMMARY_ITEM) is refused (ambiguous grouping, see
-- header). Single chokepoint for the cursor and report paths; the entry-line branch
-- builds its target without classify, so it is not refused. PURE.
function M.classify(layout_row)
  local kind = layout_row.kind
  local item = layout_row.item

  if kind == render.LAYOUT_KIND.SUMMARY_ITEM then
    return nil, M.REFUSE_ACTIVITY_ROW
  elseif kind == render.LAYOUT_KIND.TAG_TOTAL then
    if item.tag == nil then
      return nil, M.CANNOT_UNTAGGED
    end
    return { kind = "tag", current = item.tag }
  elseif kind == render.LAYOUT_KIND.LOCATION_TOTAL then
    if item.location == nil then
      return nil, M.CANNOT_NO_LOCATION
    end
    return { kind = "location", current = item.location }
  end

  return nil, M.CANNOT_TOTALS
end

-- The other same-kind values in a summary, in display order, as merge targets for the
-- rename picker: renaming to one folds the two together (rename and merge are the same
-- substitution). An activity offers the other texts under the same tag (so the rename keeps
-- the tag and actually merges); the current value and nil buckets are excluded.
function M.merge_candidates(summarized, kind, current, current_tag)
  local seen = {}
  local candidates = {}

  local function add(value)
    if value ~= nil and value ~= current and not seen[value] then
      seen[value] = true
      candidates[#candidates + 1] = value
    end
  end

  if kind == "tag" then
    for _, item in ipairs(summarized.tag_totals or {}) do
      add(item.tag)
    end
  elseif kind == "location" then
    for _, item in ipairs(summarized.location_totals or {}) do
      add(item.location)
    end
  else
    for _, item in ipairs(summarized.summary_items or {}) do
      if item.tag == current_tag then
        add(item.text)
      end
    end
  end

  return candidates
end

-- The shared description behind a set of source entries, or nil when they disagree; rename
-- edits the description, so the prompt defaults to it rather than an aliased row's label.
local function source_description(block, source_entry_rows)
  local rows = {}
  for _, row in ipairs(source_entry_rows or {}) do
    rows[row] = true
  end

  local text
  for _, semantic_entry in ipairs(block.entries) do
    if rows[semantic_entry.row] then
      if text == nil then
        text = semantic_entry.text
      elseif text ~= semantic_entry.text then
        return nil
      end
    end
  end

  return text
end

-- Resolve the cursor to a rename context: a summary row (item / tag / location total) or,
-- when the cursor sits on an entry in the active log, that single entry as an item rename
-- scoped to just it. Returns { ctx, region, recomputed, item, target } or nil, err. `item`
-- carries `source_entry_rows`; `target` is { kind, current, tag? }.
local function resolve_context(lines, cursor_row)
  -- A stale/ambiguous row or invalid log surfaces as `err`; a valid log the cursor is not
  -- on a summary row of yields the entry under it (or nil) to rename in place.
  local result, resolve_err = summary_cursor.resolve_or_entry(lines, cursor_row)
  if not result then
    return nil, resolve_err or M.NOT_A_ROW
  end

  if result.layout_row then
    local target, classify_err = M.classify(result.layout_row)
    if not target then
      return nil, classify_err
    end
    return {
      ctx = result.ctx,
      region = result.region,
      recomputed = result.recomputed,
      item = result.layout_row.item,
      target = target,
    }
  end

  local entry_item = result.entry_item
  if entry_item then
    local region, recomputed = support.locate_summary(result.ctx.analysis, result.ctx.block)
    return {
      ctx = result.ctx,
      region = region,
      recomputed = recomputed,
      item = {
        text = entry_item.text,
        tag = entry_item.tag,
        source_entry_rows = { cursor_row },
      },
      target = { kind = "item", current = entry_item.text or "", tag = entry_item.tag },
    }
  end

  return nil, M.NOT_A_ROW
end

-- Resolve the cursor to a rename target for the shell to prompt with: { kind, current,
-- candidates } (the same-kind values to merge into). Every failure carries a user-facing message.
function M.resolve(lines, cursor_row)
  local context, err = resolve_context(lines, cursor_row)
  if not context then
    return nil, err
  end

  local target = context.target

  -- Prompt with the entries' own description, not the alias; fall back to the label when
  -- the descriptions disagree.
  if target.kind == "item" then
    local description = source_description(context.ctx.block, context.item.source_entry_rows)
    if description ~= nil then
      target.current = description
    end
  end

  target.candidates =
    M.merge_candidates(context.recomputed, target.kind, target.current, target.tag)
  return target
end

-- A valid #tag / @location name: the token grammar (document.lua), minus the bare
-- "-" that would render as the #-/@- clear token.
local function valid_name(name)
  return type(name) == "string" and name:match("^[%w_%-]+$") ~= nil and name ~= "-"
end

-- Walk the block's entries with the renamed sticky state, re-rendering affected entry lines
-- whose canonical form changes, and build the renamed semantic entries the summary is
-- recomputed from. `ops` carries the per-kind rename functions and affected predicate.
local function build_source_edits(block, ops)
  local renamed_entrys = support.modified_entries(block, function(copy)
    copy.tag = ops.rename_tag(copy.tag)
    copy.location = ops.rename_loc(copy.location)
    copy.text = ops.text_for(copy.row, copy.text)
  end)

  -- Re-emit each affected entry from its canonical fields (preserving its nudge / !L) with
  -- the rename applied to each resolved value at format time, so renaming the result equals
  -- inheriting an already-renamed current. The UTC offset is threaded raw (untouched); an
  -- entry that only inherited the renamed value renders identically and skip_unchanged drops it.
  local edits = support.rewrite_entry_lines(block, function(item, resolved, prev)
    -- Re-emit an affected entry, and also the entry FOLLOWING one: renaming a predecessor's effective
    -- tag/location can make the follower's explicit token redundant (it now inherits the renamed value)
    -- or newly needed. skip_unchanged drops the re-emission unless the follower's canonical line
    -- actually changed, so only a follower that truly needs it is rewritten. `ops.affected(prev)`
    -- reuses the per-kind predicate on the predecessor's resolved sticky (never true for an item rename,
    -- which leaves tags/locations untouched).
    if not (ops.affected(item) or ops.affected(prev)) then
      return nil
    end
    return {
      text = ops.text_for(item.start_row, item.text),
      tag = ops.rename_tag(resolved.tag),
      location = ops.rename_loc(resolved.location),
      offset = resolved.offset,
    }
  end, {
    skip_unchanged = true,
    transform = function(state)
      return {
        tag = ops.rename_tag(state.tag),
        location = ops.rename_loc(state.location),
        offset = state.offset,
      }
    end,
  })

  return edits, renamed_entrys
end

-- Identity rename used for fields a given rename does not touch.
local function identity(value)
  return value
end

-- Build the rename edit script for one log block: rewrite the affected source entries (and
-- the header token when it declared the renamed value), then rebuild the one summary in
-- place. `item` is the recomputed summary item; `target.kind` selects the rename mode.
local function build_rename(analysis, block, item, target, new_value)
  local ops = {
    rename_tag = identity,
    rename_loc = identity,
    text_for = function(_, text)
      return text
    end,
  }
  local header_field -- "tag" | "location" | nil: whether the header token is renamed

  if target.kind == "item" then
    local sanitized = entry.sanitize_text(new_value or "")
    if sanitized == "" then
      return nil, M.EMPTY_TEXT
    end
    if sanitized == (item.text or "") then
      return nil, M.SAME_NAME
    end

    -- Rename exactly the entries in source_entry_rows; a same-named sibling or the closing
    -- entry is never swept in.
    local rows = {}
    for _, row in ipairs(item.source_entry_rows or {}) do
      rows[row] = true
    end

    for _, entry_item in ipairs(block.entry_items) do
      if rows[entry_item.start_row] then
        -- A blank entry is uncounted and has no report identity; it is not renamable.
        if summary.is_blank_entry(entry_item) then
          return nil, M.REFUSE_BLANK
        end
      end
    end

    local logged_err = refuse_logged(block, function(entry_item)
      return rows[entry_item.start_row] == true
    end, { "s" })
    if logged_err then
      return nil, logged_err
    end

    ops.affected = function(it)
      return rows[it.start_row] == true
    end
    ops.text_for = function(row, text)
      if rows[row] then
        return sanitized
      end
      return text
    end
  elseif target.kind == "tag" then
    if not valid_name(new_value) then
      return nil, M.INVALID_NAME
    end
    if new_value == item.tag then
      return nil, M.SAME_NAME
    end

    local old = item.tag
    ops.rename_tag = function(tag)
      if tag == old then
        return new_value
      end
      return tag
    end
    ops.affected = function(it)
      return it.tag == old
    end
    local logged_err = refuse_logged(block, ops.affected, { "s", "t" })
    if logged_err then
      return nil, logged_err
    end
    if block.header_tag == old then
      header_field = "tag"
    end
  else
    if not valid_name(new_value) then
      return nil, M.INVALID_NAME
    end
    if new_value == item.location then
      return nil, M.SAME_NAME
    end

    local old = item.location
    ops.rename_loc = function(location)
      if location == old then
        return new_value
      end
      return location
    end
    ops.affected = function(it)
      return it.location == old
    end
    local logged_err = refuse_logged(block, ops.affected, { "s", "l" })
    if logged_err then
      return nil, logged_err
    end
    if block.header_location == old then
      header_field = "location"
    end
  end

  local edits, renamed_entrys = build_source_edits(block, ops)

  -- The header carries the renamed tag/location only when it declared it.
  if header_field then
    local new_header = render.log_header_line(
      ops.rename_tag(block.header_tag),
      ops.rename_loc(block.header_location),
      block.header_offset,
      block.header_quantize_minutes,
      block.header_duration_format
    )
    if new_header ~= block.header.raw then
      table.insert(edits, {
        start_index = block.header.row - 1,
        end_index = block.header.row,
        lines = { new_header },
      })
    end
  end

  -- Rebuild the one summary from the renamed entries (a nil region is a single entry in a log
  -- with no summary yet -- a later refresh creates it). `edits` is the source + header edits.
  local summary_edit = support.summary_zone_edit(analysis, block, renamed_entrys, false)

  return { edits = support.entry_change_edits(summary_edit, edits) }
end

-- Find the recomputed summary item a value-keyed target names, or nil when absent. For an
-- activity the tag scopes the match (same text under a different tag is a different item).
local function find_target_item(recomputed, target)
  if target.kind == "tag" then
    for _, item in ipairs(recomputed.tag_totals or {}) do
      if item.tag == target.current then
        return item
      end
    end
  elseif target.kind == "location" then
    for _, item in ipairs(recomputed.location_totals or {}) do
      if item.location == target.current then
        return item
      end
    end
  else
    -- An activity is matched by text + tag; this branch serves run_by_value (the cursor and
    -- report UIs refuse activity rows in classify).
    for _, item in ipairs(recomputed.summary_items or {}) do
      if (item.text or "") == target.current and item.tag == target.tag then
        return item
      end
    end
  end

  return nil
end

function M.run(lines, cursor_row, new_value)
  local context, err = resolve_context(lines, cursor_row)
  if not context then
    return nil, err
  end

  return build_rename(
    context.ctx.analysis,
    context.ctx.block,
    context.item,
    context.target,
    new_value
  )
end

-- Rename by value rather than by cursor: act on the active log's summary item named by
-- `target` ({ kind, current, tag? }). Returns the edit script; nil, nil when the value is
-- absent (so a multi-day rename skips the day); or nil + err when the log is invalid.
function M.run_by_value(lines, target, new_value)
  local resolved, err = support.resolve_active_summary_item(lines, function(recomputed)
    return find_target_item(recomputed, target)
  end)
  if not resolved then
    return nil, err
  end
  return build_rename(resolved.ctx.analysis, resolved.ctx.block, resolved.item, target, new_value)
end

-- M.resolve over a [r1, r2] line range: the prompt target for renaming every selected entry
-- to one description (`current` defaults to their shared text, "" when they differ). Entry
-- lines only, so a ranged rename never touches the ambiguous activity grouping.
function M.resolve_range(lines, r1, r2)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  local rows = support.entry_rows_in_range(ctx.block, r1, r2)
  if #rows == 0 then
    return nil, M.NO_ENTRIES_IN_RANGE
  end

  return { kind = "item", current = source_description(ctx.block, rows) or "", candidates = {} }
end

-- M.run over a [r1, r2] line range: rename every selected entry to `new_value`, rebuilding
-- the summary via build_rename's item path, so distinct descriptions collapse to the new text.
function M.run_range(lines, r1, r2, new_value)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  local rows = support.entry_rows_in_range(ctx.block, r1, r2)
  if #rows == 0 then
    return nil, M.NO_ENTRIES_IN_RANGE
  end

  local item = { text = "", source_entry_rows = rows }
  return build_rename(ctx.analysis, ctx.block, item, { kind = "item" }, new_value)
end

return M
