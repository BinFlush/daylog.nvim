local analyze = require("worklog.analyze")
local entry = require("worklog.entry")
local render = require("worklog.render")
local summary = require("worklog.summary")
local summary_cursor = require("worklog.usecases.summary_cursor")
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

-- Classify the resolved layout row into a rename target { kind, current }.
local function classify(layout_row)
  local kind = layout_row.kind
  local item = layout_row.item

  if kind == render.LAYOUT_KIND.SUMMARY_ITEM then
    return { kind = "item", current = item.text or "" }
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

  local target, classify_err = classify(result.layout_row)
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
  local renamed_entries = {}

  for _, semantic_entry in ipairs(block.entries) do
    local copy = analyze.copy_fields(semantic_entry)
    copy.row = semantic_entry.row
    copy.tag = ops.rename_tag(copy.tag)
    copy.location = ops.rename_loc(copy.location)
    copy.workday_excluded = copy.tag == syntax.OUT_OF_OFFICE_TAG
    copy.text = ops.text_for(semantic_entry.row, copy.text)
    table.insert(renamed_entries, copy)
  end

  local current_tag = ops.rename_tag(block.header_tag)
  local current_location = ops.rename_loc(block.header_location)
  -- A rename never touches the UTC offset; thread it only so the re-emitted lines
  -- carry the same utc±H tokens (emit-on-change) the originals did.
  local current_offset = block.header_offset

  for _, item in ipairs(block.entry_items) do
    local eff_tag
    if item.explicit_tag_clear then
      eff_tag = nil
    elseif item.explicit_tag ~= nil then
      eff_tag = ops.rename_tag(item.explicit_tag)
    else
      eff_tag = current_tag
    end

    local eff_location
    if item.explicit_location_clear then
      eff_location = nil
    elseif item.explicit_location ~= nil then
      eff_location = ops.rename_loc(item.explicit_location)
    else
      eff_location = current_location
    end

    if ops.affected(item) then
      local line = entry.format({
        minutes = item.minutes,
        text = ops.text_for(item.start_row, item.text),
        tag = eff_tag,
        location = eff_location,
        offset = item.offset,
        workday_excluded = eff_tag == syntax.OUT_OF_OFFICE_TAG,
        logged = item.logged,
      }, current_tag, current_location, current_offset)

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

    current_tag = eff_tag
    current_location = eff_location
    current_offset = item.offset
  end

  return edits, renamed_entries
end

-- Identity rename used for fields a given rename does not touch.
local function identity(value)
  return value
end

function M.run(lines, cursor_row, new_value)
  local result, err = summary_cursor.resolve(lines, cursor_row)
  if not result then
    return nil, err or M.NOT_A_ROW
  end

  local target, classify_err = classify(result.layout_row)
  if not target then
    return nil, classify_err
  end

  local block = result.ctx.block
  local item = result.layout_row.item

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
  local rendered = render.summary_lines(rebuilt, block.duration_format, {
    leading_blank = false,
    quantize_minutes = block.quantize_minutes,
  })
  table.insert(edits, {
    start_index = result.region.start_row - 1,
    end_index = result.region.end_row - 1,
    lines = rendered,
  })

  -- The summary rebuild targets higher rows than the source edits, so apply
  -- highest-first to avoid index drift when the summary changes size.
  table.sort(edits, function(a, b)
    return a.start_index > b.start_index
  end)

  return { edits = edits }
end

return M
