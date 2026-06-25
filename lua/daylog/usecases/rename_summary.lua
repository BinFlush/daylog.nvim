local analyze = require("daylog.analyze")
local entry = require("daylog.entry")
local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_cursor = require("daylog.usecases.summary_cursor")
local support = require("daylog.usecases.support")
local syntax = require("daylog.syntax")

local M = {}

-- Rename a single entry's text, or a #tag / @location, propagating into the log.
--
-- Rename edits the journal at the source -- one entry's description, or a metadata
-- token everywhere it is effective. It deliberately does NOT act on an activity summary
-- row: that row groups entries that resolve to one string by different means (a bare
-- entry's description, or a mapped entry's `=> alias`), so a bulk rename through it is
-- ambiguous and would overwrite the distinct descriptions a mapping deliberately keeps.
-- Relabel an activity for the report with :DaylogMap (non-destructive); fix journal text
-- by renaming the entries. So a cursor resolves to:
--
--   * an entry line -> that one entry's activity text;
--   * a tag-total row -> that #tag everywhere it is effective;
--   * a location-total row -> that @location everywhere it is effective;
--   * an activity summary row -> refused (M.REFUSE_ACTIVITY_ROW).
--
-- Tag/location renames are value substitutions: only the header token and the
-- explicit tokens that named the old value are rewritten. Sticky inheritance is
-- preserved automatically -- an entry that inherited the old value now inherits
-- the new one from the same (rewritten) source -- so unrelated lines are left
-- untouched. Only lines whose canonical rendering actually changes are edited.

M.NOT_A_ROW = "daylog: put the cursor on an entry, or a tag or location row, to rename it"
M.REFUSE_ACTIVITY_ROW = "daylog: rename an entry to fix its text, or :DaylogMap to relabel "
  .. "an activity for the report"
M.CANNOT_TOTALS = "daylog: a totals row cannot be renamed"
M.CANNOT_UNTAGGED = "daylog: the (untagged) group cannot be renamed; tag the entries first"
M.CANNOT_NO_LOCATION =
  "daylog: the (no location) group cannot be renamed; set a location on the entries first"
M.INVALID_NAME = "daylog: a tag or location name must be letters, digits, underscores, or hyphens"
M.EMPTY_TEXT = "daylog: the activity text cannot be empty"
M.SAME_NAME = "daylog: the new name matches the current name"

-- Classify a summary layout row into a rename target { kind, current } -- a #tag or
-- @location total. An activity summary row (SUMMARY_ITEM) is refused: rename does not act
-- on the ambiguous activity grouping (see the module header); :DaylogMap relabels it. This
-- is the single chokepoint for both the cursor (resolve_context) and report (report_cursor)
-- paths; the entry-line branch builds its target without classify, so it is not refused. PURE.
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

