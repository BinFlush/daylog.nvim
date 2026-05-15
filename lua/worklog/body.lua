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

local function representable_error(item, current_tag, current_location)
  if item.tag == nil and current_tag ~= nil then
    return string.format(
      "worklog: cannot reorder entry at line %d because sticky tag cannot be cleared implicitly",
      item.row
    )
  end

  if item.location == nil and current_location ~= nil then
    return string.format(
      "worklog: cannot reorder entry at line %d because sticky location cannot be cleared implicitly",
      item.row
    )
  end

  return nil
end

local function rewrite_body(block)
  local preamble_lines = {}
  local items = {}
  local first_item_row = block.items[1] and block.items[1].start_row or math.huge

  for _, node in ipairs(block.body_nodes) do
    if node.row < first_item_row then
      table.insert(preamble_lines, node.raw)
    end
  end

  for index, item in ipairs(block.items) do
    table.insert(items, {
      minutes = item.minutes,
      text = item.text,
      tag = item.tag,
      location = item.location,
      excluded = item.excluded,
      row = item.start_row,
      index = index,
      lines = trim_trailing_empty_lines(lines_from_nodes(item.nodes)),
    })
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
    local err = representable_error(item, current_tag, current_location)
    if err then
      return nil, err
    end

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

    table.insert(result, {
      minutes = item.minutes,
      text = item.text,
      tag = item.tag,
      location = item.location,
      excluded = item.excluded,
      row = item.row,
      index = item.index,
      lines = lines,
    })
  end

  table.sort(result, function(a, b)
    if a.minutes == b.minutes then
      return a.index < b.index
    end

    return a.minutes < b.minutes
  end)

  return result
end

function M.insert_index(block, minutes)
  for _, item in ipairs(block.items) do
    if item.minutes > minutes then
      return item.start_row - 1
    end
  end

  return block.end_row - 1
end

function M.state_before(block, minutes)
  local state = {
    tag = block.header_tag,
    location = block.header_location,
  }

  for _, item in ipairs(block.items) do
    if item.minutes > minutes then
      break
    end

    state.tag = item.tag
    state.location = item.location
  end

  return state
end

function M.normalized_lines(block, format_entry)
  local body = rewrite_body(block)
  return rebuild_lines(body.preamble_lines, body.items, block.header_tag, block.header_location, format_entry)
end

function M.sorted_lines(block, format_entry)
  local body = rewrite_body(block)
  return rebuild_lines(body.preamble_lines, sorted_items(body.items), block.header_tag, block.header_location, format_entry)
end

return M
