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
    explicit_tag = entry.explicit_tag,
    explicit_location = entry.explicit_location,
    tag = entry.tag,
    location = entry.location,
    excluded = entry.excluded,
  }
end

function M.minutes_string(minutes)
  return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

function M.format(entry, current_tag, current_location)
  local parts = { M.minutes_string(entry.minutes) }

  if entry.text ~= "" then
    table.insert(parts, entry.text)
  end

  if entry.tag and entry.tag ~= current_tag then
    table.insert(parts, "#" .. entry.tag)
  end

  if entry.location and entry.location ~= current_location then
    table.insert(parts, "@" .. entry.location)
  end

  return table.concat(parts, " ")
end

function M.is_representable(entry, current_tag, current_location)
  if entry.tag == nil and current_tag ~= nil then
    return false, "worklog: cannot repeat an untagged entry after sticky tag has been set"
  end

  if entry.location == nil and current_location ~= nil then
    return false, "worklog: cannot repeat an entry without location after sticky location has been set"
  end

  return true
end

function M.parse(line, current_tag, current_location)
  local node = document.parse_line(line)

  if node.kind == "invalid_entry" then
    return false, node.message
  end

  local entry = analyze.entry_from_node(node, current_tag, current_location)
  if not entry then
    return nil
  end

  return semantic_entry(entry)
end

return M
