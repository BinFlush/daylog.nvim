local M = {}

local function hours_string(minutes)
  return string.format("%.2fh", minutes / 60)
end

local function item_text(item, default_label)
  local parts = {}

  if item.text ~= "" then
    table.insert(parts, item.text)
  end

  if item.label and item.label ~= default_label and not item.excluded then
    table.insert(parts, "#" .. item.label)
  end

  if item.excluded then
    table.insert(parts, "(ooo)")
  end

  return table.concat(parts, " ")
end

local function summary_line(prefix, item, default_label)
  local text = item_text(item, default_label)

  if text == "" then
    return prefix
  end

  return string.format("%s %s", prefix, text)
end

local function label_text(item)
  if item.label == nil then
    return "(unlabeled)"
  end

  return "#" .. item.label
end

local function label_line(prefix, item)
  return string.format("%s %s", prefix, label_text(item))
end

local function extend_lines(target, source)
  for _, line in ipairs(source) do
    table.insert(target, line)
  end
end

function M.worklog_lines(lines)
  local rendered = {
    "",
    "--- worklog ---",
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
      table.insert(lines, summary_line(string.format("%s (%+dm)", hours_string(item.duration), item.error_minutes or 0), item, summary.default_label))
    else
      table.insert(lines, summary_line(hours_string(item.duration), item, summary.default_label))
    end
  end

  table.insert(lines, "")

  if kind == "exact" then
    table.insert(lines, "--- labels exact ---")

    for _, item in ipairs(summary.label_items or {}) do
      table.insert(lines, label_line(hours_string(item.duration), item))
    end

    table.insert(lines, "")
  elseif kind == "quantized" then
    table.insert(lines, "--- labels quantized ---")

    for _, item in ipairs(summary.label_items or {}) do
      table.insert(lines, label_line(string.format("%s (%+dm)", hours_string(item.duration), item.error_minutes or 0), item))
    end

    table.insert(lines, "")
  end

  table.insert(lines, "--- totals" .. header_suffix .. " ---")

  if kind == "quantized" then
    table.insert(lines, string.format("%s (%+dm) activity", hours_string(summary.activity_total), summary.activity_error_minutes or 0))
    table.insert(lines, string.format("%s (%+dm) workday", hours_string(summary.workday_total), summary.workday_error_minutes or 0))
  else
    table.insert(lines, string.format("%s activity", hours_string(summary.activity_total)))
    table.insert(lines, string.format("%s workday", hours_string(summary.workday_total)))
  end

  return lines
end

return M
