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
    explicit_tag_clear = entry.explicit_tag_clear,
    explicit_location = entry.explicit_location,
    explicit_location_clear = entry.explicit_location_clear,
    tag = entry.tag,
    location = entry.location,
    workday_excluded = entry.workday_excluded,
    logged = entry.logged,
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

  if entry.tag ~= current_tag then
    if entry.tag == nil then
      table.insert(parts, "#-")
    else
      table.insert(parts, "#" .. entry.tag)
    end
  end

  if entry.location ~= current_location then
    if entry.location == nil then
      table.insert(parts, "@-")
    else
      table.insert(parts, "@" .. entry.location)
    end
  end

  if entry.logged then
    table.insert(parts, "!L")
  end

  return table.concat(parts, " ")
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
