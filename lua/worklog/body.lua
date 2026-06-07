local analyze = require("worklog.analyze")
local syntax = require("worklog.syntax")

local M = {}

-- Worklog body reconstruction helpers.
--
-- This module owns rewriting semantic worklog blocks back into editable block
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
    local copy = analyze.copy_fields(item)
    copy.row = item.start_row
    copy.index = index
    copy.lines = trim_trailing_empty_lines(lines_from_nodes(item.nodes))
    table.insert(items, copy)
  end

  return {
    preamble_lines = preamble_lines,
    items = items,
  }
end

local function rebuild_lines(preamble_lines, items, header_tag, header_location, format_entry)
  local lines = {}
  local current_tag = header_tag
  local current_location = header_location

  for _, line in ipairs(preamble_lines) do
    table.insert(lines, line)
  end

  for _, item in ipairs(items) do
    table.insert(lines, format_entry(item, current_tag, current_location))
    current_tag = item.tag
    current_location = item.location

    for i = 2, #item.lines do
      table.insert(lines, item.lines[i])
    end
  end

  return trim_trailing_empty_lines(lines)
end

local function sorted_items(items)
  local result = {}

  for _, item in ipairs(items) do
    local lines = {}

    for _, line in ipairs(item.lines) do
      table.insert(lines, line)
    end

    local copy = analyze.copy_fields(item)
    copy.row = item.row
    copy.index = item.index
    copy.lines = lines
    table.insert(result, copy)
  end

  table.sort(result, function(a, b)
    if a.minutes == b.minutes then
      return a.index < b.index
    end

    return a.minutes < b.minutes
  end)

  return result
end

-- The block's last non-blank body line. Appending here keeps trailing blank lines
-- (a visual gap before the summary) as separation instead of stepping past them;
-- notes stay with their entry, only blank lines are skipped. Returns the header row
-- for an entry-less block.
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

  -- Append after the block's last non-blank body line, so trailing blank lines stay
  -- as separation instead of pushing the new entry past them.
  return M.last_content_row(block)
end

function M.state_before(block, minutes)
  local state = {
    tag = block.header_tag,
    location = block.header_location,
  }

  -- Inserted entries are placed after existing equal timestamps, so the sticky
  -- state before insertion includes every item at the same minute.
  for _, item in ipairs(block.entry_items) do
    if item.minutes > minutes then
      break
    end

    state.tag = item.tag
    state.location = item.location
  end

  return state
end

-- The entries whose effective tag or location would change when the block is
-- sorted by time. Each entry item carries its buffer-order effective metadata;
-- this re-resolves sticky state in time-sorted order and reports every entry
-- that differs (as { minutes, text }), so :WorklogOrder can warn that it set
-- those values from the original order. Empty when sorting is unambiguous.
function M.sort_changes_metadata(block)
  local order = {}
  for index, item in ipairs(block.entry_items) do
    table.insert(order, { index = index, item = item })
  end

  table.sort(order, function(a, b)
    if a.item.minutes == b.item.minutes then
      return a.index < b.index
    end

    return a.item.minutes < b.item.minutes
  end)

  local tag = block.header_tag
  local location = block.header_location
  local changed = {}

  for _, entry in ipairs(order) do
    local item = entry.item

    if item.explicit_tag_clear then
      tag = nil
    elseif item.explicit_tag ~= nil then
      tag = item.explicit_tag
    end

    if item.explicit_location_clear then
      location = nil
    elseif item.explicit_location ~= nil then
      location = item.explicit_location
    end

    if tag ~= item.tag or location ~= item.location then
      table.insert(changed, { minutes = item.minutes, text = item.text })
    end
  end

  return changed
end

-- Body rewrites are intentionally infallible now that explicit #- and @-
-- tokens make sticky-to-nil transitions representable in canonical output.
function M.normalized_lines(block, format_entry)
  local body = rewrite_body(block)
  return rebuild_lines(
    body.preamble_lines,
    body.items,
    block.header_tag,
    block.header_location,
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
    format_entry
  )
end

return M
