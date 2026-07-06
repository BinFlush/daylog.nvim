local syntax = require("daylog.syntax")

local M = {}

-- Semantic analyzer for parsed log documents (PURE).
--
-- Turns syntax nodes into log blocks, semantic entries, entry items with attached notes, and
-- diagnostics; the source of truth for command-time behavior.

local INVALID_FIRST_HEADER_MESSAGE =
  "daylog: first line must be a log header such as --- log --- or --- log #ClientA @office q=30 ---"
local DEFAULT_DURATION_FORMAT = syntax.DURATION_DECIMAL

local function push_diagnostic(diagnostics, diagnostic)
  diagnostic.category = syntax.DIAGNOSTIC_CATEGORY_BY_CODE[diagnostic.code]
  table.insert(diagnostics, diagnostic)
end

-- Copy the mutable per-entry logged table ({ level -> committed minutes | true }) so working
-- entries never alias it.
local function copy_logged(logged)
  if logged == nil then
    return nil
  end

  local out = {}
  for level, committed in pairs(logged) do
    out[level] = committed
  end
  return out
end
M.copy_logged = copy_logged

-- Copy the semantic-entry field set from any source carrying it. Structural fields (row, index,
-- attached lines) are intentionally left out so callers add only what they need.
local function copy_fields(src)
  return {
    minutes = src.minutes,
    text = src.text,
    explicit_tag = src.explicit_tag,
    explicit_tag_clear = src.explicit_tag_clear,
    explicit_location = src.explicit_location,
    explicit_location_clear = src.explicit_location_clear,
    explicit_offset = src.explicit_offset,
    tag = src.tag,
    location = src.location,
    offset = src.offset,
    nudge = src.nudge,
    logged = copy_logged(src.logged),
    alias = src.alias,
  }
end

M.copy_fields = copy_fields

-- An entry's effective UTC time in minutes: the local clock minus its sticky UTC offset (identically
-- raw `minutes` when no offsets are in play). Durations and the ordering check use this; the 24:00
-- boundary, display, and insertion placement stay raw-local.
local function effective_minutes(item)
  return item.minutes - (item.offset or 0)
end

M.effective_minutes = effective_minutes

local function body_nodes(document, block)
  local nodes = {}

  for row = block.body_start_row, block.end_row - 1 do
    table.insert(nodes, document.nodes[row])
  end

  return nodes
end

-- Resolve an item's sticky metadata from the previous state: a clear token forces nil, an explicit
-- value switches, otherwise inherit (the offset is sticky but has no clear form). The single
-- definition of the clear/explicit/inherit rule, resolved through by analyzer, reorder, and rename.
local function resolve_sticky(prev, item)
  local tag = prev.tag
  if item.explicit_tag_clear then
    tag = nil
  elseif item.explicit_tag ~= nil then
    tag = item.explicit_tag
  end

  local location = prev.location
  if item.explicit_location_clear then
    location = nil
  elseif item.explicit_location ~= nil then
    location = item.explicit_location
  end

  local offset = prev.offset
  if item.explicit_offset ~= nil then
    offset = item.explicit_offset
  end

  return { tag = tag, location = location, offset = offset }
end

M.resolve_sticky = resolve_sticky

local function semantic_entry_from_node(node, current_tag, current_location, current_offset)
  local resolved = resolve_sticky(
    { tag = current_tag, location = current_location, offset = current_offset },
    node
  )

  return {
    row = node.row,
    minutes = node.minutes,
    text = node.text,
    explicit_tag = node.explicit_tag,
    explicit_tag_clear = node.explicit_tag_clear,
    explicit_location = node.explicit_location,
    explicit_location_clear = node.explicit_location_clear,
    explicit_offset = node.explicit_offset,
    tag = resolved.tag,
    location = resolved.location,
    offset = resolved.offset,
    -- The rounding nudge is per-entry and non-sticky, taken straight from the node.
    nudge = node.nudge,
    -- Per-entry, non-sticky logged state keyed by level, each holding committed minutes or `true`.
    -- Only the summary level (`s`) drives the summary today. Copied so it never aliases the node's table.
    logged = copy_logged(node.logged),
    -- A mapping alias (` => label`): per-entry, non-sticky, taken straight from the node.
    alias = node.alias,
  }
end

