local M = {}

local MISSING_LABEL_MESSAGE = "missing label; add a trailing #label or declare a default label in the first worklog header"

-- Worklog ordering operates on normalized timestamped items rather than raw
-- lines. A timestamped line owns all following non-timestamped lines until the
-- next timestamped line, while preamble lines before the first timestamp stay
-- outside of any item.
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

local function finalize_item(item)
  if not item then
    return nil
  end

  item.lines = trim_trailing_empty_lines(item.lines)
  return item
end

function M.parse_items(lines, start_row, parse_time_line)
  local preamble_lines = {}
  local items = {}
  local current = nil

  for i, line in ipairs(lines) do
    local entry, err = parse_time_line(line)

    if entry == false then
      return {
        preamble_lines = preamble_lines,
        items = items,
        error = {
          row = start_row + i - 1,
          message = err,
        },
      }
    end

    if entry then
      current = finalize_item(current)
      if current then
        table.insert(items, current)
      end

      current = {
        minutes = entry.minutes,
        text = entry.text,
        label = entry.label,
        excluded = entry.excluded,
        row = start_row + i - 1,
        index = #items + 1,
        lines = { line },
      }
    elseif current then
      table.insert(current.lines, line)
    else
      table.insert(preamble_lines, line)
    end
  end

  current = finalize_item(current)
  if current then
    table.insert(items, current)
  end

  for i = 1, #items - 1 do
    if items[i].label == nil then
      return {
        preamble_lines = preamble_lines,
        items = items,
        error = {
          row = items[i].row,
          message = MISSING_LABEL_MESSAGE,
        },
      }
    end
  end

  return {
    preamble_lines = preamble_lines,
    items = items,
  }
end

function M.find_unordered_rows(items)
  for i = 2, #items do
    if items[i].minutes < items[i - 1].minutes then
      return items[i - 1].row, items[i].row
    end
  end

  return nil
end

function M.get_insert_row(items, minutes, default_row)
  -- Equal timestamps are allowed, so new entries are placed after any existing
  -- item with the same time and before the first later item.
  for _, item in ipairs(items) do
    if item.minutes > minutes then
      return item.row - 1
    end
  end

  return default_row
end

local function rebuild_lines(preamble_lines, items, default_label, format_time_line)
  local lines = {}

  for _, line in ipairs(preamble_lines) do
    table.insert(lines, line)
  end

  for _, item in ipairs(items) do
    if format_time_line then
      table.insert(lines, format_time_line(item, default_label))
      for i = 2, #item.lines do
        table.insert(lines, item.lines[i])
      end
    else
      for _, line in ipairs(item.lines) do
        table.insert(lines, line)
      end
    end
  end

  return trim_trailing_empty_lines(lines)
end

function M.normalized_lines(parsed, default_label, format_time_line)
  return rebuild_lines(parsed.preamble_lines, parsed.items, default_label, format_time_line)
end

function M.sorted_lines(parsed, default_label, format_time_line)
  local items = vim.deepcopy(parsed.items)

  -- Preserve original order for equal timestamps so WorklogOrder stays stable.
  table.sort(items, function(a, b)
    if a.minutes == b.minutes then
      return a.index < b.index
    end

    return a.minutes < b.minutes
  end)

  return rebuild_lines(parsed.preamble_lines, items, default_label, format_time_line)
end

return M
