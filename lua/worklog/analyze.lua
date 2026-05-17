local M = {}

-- Semantic analyzer for parsed worklog documents.
--
-- This layer turns syntax nodes into worklog blocks, semantic entries, entry
-- items with attached note lines, and structured diagnostics. It is the main
-- source of truth for command-time behavior.

local INVALID_FIRST_HEADER_MESSAGE =
  "worklog: first line must be a worklog header such as --- worklog --- or --- worklog #ClientA @office quantize=30 ---"
local DEFAULT_QUANTIZE_MINUTES = 15

local function push_diagnostic(diagnostics, diagnostic)
  table.insert(diagnostics, diagnostic)
end

local function body_nodes(document, block)
  local nodes = {}

  for row = block.body_start_row, block.end_row - 1 do
    table.insert(nodes, document.nodes[row])
  end

  return nodes
end

local function semantic_entry_from_node(node, current_tag, current_location)
  local tag = current_tag
  local location = current_location

  if node.explicit_tag_clear then
    tag = nil
  elseif node.explicit_tag ~= nil then
    tag = node.explicit_tag
  end

  if node.explicit_location_clear then
    location = nil
  elseif node.explicit_location ~= nil then
    location = node.explicit_location
  end

  return {
    row = node.row,
    minutes = node.minutes,
    text = node.text,
    explicit_tag = node.explicit_tag,
    explicit_tag_clear = node.explicit_tag_clear,
    explicit_location = node.explicit_location,
    explicit_location_clear = node.explicit_location_clear,
    tag = tag,
    location = location,
    workday_excluded = tag == "ooo",
  }
end

local function analyze_entry_items(block, diagnostics)
  local entry_items = {}
  local entries = {}
  local current = nil
  local current_tag = block.header_tag
  local current_location = block.header_location

  for _, node in ipairs(block.body_nodes) do
    if node.kind == "entry" then
      local entry = semantic_entry_from_node(node, current_tag, current_location)

      current_tag = entry.tag
      current_location = entry.location

      current = {
        kind = "entry_item",
        entry = node,
        nodes = { node },
        start_row = node.row,
        end_row = node.row,
        minutes = entry.minutes,
        text = entry.text,
        explicit_tag = entry.explicit_tag,
        explicit_tag_clear = entry.explicit_tag_clear,
        explicit_location = entry.explicit_location,
        explicit_location_clear = entry.explicit_location_clear,
        tag = entry.tag,
        location = entry.location,
        workday_excluded = entry.workday_excluded,
      }
      table.insert(entry_items, current)
      table.insert(entries, entry)
    elseif node.kind == "note_line" or node.kind == "blank_line" then
      if current then
        table.insert(current.nodes, node)
        current.end_row = node.row
      end
    elseif node.kind == "invalid_entry" then
      push_diagnostic(diagnostics, {
        code = "invalid_entry",
        severity = "error",
        row = node.row,
        message = node.message,
      })
      current = nil
    else
      current = nil
    end
  end

  for i = 2, #entry_items do
    if entry_items[i].minutes < entry_items[i - 1].minutes then
      push_diagnostic(diagnostics, {
        code = "unordered_timestamps",
        severity = "error",
        row = entry_items[i - 1].row or entry_items[i - 1].start_row,
        row2 = entry_items[i].row or entry_items[i].start_row,
        message = "timestamps are not in non-decreasing order",
      })
      break
    end
  end

  return entry_items, entries
end

local function is_worklog_header(node)
  return node.kind == "worklog_header"
end

local function is_header(node)
  return node.kind == "worklog_header" or node.kind == "block_header"
end

local function is_structural_diagnostic(diagnostic)
  return diagnostic.code == "invalid_first_header"
    or diagnostic.code == "invalid_worklog_header_option"
    or diagnostic.code == "invalid_worklog_header_metadata"
    or diagnostic.code == "invalid_worklog_header_token"
end

local function is_block_diagnostic(diagnostic)
  return diagnostic.code == "invalid_entry" or diagnostic.code == "unordered_timestamps"
end