-- The other same-kind values in the recomputed summary, in display order, as merge
-- targets for the rename picker: renaming to one of them folds the two together
-- (rename and merge are the same value substitution). Tags and locations offer the
-- other tag/location totals; an activity offers the other activity texts under the
-- same tag (so picking one actually merges -- the rename keeps the tag). The current
-- value and the placeholder buckets (nil tag/location) are excluded.
local function merge_candidates(recomputed, kind, current, current_tag)
  local seen = {}
  local candidates = {}

  local function add(value)
    if value ~= nil and value ~= current and not seen[value] then
      seen[value] = true
      candidates[#candidates + 1] = value
    end
  end

  if kind == "tag" then
    for _, item in ipairs(recomputed.tag_totals or {}) do
      add(item.tag)
    end
  elseif kind == "location" then
    for _, item in ipairs(recomputed.location_totals or {}) do
      add(item.location)
    end
  else
    for _, item in ipairs(recomputed.summary_items or {}) do
      if item.tag == current_tag then
        add(item.text)
      end
    end
  end

  return candidates
end

-- The shared description behind a set of source entries, or nil when they disagree. An
-- aliased row is labeled by its alias (` => label`), but rename edits the description, so
-- the prompt should default to that description rather than the alias. For a single entry
-- this is just that entry's text.
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
  local result, resolve_err = summary_cursor.resolve(lines, cursor_row)
  if result then
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

  -- In the summary region but not on a selectable row -- surface that, don't reinterpret
  -- the cursor as an entry.
  if resolve_err then
    return nil, resolve_err
  end

  local ctx, ctx_err = support.get_validated_active(lines)
  if not ctx then
    return nil, ctx_err or M.NOT_A_ROW
  end

  for _, entry_item in ipairs(ctx.block.entry_items) do
    if entry_item.start_row == cursor_row then
      local region, recomputed = support.locate_summary(ctx.analysis, ctx.block)
      return {
        ctx = ctx,
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
  end

  return nil, M.NOT_A_ROW
end

-- Resolve the cursor to a rename target for the shell to prompt with: { kind,
-- current, candidates }. `candidates` are the other same-kind values to merge into.
-- Unlike the raw summary_cursor.resolve, every failure carries a user-facing message.
function M.resolve(lines, cursor_row)
  local context, err = resolve_context(lines, cursor_row)
  if not context then
    return nil, err
  end

  local target = context.target

  -- Prompt with the entries' own description (rename edits `a`, the description), not the
  -- alias the row is labeled by; fall back to the label when the descriptions disagree.
  if target.kind == "item" then
    local description = source_description(context.ctx.block, context.item.source_entry_rows)
    if description ~= nil then
      target.current = description
    end
  end

  target.candidates = merge_candidates(context.recomputed, target.kind, target.current, target.tag)
  return target
end

-- A valid #tag / @location name: the token grammar (document.lua), minus the bare
-- "-" that would render as the #-/@- clear token.
local function valid_name(name)
  return type(name) == "string" and name:match("^[%w_%-]+$") ~= nil and name ~= "-"
end

-- Walk the block's entries with the renamed sticky state, re-rendering the
-- affected entry lines whose canonical form changes, and build the renamed
-- semantic entries the rebuilt summary is computed from. `ops` carries the
-- per-kind rename functions and the affected-entry predicate.
local function build_source_edits(block, ops)
  local edits = {}
  local renamed_entrys = support.modified_entries(block, function(copy)
    copy.tag = ops.rename_tag(copy.tag)
    copy.location = ops.rename_loc(copy.location)
    copy.workday_excluded = copy.tag == syntax.OUT_OF_OFFICE_TAG
    copy.text = ops.text_for(copy.row, copy.text)
  end)

  -- Walk the entries in source order resolving raw sticky state through the one
  -- analyzer rule, then apply the rename to each resolved value. This matches
  -- renaming as we walk: rename(nil) = nil and the resolver yields prev/explicit/nil
  -- per field, so renaming the result equals inheriting an already-renamed current.
  -- A rename never touches the UTC offset; it is threaded raw so the re-emitted lines
  -- carry the same utc±H tokens (emit-on-change) the originals did. `prev` is the raw
  -- sticky state before the entry, so the emit-on-change baseline is its renamed form.
  local prev = {
    tag = block.header_tag,
    location = block.header_location,
    offset = block.header_offset,
  }

  for _, item in ipairs(block.entry_items) do
    local resolved = analyze.resolve_sticky(prev, item)
    local eff_tag = ops.rename_tag(resolved.tag)
    local eff_location = ops.rename_loc(resolved.location)

    if ops.affected(item) then
      -- Re-emit from the canonical field set (preserving the entry's own nudge / !L)
      -- with only the rename's transforms applied.
      local fields = analyze.copy_fields(item)
      fields.text = ops.text_for(item.start_row, item.text)
      fields.tag = eff_tag
      fields.location = eff_location
      fields.offset = resolved.offset
      fields.workday_excluded = eff_tag == syntax.OUT_OF_OFFICE_TAG
      local line =
        entry.format(fields, ops.rename_tag(prev.tag), ops.rename_loc(prev.location), prev.offset)

      -- An entry that only inherited the renamed value renders identically (it
      -- still has no token), so only emit an edit when the line truly changes.
      if line ~= item.entry.raw then
        table.insert(edits, {
          start_index = item.start_row - 1,
          end_index = item.start_row,
          lines = { line },
        })
      end
    end

    prev = resolved
  end

  return edits, renamed_entrys
end

-- Identity rename used for fields a given rename does not touch.
local function identity(value)
  return value
end

-- Build the rename edit script for one log block: rewrite the affected source
-- entries (and the header token when it declared the renamed value), then rebuild
-- the one summary in place. `item` is the recomputed summary item the rename acts
-- on and `region` is its summary's location; `target.kind` selects the rename mode.
-- Shared by the cursor-driven M.run and the value-driven M.run_by_value.
local function build_rename(block, region, item, target, new_value)
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

    -- Rename exactly the entries in source_entry_rows -- for an entry-line cursor that is the
    -- one entry; a same-named sibling or the closing entry is never swept in.
    local rows = {}
    for _, row in ipairs(item.source_entry_rows or {}) do
      rows[row] = true
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

  -- Rebuild the one summary from the renamed entries and replace it in place. A renamed
  -- single entry can sit in a log with no summary block yet; then there is nothing to
  -- rebuild (a later refresh creates it) and only the source edit applies.
  if region then
    local rebuilt = summary.summarize_entries(renamed_entrys, block.quantize_minutes)
    local rendered =
      render.summary_lines(rebuilt, block.duration_format, support.summary_render_options(block))
    table.insert(edits, {
      start_index = region.start_row - 1,
      end_index = region.end_row - 1,
      lines = rendered,
    })
  end

  -- The summary rebuild targets higher rows than the source edits, so apply
  -- highest-first to avoid index drift when the summary changes size.
  table.sort(edits, function(a, b)
    return a.start_index > b.start_index
  end)

  return { edits = edits }
end

-- Find the recomputed summary item a value-keyed target names, or nil when the
-- log has no such item. For an activity the tag scopes the match (the same text
-- under a different tag is a different item), mirroring how the summary groups rows.
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
    -- An activity is matched by text + tag. The cursor and report UIs refuse activity rows
    -- in classify, so this branch serves run_by_value as a complete value-keyed primitive.
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

  return build_rename(context.ctx.block, context.region, context.item, context.target, new_value)
end

-- Rename by value rather than by cursor: act on the active log's summary item
-- identified by `target` ({ kind, current, tag? }). Returns the edit script; nil
-- with no error when the value is not present in this log (the day is simply
-- unaffected, so the multi-day rename skips it); or nil + err when the log is
-- invalid. This is what lets one rename fan out across every day of a report.
function M.run_by_value(lines, target, new_value)
  local ctx, err = support.get_validated_active(lines)
  if not ctx then
    return nil, err
  end

  local region, recomputed = support.locate_summary(ctx.analysis, ctx.block)
  if not region then
    return nil, nil
  end

  local item = find_target_item(recomputed, target)
  if not item then
    return nil, nil
  end

  return build_rename(ctx.block, region, item, target, new_value)
end

return M