local function analyze_entry_items(block, diagnostics)
  local entry_items = {}
  local entries = {}
  local current = nil
  local current_tag = block.header_tag
  local current_location = block.header_location
  local current_offset = block.header_offset

  for _, node in ipairs(block.body_nodes) do
    if node.kind == syntax.NODE_KIND.ENTRY then
      local entry = semantic_entry_from_node(node, current_tag, current_location, current_offset)

      -- A blank entry may carry no reporting metadata (a utc offset is allowed); flag any that slipped in.
      if
        node.text == ""
        and (
          node.explicit_tag ~= nil
          or node.explicit_tag_clear
          or node.explicit_location ~= nil
          or node.explicit_location_clear
          or node.logged ~= nil
          or node.alias ~= nil
          or (node.nudge ~= nil and node.nudge ~= 0)
        )
      then
        push_diagnostic(diagnostics, {
          code = syntax.DIAGNOSTIC.BLANK_ENTRY_METADATA,
          severity = "error",
          row = node.row,
          message = "a blank entry cannot carry a tag, location, marker, alias, or round nudge",
        })
      end

      current_tag = entry.tag
      current_location = entry.location
      current_offset = entry.offset

      current = copy_fields(entry)
      current.kind = syntax.NODE_KIND.ENTRY_ITEM
      current.entry = node
      current.nodes = { node }
      current.start_row = node.row
      current.end_row = node.row
      table.insert(entry_items, current)
      table.insert(entries, entry)
    elseif node.kind == syntax.NODE_KIND.NOTE_LINE or node.kind == syntax.NODE_KIND.BLANK_LINE then
      if current then
        table.insert(current.nodes, node)
        current.end_row = node.row
      end
    elseif node.kind == syntax.NODE_KIND.INVALID_ENTRY then
      push_diagnostic(diagnostics, {
        code = syntax.DIAGNOSTIC.INVALID_ENTRY,
        severity = "error",
        row = node.row,
        message = node.message,
      })
      current = nil
    else
      current = nil
    end
  end

  -- Ordering is checked in effective UTC time, so a westward clock move is not flagged while a
  -- genuine real-time reversal still is.
  for i = 2, #entry_items do
    if effective_minutes(entry_items[i]) < effective_minutes(entry_items[i - 1]) then
      push_diagnostic(diagnostics, {
        code = syntax.DIAGNOSTIC.UNORDERED_TIMESTAMPS,
        severity = "error",
        row = entry_items[i - 1].start_row,
        row2 = entry_items[i].start_row,
        message = "timestamps are not in non-decreasing order",
      })
      break
    end
  end

  -- 24:00 is only the day's closing boundary, so it must be the final entry.
  for i = 1, #entry_items - 1 do
    if entry_items[i].minutes == syntax.END_OF_DAY_MINUTES then
      push_diagnostic(diagnostics, {
        code = syntax.DIAGNOSTIC.MIDNIGHT_NOT_FINAL,
        severity = "error",
        row = entry_items[i].start_row,
        message = "24:00 must be the final entry in a log block",
      })
      break
    end
  end

  -- A log is either timezone-naive or timezone-aware, never a mix: an offset after offset-free
  -- entries silently reinterprets the transition interval, so it is refused until the log is
  -- all-or-nothing. The first non-nil offset after a nil one is the only transition to catch.
  for i = 2, #entry_items do
    if entry_items[i].offset ~= nil and entry_items[i - 1].offset == nil then
      push_diagnostic(diagnostics, {
        code = syntax.DIAGNOSTIC.MIXED_OFFSET,
        severity = "error",
        row = entry_items[i].start_row,
        message = "a utc offset here follows offset-free entries; put the offset on the log "
          .. "header (or remove it) so the whole log is timezone-consistent",
      })
      break
    end
  end

  return entry_items, entries
end

local function is_log_header(node)
  return node.kind == syntax.NODE_KIND.LOG_HEADER
end

local function is_header(node)
  return node.kind == syntax.NODE_KIND.LOG_HEADER or node.kind == syntax.NODE_KIND.BLOCK_HEADER
end

-- Mark a single-valued header option `flag` as declared: on a repeat emit the duplicate diagnostic
-- and return false, else set the flag and return true. Only the duplicate check is shared.
local function declare_once(result, diagnostics, flag, label, row)
  if result[flag] then
    push_diagnostic(diagnostics, {
      code = syntax.DIAGNOSTIC.INVALID_LOG_HEADER_OPTION,
      severity = "error",
      row = row,
      message = "duplicate log header option: " .. label,
    })
    return false
  end

  result[flag] = true
  return true
end

-- The header metadata kinds that are first-wins and at-most-one: each names the result flag and
-- value field it sets, and the noun for its "multiple ... are not allowed" diagnostic.
local HEADER_METADATA = {
  [syntax.TOKEN_KIND.TAG] = { has = "has_tag", value = "tag", noun = "tags" },
  [syntax.TOKEN_KIND.LOCATION] = { has = "has_location", value = "location", noun = "locations" },
  [syntax.TOKEN_KIND.OFFSET] = { has = "has_offset", value = "offset", noun = "utc offsets" },
}

