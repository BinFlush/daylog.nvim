local M = {}

local WORKLOG_HEADER = "--- worklog ---"

local function parse_header(line)
  local default_label = line:match("^%-%-%- worklog default=#([%w_%-]+) %-%-%-$")
  if default_label then
    return {
      header = line,
      is_worklog = true,
      default_label = default_label,
    }
  end

  if line == WORKLOG_HEADER then
    return {
      header = line,
      is_worklog = true,
    }
  end

  if line:match("^%-%-%- .+ %-%-%-$") then
    return {
      header = line,
      is_worklog = false,
    }
  end

  return nil
end

local function is_worklog(block)
  return block.is_worklog == true
end

function M.is_worklog(block)
  return is_worklog(block)
end

function M.parse(lines)
  local headers = {}
  local blocks = {
    default_label = nil,
    error = nil,
  }

  for i, line in ipairs(lines) do
    local header = parse_header(line)
    if header then
      header.start_row = i
      header.body_start_row = i + 1
      table.insert(headers, header)
    end
  end

  if #headers == 0 then
    return blocks
  end

  local first = headers[1]

  if first.start_row ~= 1 or not first.is_worklog then
    blocks.error = "worklog: first line must be --- worklog --- or --- worklog default=#label ---"
  else
    blocks.default_label = first.default_label
  end

  for i, block in ipairs(headers) do
    local next_block = headers[i + 1]

    block.end_row = next_block and next_block.start_row or (#lines + 1)
    table.insert(blocks, block)

    if i > 1 and block.is_worklog and block.default_label and not blocks.error then
      blocks.error = "worklog: only the first worklog header may declare a default label"
    end
  end

  return blocks
end

function M.get_active_worklog(blocks)
  local active = nil

  for _, block in ipairs(blocks) do
    if is_worklog(block) then
      active = block
    end
  end

  return active
end

function M.get_worklog_at_row(blocks, row)
  for _, block in ipairs(blocks) do
    if is_worklog(block) and row >= block.body_start_row and row < block.end_row then
      return block
    end
  end

  return nil
end

function M.get_body_lines(lines, block)
  local result = {}

  for i = block.body_start_row, block.end_row - 1 do
    table.insert(result, lines[i])
  end

  return result
end

function M.trim_empty_lines(lines)
  local start_index = 1
  local end_index = #lines

  while start_index <= #lines and lines[start_index] == "" do
    start_index = start_index + 1
  end

  while end_index >= start_index and lines[end_index] == "" do
    end_index = end_index - 1
  end

  local result = {}

  for i = start_index, end_index do
    table.insert(result, lines[i])
  end

  return result
end

function M.get_insert_index(block)
  return block.end_row - 1
end

return M
