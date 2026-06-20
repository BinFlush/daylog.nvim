local analyze = require("blotter.analyze")
local syntax = require("blotter.syntax")

local M = {}

-- Blotter body reconstruction helpers.
--
-- This module owns rewriting semantic blotter blocks back into editable block
-- bodies. It derives canonical body lines, sorted body lines, and insert points
-- directly from semantic block items instead of reparsing raw lines.

local function trim_trailing_empty_lines(lines)
  local end_index = #lines

  while end_index > 0 and lines[end_index] == "" do
    end_index = end_index - 1
  end

  local result = {}

  for i = 1, end_index do
    table.insert(result, lines[i])
  end

  return result
end

local function lines_from_nodes(nodes)
  local lines = {}

  for _, node in ipairs(nodes) do
    table.insert(lines, node.raw)
  end

  return lines
end

-- Clone a block item through the canonical field set, re-attaching the structural
-- fields copy_fields deliberately drops: the source row, its order index, and its
-- lines. These three are explicit params because the call sites source them
-- differently (raw blot_items vs already-cloned, sorted items).
local function clone_item(item, row, index, lines)
  local copy = analyze.copy_fields(item)
  copy.row = row
  copy.index = index
  copy.lines = lines
  return copy
end

local function rewrite_body(block)
  local preamble_lines = {}
  local items = {}
  local first_item_row = block.blot_items[1] and block.blot_items[1].start_row or math.huge

  for _, node in ipairs(block.body_nodes) do
    if node.row < first_item_row then
      table.insert(preamble_lines, node.raw)
    end
  end

  for index, item in ipairs(block.blot_items) do
    table.insert(
      items,
      clone_item(
        item,
        item.start_row,
        index,
        trim_trailing_empty_lines(lines_from_nodes(item.nodes))
      )
    )
  end

  return {
    preamble_lines = preamble_lines,
    items = items,
  }
end

local function rebuild_lines(
  preamble_lines,
  items,
  header_tag,
  header_location,
  header_offset,
  format_blot
)
  local lines = {}
  local current_tag = header_tag
  local current_location = header_location
  local current_offset = header_offset

  for _, line in ipairs(preamble_lines) do
    table.insert(lines, line)
  end

  for _, item in ipairs(items) do
    table.insert(lines, format_blot(item, current_tag, current_location, current_offset))
    current_tag = item.tag
    current_location = item.location
    current_offset = item.offset

    for i = 2, #item.lines do
      table.insert(lines, item.lines[i])
    end
  end

  return trim_trailing_empty_lines(lines)
end

-- Order by effective UTC time, then by original index to break ties stably. Both
-- :BlotterOrder's reorder and its change-warning sort through this one rule, so a
-- divergence can't make the warning describe a different order than the rewrite.
local function less_by_effective_time(a_eff, a_index, b_eff, b_index)
  if a_eff == b_eff then
    return a_index < b_index
  end

  return a_eff < b_eff
end

local function sorted_items(items)
  local result = {}

  for _, item in ipairs(items) do
    local lines = {}

    for _, line in ipairs(item.lines) do
      table.insert(lines, line)
    end

    table.insert(result, clone_item(item, item.row, item.index, lines))
  end

  -- Sort by effective UTC time so :BlotterOrder agrees with the effective
  -- unordered-timestamps check; without offsets this is the raw-minute order.
  table.sort(result, function(a, b)
    return less_by_effective_time(
      analyze.effective_minutes(a),
      a.index,
      analyze.effective_minutes(b),
      b.index
    )
  end)

  return result
end

-- The block's last non-blank body line. Appending here keeps trailing blank lines
-- (a visual gap before the summary) as separation instead of stepping past them;
-- notes stay with their blot, only blank lines are skipped. Returns the header row
-- for an blot-less block.
function M.last_content_row(block)
  local row = block.start_row

  for _, node in ipairs(block.body_nodes) do
    if node.kind ~= syntax.NODE_KIND.BLANK_LINE then
      row = node.row
    end
  end

  return row
end

function M.insert_index(block, minutes)
  for _, item in ipairs(block.blot_items) do
    if item.minutes > minutes then
      return item.start_row - 1
    end
  end

  -- Append after the block's last non-blank body line, so trailing blank lines stay
  -- as separation instead of pushing the new blot past them.
  return M.last_content_row(block)
end

function M.state_before(block, minutes)
  local state = {
    tag = block.header_tag,
    location = block.header_location,
    offset = block.header_offset,
  }

  -- Inserted blots are placed after existing equal timestamps, so the sticky
  -- state before insertion includes every item at the same minute. Placement is by
  -- the written local clock (raw minutes): an insertion is positioned by the time
  -- the user typed, not by effective UTC.
  for _, item in ipairs(block.blot_items) do
    if item.minutes > minutes then
      break
    end

    state.tag = item.tag
    state.location = item.location
    state.offset = item.offset
  end

  return state
end

-- The blots whose effective tag or location would change when the block is
-- sorted by time. Each blot item carries its buffer-order effective metadata;
-- this re-resolves sticky state in time-sorted order and reports every blot
-- that differs (as { minutes, text }), so :BlotterOrder can warn that it set
-- those values from the original order. Empty when sorting is unambiguous.
function M.sort_changes_metadata(block)
  local order = {}
  for index, item in ipairs(block.blot_items) do
    table.insert(order, { index = index, item = item })
  end

  table.sort(order, function(a, b)
    return less_by_effective_time(
      analyze.effective_minutes(a.item),
      a.index,
      analyze.effective_minutes(b.item),
      b.index
    )
  end)

  local current = {
    tag = block.header_tag,
    location = block.header_location,
    offset = block.header_offset,
  }
  local changed = {}

  for _, blot in ipairs(order) do
    local item = blot.item
    current = analyze.resolve_sticky(current, item)

    if
      current.tag ~= item.tag
      or current.location ~= item.location
      or current.offset ~= item.offset
    then
      table.insert(changed, { minutes = item.minutes, text = item.text })
    end
  end

  return changed
end

-- Body rewrites are intentionally infallible now that explicit #- and @-
-- tokens make sticky-to-nil transitions representable in canonical output.
function M.normalized_lines(block, format_blot)
  local body = rewrite_body(block)
  return rebuild_lines(
    body.preamble_lines,
    body.items,
    block.header_tag,
    block.header_location,
    block.header_offset,
    format_blot
  )
end

function M.sorted_lines(block, format_blot)
  local body = rewrite_body(block)
  return rebuild_lines(
    body.preamble_lines,
    sorted_items(body.items),
    block.header_tag,
    block.header_location,
    block.header_offset,
    format_blot
  )
end

return M
