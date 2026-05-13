local analyze = require("worklog.analyze")
local document = require("worklog.document")

local M = {}

-- Semantic worklog entry codec.
--
-- This module is responsible for the smallest meaningful worklog unit: a single
-- timestamped entry line. It parses one source line into semantic entry data
-- and formats semantic entries back into canonical source lines.

local function semantic_entry(entry)
  return {
    minutes = entry.minutes,
    text = entry.text,
    label = entry.label,
    excluded = entry.excluded,
  }
end

function M.minutes_string(minutes)
  return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

function M.format(entry, default_label)
  local parts = { M.minutes_string(entry.minutes) }

  if entry.text ~= "" then
    table.insert(parts, entry.text)
  end

  if entry.label == "ooo" then
    table.insert(parts, "#ooo")
  elseif entry.label and entry.label ~= default_label then
    table.insert(parts, "#" .. entry.label)
  end

  return table.concat(parts, " ")
end

function M.parse(line, default_label)
  local node = document.parse_line(line)

  if node.kind == "invalid_entry" then
    return false, node.message
  end

  local entry = analyze.entry_from_node(node, default_label)
  if not entry then
    return nil
  end

  return semantic_entry(entry)
end

return M
