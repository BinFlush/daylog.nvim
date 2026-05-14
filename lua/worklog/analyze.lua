local M = {}

-- Semantic analyzer for parsed worklog documents.
--
-- This layer turns syntax nodes into worklog blocks, semantic entries, entry
-- items with attached note lines, and structured diagnostics. It is the main
-- source of truth for command-time behavior.

local INVALID_FIRST_HEADER_MESSAGE = "worklog: first line must be a worklog header such as --- worklog --- or --- worklog default=#label ---"
local UNEXPECTED_DEFAULT_LABEL_MESSAGE = "worklog: only the first worklog header may declare a default label"
local UNEXPECTED_QUANTIZE_MESSAGE = "worklog: only the first worklog header may declare quantize=<minutes>"
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

local function semantic_entry(item)
  return {
    row = item.entry.row,
    minutes = item.minutes,
    text = item.text,
    explicit_label = item.explicit_label,
    label = item.label,
    excluded = item.excluded,
  }
end

local function semantic_entry_from_node(node, default_label)
  local label = node.explicit_label or default_label

  return {
    row = node.row,
    minutes = node.minutes,
    text = node.text,
    explicit_label = node.explicit_label,
    label = label,
    excluded = label == "ooo",
  }
end

local function analyze_worklog_items(block, diagnostics)
  local items = {}
  local entries = {}
  local current = nil

  for _, node in ipairs(block.body_nodes) do
    if node.kind == "entry" then
      local entry = semantic_entry_from_node(node, block.default_label)

      current = {
        kind = "entry_item",
        entry = node,
        nodes = { node },
        start_row = node.row,
        end_row = node.row,
        minutes = entry.minutes,
        text = entry.text,
        explicit_label = entry.explicit_label,
        label = entry.label,
        excluded = entry.excluded,
      }
      table.insert(items, current)
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

  for i = 2, #items do
    if items[i].minutes < items[i - 1].minutes then
      push_diagnostic(diagnostics, {
        code = "unordered_timestamps",
        severity = "error",
        row = items[i - 1].row or items[i - 1].start_row,
        row2 = items[i].row or items[i].start_row,
        message = "timestamps are not in non-decreasing order",
      })
      break
    end
  end

  return items, entries
end

local function is_worklog_header(node)
  return node.kind == "worklog_header"
end

local function is_header(node)
  return node.kind == "worklog_header" or node.kind == "block_header"
end

local function is_structural_diagnostic(diagnostic)
  return diagnostic.code == "invalid_first_header"
    or diagnostic.code == "unexpected_default_label"
    or diagnostic.code == "unexpected_quantize"
    or diagnostic.code == "invalid_worklog_header_option"
end

local function is_block_diagnostic(diagnostic)
  return diagnostic.code == "invalid_entry" or diagnostic.code == "unordered_timestamps"
end

local function interpret_worklog_header(header, diagnostics)
  local result = {
    default_label = nil,
    quantize_minutes = nil,
    declared_default = false,
    declared_quantize = false,
  }

  for _, token in ipairs(header.option_tokens or {}) do
    if token.key == "default" then
      if result.declared_default then
        push_diagnostic(diagnostics, {
          code = "invalid_worklog_header_option",
          severity = "error",
          row = header.row,
          message = "duplicate worklog header option: default",
        })
      else
        result.declared_default = true
        local default_label = token.value:match("^#([%w_%-]+)$")

        if not default_label then
          push_diagnostic(diagnostics, {
            code = "invalid_worklog_header_option",
            severity = "error",
            row = header.row,
            message = "worklog header option default must be in the form default=#label",
          })
        else
          result.default_label = default_label
        end
      end
    elseif token.key == "quantize" then
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

        if not quantize_minutes or quantize_minutes <= 0 or quantize_minutes ~= math.floor(quantize_minutes) then
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
      code = "invalid_worklog_header_option",
      severity = "error",
      row = header.row,
      message = "worklog header options must use key=value: " .. token,
    })
  end

  return result
end

function M.is_worklog(block)
  return block.kind == "worklog_block"
end

function M.entry_from_node(node, default_label)
  if node.kind ~= "entry" then
    return nil
  end

  return semantic_entry_from_node(node, default_label)
end

function M.entries_from_nodes(nodes, default_label)
  local entries = {}

  for _, node in ipairs(nodes) do
    if node.kind == "invalid_entry" then
      return nil, {
        row = node.row,
        message = node.message,
      }
    end

    local entry = M.entry_from_node(node, default_label)
    if entry then
      table.insert(entries, entry)
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
  local default_label = nil
  local quantize_minutes = DEFAULT_QUANTIZE_MINUTES

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
    local first_options = interpreted_headers[1]

    if first.row ~= 1 or not is_worklog_header(first) then
      push_diagnostic(diagnostics, {
        code = "invalid_first_header",
        severity = "error",
        row = first.row,
        message = INVALID_FIRST_HEADER_MESSAGE,
      })
    else
      default_label = first_options.default_label
      if first_options.quantize_minutes ~= nil then
        quantize_minutes = first_options.quantize_minutes
      end
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
      header_default_label = interpreted_header.default_label,
      header_quantize_minutes = interpreted_header.quantize_minutes,
      default_label = is_worklog_header(header) and default_label or nil,
      quantize_minutes = is_worklog_header(header) and quantize_minutes or nil,
    }

    block.body_nodes = body_nodes(document, block)

    if M.is_worklog(block) then
      if i > 1 and interpreted_header.declared_default then
        push_diagnostic(diagnostics, {
          code = "unexpected_default_label",
          severity = "error",
          row = header.row,
          message = UNEXPECTED_DEFAULT_LABEL_MESSAGE,
        })
      end

      if i > 1 and interpreted_header.declared_quantize then
        push_diagnostic(diagnostics, {
          code = "unexpected_quantize",
          severity = "error",
          row = header.row,
          message = UNEXPECTED_QUANTIZE_MESSAGE,
        })
      end

      block.items, block.entries = analyze_worklog_items(block, diagnostics)
      table.insert(worklog_blocks, block)
    end

    table.insert(blocks, block)
  end

  return {
    kind = "analysis",
    document = document,
    default_label = default_label,
    quantize_minutes = quantize_minutes,
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
    if is_block_diagnostic(diagnostic) and diagnostic.row >= block.start_row and diagnostic.row < block.end_row then
      return diagnostic
    end
  end

  return nil
end

return M