local function interpret_log_header(header, diagnostics)
  local result = {
    tag = nil,
    has_tag = false,
    location = nil,
    has_location = false,
    offset = nil,
    has_offset = false,
    quantize_minutes = nil,
    declared_quantize = false,
    duration_format = nil,
    declared_duration = false,
  }

  for _, token in ipairs(header.metadata_tokens or {}) do
    local spec = HEADER_METADATA[token.kind]
    if spec then
      if result[spec.has] then
        push_diagnostic(diagnostics, {
          code = syntax.DIAGNOSTIC.INVALID_LOG_HEADER_METADATA,
          severity = "error",
          row = header.row,
          message = "multiple log header " .. spec.noun .. " are not allowed",
        })
      else
        result[spec.has] = true
        result[spec.value] = token.value
      end
    end
  end

  for _, token in ipairs(header.option_tokens or {}) do
    if token.key == syntax.OPTION_QUANTIZE then
      if declare_once(result, diagnostics, "declared_quantize", "q", header.row) then
        local quantize_minutes = tonumber(token.value)

        -- tonumber accepts inf, hex, scientific, floats, and signs; require a plain digit run and
        -- cap at a day so only true positive integers are taken.
        if
          token.value:match("^%d+$") == nil
          or quantize_minutes <= 0
          or quantize_minutes > 1440
        then
          push_diagnostic(diagnostics, {
            code = syntax.DIAGNOSTIC.INVALID_LOG_HEADER_OPTION,
            severity = "error",
            row = header.row,
            message = "log header option q must be a positive integer of minutes (at most 1440)",
          })
        else
          result.quantize_minutes = quantize_minutes
        end
      end
    elseif token.key == syntax.OPTION_DURATION then
      if declare_once(result, diagnostics, "declared_duration", "d", header.row) then
        if not syntax.DURATION_FORMATS[token.value] then
          push_diagnostic(diagnostics, {
            code = syntax.DIAGNOSTIC.INVALID_LOG_HEADER_OPTION,
            severity = "error",
            row = header.row,
            message = "log header option d must be dec or hm",
          })
        else
          result.duration_format = token.value
        end
      end
    else
      push_diagnostic(diagnostics, {
        code = syntax.DIAGNOSTIC.INVALID_LOG_HEADER_OPTION,
        severity = "error",
        row = header.row,
        message = "unknown log header option: " .. token.key,
      })
    end
  end

  for _, token in ipairs(header.invalid_tokens or {}) do
    push_diagnostic(diagnostics, {
      code = syntax.DIAGNOSTIC.INVALID_LOG_HEADER_TOKEN,
      severity = "error",
      row = header.row,
      message = "log header tokens must be #tag, @location, utc±H[:MM], or key=value: " .. token,
    })
  end

  return result
end

function M.is_log(block)
  return block.kind == syntax.BLOCK_KIND.LOG
end

function M.entry_from_node(node, current_tag, current_location, current_offset)
  if node.kind ~= syntax.NODE_KIND.ENTRY then
    return nil
  end

  return semantic_entry_from_node(node, current_tag, current_location, current_offset)
end

function M.structural_error(analysis)
  for _, diagnostic in ipairs(analysis.diagnostics) do
    if diagnostic.category == syntax.DIAGNOSTIC_CATEGORY.STRUCTURAL then
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
  local log_blocks = {}

  for _, node in ipairs(document.nodes) do
    if is_header(node) then
      table.insert(header_nodes, node)
    end
  end

  for i, header in ipairs(header_nodes) do
    if is_log_header(header) then
      interpreted_headers[i] = interpret_log_header(header, diagnostics)
    else
      interpreted_headers[i] = nil
    end
  end

  if #header_nodes > 0 then
    local first = header_nodes[1]

    if first.row ~= 1 or not is_log_header(first) then
      push_diagnostic(diagnostics, {
        code = syntax.DIAGNOSTIC.INVALID_FIRST_HEADER,
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
      kind = is_log_header(header) and syntax.BLOCK_KIND.LOG or syntax.BLOCK_KIND.GENERIC,
      header = header,
      start_row = header.row,
      body_start_row = header.row + 1,
      end_row = next_header and next_header.row or (document.row_count + 1),
      header_tag = interpreted_header.tag,
      header_location = interpreted_header.location,
      header_offset = interpreted_header.offset,
      header_quantize_minutes = interpreted_header.quantize_minutes,
      header_duration_format = interpreted_header.duration_format,
      quantize_minutes = is_log_header(header)
          and (interpreted_header.quantize_minutes or syntax.DEFAULT_QUANTIZE_MINUTES)
        or nil,
      duration_format = is_log_header(header)
          and (interpreted_header.duration_format or DEFAULT_DURATION_FORMAT)
        or nil,
    }

    block.body_nodes = body_nodes(document, block)

    if M.is_log(block) then
      block.entry_items, block.entries = analyze_entry_items(block, diagnostics)
      table.insert(log_blocks, block)
    end

    table.insert(blocks, block)
  end

  return {
    kind = syntax.NODE_KIND.ANALYSIS,
    document = document,
    diagnostics = diagnostics,
    blocks = blocks,
    log_blocks = log_blocks,
  }
end

function M.get_active_log(analysis)
  return analysis.log_blocks[#analysis.log_blocks]
end

function M.get_log_at_row(analysis, row)
  for _, block in ipairs(analysis.log_blocks) do
    if row >= block.start_row and row < block.end_row then
      return block
    end
  end

  return nil
end

function M.find_block_diagnostic(analysis, block)
  for _, diagnostic in ipairs(analysis.diagnostics) do
    if
      diagnostic.category == syntax.DIAGNOSTIC_CATEGORY.BLOCK
      and diagnostic.row >= block.start_row
      and diagnostic.row < block.end_row
    then
      return diagnostic
    end
  end

  return nil
end

return M
