local M = {}

local function hours_string(minutes)
  return string.format("%.2fh", minutes / 60)
end

local function item_text(item)
  local parts = {}

  if item.text ~= "" then
    table.insert(parts, item.text)
  end

  if item.tag then
    table.insert(parts, "#" .. item.tag)
  end

  if item.location then
    table.insert(parts, "@" .. item.location)
  end

  return table.concat(parts, " ")
end

local function summary_line(prefix, item)
  local text = item_text(item)

  if text == "" then
    return prefix
  end

  return string.format("%s %s", prefix, text)
end

local function tag_text(item)
  if item.tag == nil then
    return "(untagged)"
  end

  return "#" .. item.tag
end

local function location_text(item)
  if item.location == nil then
    return "(no location)"
  end

  return "@" .. item.location
end

local function tag_line(prefix, item)
  return string.format("%s %s", prefix, tag_text(item))
end

local function location_line(prefix, item)
  return string.format("%s %s", prefix, location_text(item))
end

local function extend_lines(target, source)
  for _, line in ipairs(source) do
    table.insert(target, line)
  end
end

local function has_metadata_items(items, field)
  for _, item in ipairs(items or {}) do
    if item[field] ~= nil then
      return true
    end
  end

  return false
end

local function has_excluded_items(items)
  for _, item in ipairs(items or {}) do
    if item.excluded then
      return true
    end
  end

  return false
end

function M.worklog_lines(lines, header_tag, header_location, header_quantize_minutes)
  local header = { "--- worklog" }

  if header_tag then
    table.insert(header, "#" .. header_tag)
  end

  if header_location then
    table.insert(header, "@" .. header_location)
  end

  if header_quantize_minutes then
    table.insert(header, "quantize=" .. tostring(header_quantize_minutes))
  end

  local rendered = {
    "",
    table.concat(header, " ") .. " ---",
  }

  extend_lines(rendered, lines)

  return rendered
end

function M.summary_lines(summary, kind)
  local header_suffix = kind == "quantized" and " quantized" or " exact"
  local lines = {}

  table.insert(lines, "")
  table.insert(lines, "--- summary" .. header_suffix .. " ---")

  for _, item in ipairs(summary.items) do
    if kind == "quantized" then
      table.insert(lines, summary_line(string.format("%s (%+dm)", hours_string(item.duration), item.error_minutes or 0), item))
    else
      table.insert(lines, summary_line(hours_string(item.duration), item))
    end
  end

  table.insert(lines, "")

  if kind == "exact" then
    if has_metadata_items(summary.tag_items, "tag") then
      table.insert(lines, "--- tags exact ---")

      for _, item in ipairs(summary.tag_items or {}) do
        table.insert(lines, tag_line(hours_string(item.duration), item))
      end

      table.insert(lines, "")
    end

    if has_metadata_items(summary.location_items, "location") then
      table.insert(lines, "--- locations exact ---")

      for _, item in ipairs(summary.location_items or {}) do
        table.insert(lines, location_line(hours_string(item.duration), item))
      end

      table.insert(lines, "")
    end
  elseif kind == "quantized" then
    if has_metadata_items(summary.tag_items, "tag") then
      table.insert(lines, "--- tags quantized ---")

      for _, item in ipairs(summary.tag_items or {}) do
        table.insert(lines, tag_line(string.format("%s (%+dm)", hours_string(item.duration), item.error_minutes or 0), item))
      end

      table.insert(lines, "")
    end

    if has_metadata_items(summary.location_items, "location") then
      table.insert(lines, "--- locations quantized ---")

      for _, item in ipairs(summary.location_items or {}) do
        table.insert(lines, location_line(string.format("%s (%+dm)", hours_string(item.duration), item.error_minutes or 0), item))
      end

      table.insert(lines, "")
    end
  end

  table.insert(lines, "--- totals" .. header_suffix .. " ---")

  if kind == "quantized" then
    if has_excluded_items(summary.items) then
      table.insert(lines, string.format("%s (%+dm) activity", hours_string(summary.activity_total), summary.activity_error_minutes or 0))
    end

    table.insert(lines, string.format("%s (%+dm) workday", hours_string(summary.workday_total), summary.workday_error_minutes or 0))
  else
    if has_excluded_items(summary.items) then
      table.insert(lines, string.format("%s activity", hours_string(summary.activity_total)))
    end

    table.insert(lines, string.format("%s workday", hours_string(summary.workday_total)))
  end

  return lines
end

return M
