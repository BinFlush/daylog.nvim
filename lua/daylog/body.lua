local analyze = require("daylog.analyze")
local syntax = require("daylog.syntax")

local M = {}

-- Rewrites semantic log blocks back into editable bodies, deriving canonical/sorted
-- lines and insert points from block items rather than reparsing raw lines.

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

-- Clone a block item, re-attaching the structural fields copy_fields drops (row, index,
-- lines) as explicit params since call sites source them differently.
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
  local first_item_row = block.entry_items[1] and block.entry_items[1].start_row or math.huge

  for _, node in ipairs(block.body_nodes) do
    if node.row < first_item_row then
      table.insert(preamble_lines, node.raw)
    end
  end

  for index, item in ipairs(block.entry_items) do
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
  format_entry
)
  local lines = {}
  local current_tag = header_tag
  local current_location = header_location
  local current_offset = header_offset

  for _, line in ipairs(preamble_lines) do
    table.insert(lines, line)
  end

  for _, item in ipairs(items) do
    table.insert(lines, format_entry(item, current_tag, current_location, current_offset))
    current_tag = item.tag
    current_location = item.location
    current_offset = item.offset

    for i = 2, #item.lines do
      table.insert(lines, item.lines[i])
    end
  end

  return trim_trailing_empty_lines(lines)
end

-- Order by effective UTC time, index breaking ties stably; both :Daylog order's reorder
-- and its change-warning use this one rule so they can't diverge.
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

  -- Sort by effective UTC time so :Daylog order agrees with the unordered-timestamps check.
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

-- The block's last non-blank body line; appending here keeps trailing blank lines as
-- separation. Returns the header row for an entry-less block.
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
  for _, item in ipairs(block.entry_items) do
    if item.minutes > minutes then
      return item.start_row - 1
    end
  end

  -- Append after the last non-blank line so trailing blanks stay as separation.
  return M.last_content_row(block)
end

function M.state_before(block, minutes)
  local state = {
    tag = block.header_tag,
    location = block.header_location,
    offset = block.header_offset,
  }

  -- Insertion is placed after existing equal timestamps by the written local clock (raw
  -- minutes, not effective UTC), so the sticky state includes every item at the same minute.
  for _, item in ipairs(block.entry_items) do
    if item.minutes > minutes then
      break
    end

    state.tag = item.tag
    state.location = item.location
    state.offset = item.offset
  end

  return state
end

-- Entries whose effective tag/location would change when the block is sorted by time
-- (as { minutes, text }), so :Daylog order can warn; empty when sorting is unambiguous.
function M.sort_changes_metadata(block)
  local order = {}
  for index, item in ipairs(block.entry_items) do
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

  for _, entry in ipairs(order) do
    local item = entry.item
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

-- Body rewrites are infallible: explicit #- and @- tokens make sticky-to-nil
-- transitions representable in canonical output.
function M.normalized_lines(block, format_entry)
  local body = rewrite_body(block)
  return rebuild_lines(
    body.preamble_lines,
    body.items,
    block.header_tag,
    block.header_location,
    block.header_offset,
    format_entry
  )
end

function M.sorted_lines(block, format_entry)
  local body = rewrite_body(block)
  return rebuild_lines(
    body.preamble_lines,
    sorted_items(body.items),
    block.header_tag,
    block.header_location,
    block.header_offset,
    format_entry
  )
end

return M
