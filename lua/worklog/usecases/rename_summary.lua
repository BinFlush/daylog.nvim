local analyze = require("worklog.analyze")
local entry = require("worklog.entry")
local render = require("worklog.render")
local summary = require("worklog.summary")
local summary_cursor = require("worklog.usecases.summary_cursor")
local support = require("worklog.usecases.support")
local syntax = require("worklog.syntax")

local M = {}

-- Rename what a summary row stands for, propagating into the attached worklog.
--
-- The rendered summary row is only a selector (see summary_cursor): the active
-- worklog is analyzed from source and the cursor row maps back to a recomputed
-- summary item. The rename then rewrites the *source* and rebuilds the one
-- summary, keeping the summary a pure projection.
--
--   * a main summary row renames the activity text of its source entries;
--   * a tag-total row renames that #tag everywhere it is effective;
--   * a location-total row renames that @location everywhere it is effective.
--
-- Tag/location renames are value substitutions: only the header token and the
-- explicit tokens that named the old value are rewritten. Sticky inheritance is
-- preserved automatically -- an entry that inherited the old value now inherits
-- the new one from the same (rewritten) source -- so unrelated lines are left
-- untouched. Only lines whose canonical rendering actually changes are edited.

M.NOT_A_ROW = "worklog: put the cursor on a summary item, tag, or location row to rename it"
M.CANNOT_TOTALS = "worklog: a totals row cannot be renamed"
M.CANNOT_UNTAGGED = "worklog: the (untagged) group cannot be renamed; tag the entries first"
M.CANNOT_NO_LOCATION =
  "worklog: the (no location) group cannot be renamed; set a location on the entries first"
M.INVALID_NAME = "worklog: a tag or location name must be letters, digits, underscores, or hyphens"
M.EMPTY_TEXT = "worklog: the activity text cannot be empty"
M.SAME_NAME = "worklog: the new name matches the current name"

-- Classify a summary layout row into a rename target { kind, current, tag? }. The
-- `tag` is the activity's tag scope (an item is identified by text *and* tag), used
-- by run_by_value / the report rename to find the same item in another worklog. The
-- single-file run ignores it (it acts on the cursor's exact item). PURE.
function M.classify(layout_row)
  local kind = layout_row.kind
  local item = layout_row.item

  if kind == render.LAYOUT_KIND.SUMMARY_ITEM then
    return { kind = "item", current = item.text or "", tag = item.tag }
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
local function merge_candidates(result, kind, current)
  local recomputed = result.recomputed
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
    local current_tag = result.layout_row.item.tag
    for _, item in ipairs(recomputed.summary_items or {}) do
      if item.tag == current_tag then
        add(item.text)
      end
    end
  end

  return candidates
end

-- Resolve the cursor to a rename target for the shell to prompt with: { kind,
-- current, candidates }. `candidates` are the other same-kind values to merge into.
-- Unlike the raw summary_cursor.resolve, every failure carries a user-facing message.
function M.resolve(lines, cursor_row)
  local result, err = summary_cursor.resolve(lines, cursor_row)
  if not result then
    return nil, err or M.NOT_A_ROW
  end

  local target, classify_err = M.classify(result.layout_row)
  if not target then
    return nil, classify_err
  end

  target.candidates = merge_candidates(result, target.kind, target.current)
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
  local renamed_entries = support.modified_entries(block, function(copy)
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

  return edits, renamed_entries
end

-- Identity rename used for fields a given rename does not touch.
local function identity(value)
  return value
end

-- Build the rename edit script for one worklog block: rewrite the affected source
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

  local edits, renamed_entries = build_source_edits(block, ops)

  -- The header carries the renamed tag/location only when it declared it.
  if header_field then
    local new_header = render.worklog_header_line(
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

  -- Rebuild the one summary from the renamed entries and replace it in place.
  local rebuilt = summary.summarize_entries(renamed_entries, block.quantize_minutes)
  local rendered =
    render.summary_lines(rebuilt, block.duration_format, support.summary_render_options(block))
  table.insert(edits, {
    start_index = region.start_row - 1,
    end_index = region.end_row - 1,
    lines = rendered,
  })

  -- The summary rebuild targets higher rows than the source edits, so apply
  -- highest-first to avoid index drift when the summary changes size.
  table.sort(edits, function(a, b)
    return a.start_index > b.start_index
  end)

  return { edits = edits }
end

-- Find the recomputed summary item a value-keyed target names, or nil when the
-- worklog has no such item. For an activity the tag scopes the match (the same text
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
    for _, item in ipairs(recomputed.summary_items or {}) do
      if (item.text or "") == target.current and item.tag == target.tag then
        return item
      end
    end
  end

  return nil
end

function M.run(lines, cursor_row, new_value)
  local result, err = summary_cursor.resolve(lines, cursor_row)
  if not result then
    return nil, err or M.NOT_A_ROW
  end

  local target, classify_err = M.classify(result.layout_row)
  if not target then
    return nil, classify_err
  end

  return build_rename(result.ctx.block, result.region, result.layout_row.item, target, new_value)
end

-- Rename by value rather than by cursor: act on the active worklog's summary item
-- identified by `target` ({ kind, current, tag? }). Returns the edit script; nil
-- with no error when the value is not present in this worklog (the day is simply
-- unaffected, so the multi-day rename skips it); or nil + err when the worklog is
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
