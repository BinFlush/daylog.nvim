local analyze = require("daylog.analyze")
local document = require("daylog.document")
local syntax = require("daylog.syntax")

local M = {}

-- Semantic entry codec: parses one timestamped entry line into semantic data and
-- formats it back into a canonical source line.

function M.minutes_string(minutes)
  return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

function M.format(entry, current_tag, current_location, current_offset)
  local parts = { M.minutes_string(entry.minutes) }

  if entry.text ~= "" then
    table.insert(parts, entry.text)
  end

  -- A mapping alias (` => label`) reports under its target; it sits right after the description
  -- so trailing metadata still attaches, and may be multi-word (`=>` then label).
  if entry.alias and entry.alias ~= "" then
    table.insert(parts, "=>")
    table.insert(parts, entry.alias)
  end

  if entry.tag ~= current_tag then
    if entry.tag == nil then
      table.insert(parts, syntax.TAG_CLEAR_TOKEN)
    else
      table.insert(parts, "#" .. entry.tag)
    end
  end

  if entry.location ~= current_location then
    if entry.location == nil then
      table.insert(parts, syntax.LOCATION_CLEAR_TOKEN)
    else
      table.insert(parts, "@" .. entry.location)
    end
  end

  -- The offset emits on change like #tag/@location but has no clear token, so a nil offset
  -- emits nothing. Token order: `#tag @location utc±H round±N !S !T !L !W`.
  if entry.offset ~= nil and entry.offset ~= current_offset then
    table.insert(parts, syntax.utc_offset_token(entry.offset))
  end

  -- The rounding nudge is per-entry and non-sticky: emitted when nonzero, never inherited.
  if entry.nudge and entry.nudge ~= 0 then
    table.insert(parts, syntax.round_nudge_token(entry.nudge))
  end

  -- Logged markers ride in one compact token in `S T L W` order (`!S60T120L90W480`; bare `!S`);
  -- parsing still accepts the separated `!S60 !T120` form.
  local logged = syntax.format_logged(entry.logged)
  if logged then
    table.insert(parts, logged)
  end

  return table.concat(parts, " ")
end

function M.parse(line, current_tag, current_location, current_offset)
  local node = document.parse_line(line)

  if node.kind == syntax.NODE_KIND.INVALID_ENTRY then
    return false, node.message
  end

  local entry = analyze.entry_from_node(node, current_tag, current_location, current_offset)
  if not entry then
    return nil
  end

  return analyze.copy_fields(entry)
end

-- Defer to document's exported control-token grammar rather than forking the patterns,
-- so a future control token stays parenthesized automatically.
local function is_dangerous_token(token)
  return document.classify_control_token(token) ~= nil
end

-- Make `text` safe as activity text so it can't grow trailing metadata: parenthesize each
-- control token in the trailing run (the parser peels metadata from the end) so the scan
-- stops at a plain word; mid-text tokens (e.g. "fix #flaky tests") are left untouched.
function M.sanitize_text(text)
  text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    return text
  end

  local tokens = {}
  for token in text:gmatch("%S+") do
    -- "=>" is the alias separator; wrap every such token so sanitized text can never grow an alias.
    if token == "=>" then
      token = "(=>)"
    end
    table.insert(tokens, token)
  end

  for i = #tokens, 1, -1 do
    if is_dangerous_token(tokens[i]) then
      tokens[i] = "(" .. tokens[i] .. ")"
    else
      break
    end
  end

  return table.concat(tokens, " ")
end

-- Make `value` safe as an alias label: same trailing-metadata and `=>` hazards as activity
-- text, so defer to sanitize_text; "" for an empty value (a cleared mapping).
function M.sanitize_alias(value)
  return M.sanitize_text(value or "")
end

return M