local function interpret_worklog_header(header, diagnostics)
  local result = {
    tag = nil,
    has_tag = false,
    location = nil,
    has_location = false,
    quantize_minutes = nil,
    declared_quantize = false,
  }

  for _, token in ipairs(header.metadata_tokens or {}) do
    if token.kind == "tag" then
      if result.has_tag then
        push_diagnostic(diagnostics, {
          code = "invalid_worklog_header_metadata",
          severity = "error",
          row = header.row,
          message = "multiple worklog header tags are not allowed",
        })
      else
        result.has_tag = true
        result.tag = token.value
      end
    elseif token.kind == "location" then
      if result.has_location then
        push_diagnostic(diagnostics, {
          code = "invalid_worklog_header_metadata",
          severity = "error",
          row = header.row,
          message = "multiple worklog header locations are not allowed",
        })
      else
        result.has_location = true
        result.location = token.value
      end
    end
  end

  for _, token in ipairs(header.option_tokens or {}) do
    if token.key == "quantize" then
      if result.declared_quantize then
        push_diagnostic(diagnostics, {
          code = "invalid_worklog_header_option",
          severity = "error",
          row = header.row,
          message = "duplicate worklog header option: quantize",
        })
      else
        result.declared_quantize = true
        local quantize_minutes = tonumber(token.value)

        if
          not quantize_minutes
          or quantize_minutes <= 0
          or quantize_minutes ~= math.floor(quantize_minutes)
        then
          push_diagnostic(diagnostics, {
            code = "invalid_worklog_header_option",
            severity = "error",
            row = header.row,
            message = "worklog header option quantize must be a positive integer",
          })
        else
          result.quantize_minutes = quantize_minutes
        end
      end
    else
      push_diagnostic(diagnostics, {
        code = "invalid_worklog_header_option",
        severity = "error",
        row = header.row,
        message = "unknown worklog header option: " .. token.key,
      })
    end
  end

  for _, token in ipairs(header.invalid_tokens or {}) do
    push_diagnostic(diagnostics, {
      code = "invalid_worklog_header_token",
      severity = "error",
      row = header.row,
      message = "worklog header tokens must be #tag, @location, or key=value: " .. token,
    })
  end

  return result
end

function M.is_worklog(block)
  return block.kind == "worklog_block"
end

function M.entry_from_node(node, current_tag, current_location)
  if node.kind ~= "entry" then
    return nil
  end

  return semantic_entry_from_node(node, current_tag, current_location)
end

function M.entries_from_nodes(nodes, current_tag, current_location)
  local entries = {}
  local tag = current_tag
  local location = current_location

  for _, node in ipairs(nodes) do
    if node.kind == "invalid_entry" then
      return nil, {
        row = node.row,
        message = node.message,
      }
    end

    local entry = M.entry_from_node(node, tag, location)
    if entry then
      table.insert(entries, entry)
      tag = entry.tag
      location = entry.location
    end
  end

  return entries
end

function M.structural_error(analysis)
  for _, diagnostic in ipairs(analysis.diagnostics) do
    if is_structural_diagnostic(diagnostic) then
      return diagnostic.message
    end
  end

  return nil
end

function M.analyze(document)
  local diagnostics = {}
  local header_nodes = {}
  local interpreted_headers = {}
  local blocks = {}
  local worklog_blocks = {}

  for _, node in ipairs(document.nodes) do
    if is_header(node) then
      table.insert(header_nodes, node)
    end
  end

  for i, header in ipairs(header_nodes) do
    if is_worklog_header(header) then
      interpreted_headers[i] = interpret_worklog_header(header, diagnostics)
    else
      interpreted_headers[i] = nil
    end
  end

  if #header_nodes > 0 then
    local first = header_nodes[1]

    if first.row ~= 1 or not is_worklog_header(first) then
      push_diagnostic(diagnostics, {
        code = "invalid_first_header",
        severity = "error",
        row = first.row,
        message = INVALID_FIRST_HEADER_MESSAGE,
      })
    end
  end

  for i, header in ipairs(header_nodes) do
    local next_header = header_nodes[i + 1]
    local interpreted_header = interpreted_headers[i] or {}
    local block = {
      kind = is_worklog_header(header) and "worklog_block" or "generic_block",
      header = header,
      start_row = header.row,
      body_start_row = header.row + 1,
      end_row = next_header and next_header.row or (document.row_count + 1),
      header_tag = interpreted_header.tag,
      header_location = interpreted_header.location,
      header_quantize_minutes = interpreted_header.quantize_minutes,
      quantize_minutes = is_worklog_header(header)
          and (interpreted_header.quantize_minutes or DEFAULT_QUANTIZE_MINUTES)
        or nil,
    }

    block.body_nodes = body_nodes(document, block)

    if M.is_worklog(block) then
      block.entry_items, block.entries = analyze_entry_items(block, diagnostics)
      table.insert(worklog_blocks, block)
    end

    table.insert(blocks, block)
  end

  return {
    kind = "analysis",
    document = document,
    diagnostics = diagnostics,
    blocks = blocks,
    worklog_blocks = worklog_blocks,
  }
end

function M.get_active_worklog(analysis)
  return analysis.worklog_blocks[#analysis.worklog_blocks]
end

function M.get_worklog_at_row(analysis, row)
  for _, block in ipairs(analysis.worklog_blocks) do
    if row >= block.start_row and row < block.end_row then
      return block
    end
  end

  return nil
end

function M.find_block_diagnostic(analysis, block)
  for _, diagnostic in ipairs(analysis.diagnostics) do
    if
      is_block_diagnostic(diagnostic)
      and diagnostic.row >= block.start_row
      and diagnostic.row < block.end_row
    then
      return diagnostic
    end
  end

  return nil
end

return M
