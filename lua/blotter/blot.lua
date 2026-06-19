local analyze = require("blotter.analyze")
local document = require("blotter.document")
local syntax = require("blotter.syntax")

local M = {}

-- Semantic worklog blot codec.
--
-- This module is responsible for the smallest meaningful worklog unit: a single
-- timestamped blot line. It parses one source line into semantic blot data
-- and formats semantic blots back into canonical source lines.

function M.minutes_string(minutes)
  return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

function M.format(blot, current_tag, current_location, current_offset)
  local parts = { M.minutes_string(blot.minutes) }

  if blot.text ~= "" then
    table.insert(parts, blot.text)
  end

  if blot.tag ~= current_tag then
    if blot.tag == nil then
      table.insert(parts, syntax.TAG_CLEAR_TOKEN)
    else
      table.insert(parts, "#" .. blot.tag)
    end
  end

  if blot.location ~= current_location then
    if blot.location == nil then
      table.insert(parts, syntax.LOCATION_CLEAR_TOKEN)
    else
      table.insert(parts, "@" .. blot.location)
    end
  end

  -- The offset is emitted on change like #tag/@location, but has no clear token:
  -- once set it is always a concrete value, so a nil offset (no offsets in play)
  -- emits nothing. The order is `#tag @location utc±H round±N !L`.
  if blot.offset ~= nil and blot.offset ~= current_offset then
    table.insert(parts, syntax.utc_offset_token(blot.offset))
  end

  -- The rounding nudge is per-blot and non-sticky (like !L): always emitted when
  -- nonzero, never inherited, no current_* comparison.
  if blot.nudge and blot.nudge ~= 0 then
    table.insert(parts, syntax.round_nudge_token(blot.nudge))
  end

  if blot.logged then
    table.insert(parts, syntax.LOGGED_TOKEN)
  end

  return table.concat(parts, " ")
end

function M.parse(line, current_tag, current_location, current_offset)
  local node = document.parse_line(line)

  if node.kind == syntax.NODE_KIND.INVALID_ENTRY then
    return false, node.message
  end

  local blot = analyze.entry_from_node(node, current_tag, current_location, current_offset)
  if not blot then
    return nil
  end

  return analyze.copy_fields(blot)
end

-- A control token is exactly what the parser peels from an blot's trailing run, so
-- defer to the one grammar document exports rather than forking the patterns here --
-- a future control token then stays parenthesized automatically.
local function is_dangerous_token(token)
  return document.classify_control_token(token) ~= nil
end

-- Make `text` safe to use as an blot's activity text so it can never grow
-- trailing metadata. The parser peels metadata by scanning whitespace tokens from
-- the end while they are control tokens (#tag, @loc, #-, @-, !L); wrap each token
-- in the trailing run of such tokens in parentheses so the scan stops at a plain
-- word. Mid-text tokens (e.g. "fix #flaky tests") are left untouched.
function M.sanitize_text(text)
  text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    return text
  end

  local tokens = {}
  for token in text:gmatch("%S+") do
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

return M
