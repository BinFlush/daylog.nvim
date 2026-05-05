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
  return "#" .. item.label
end

function M.worklog_lines(lines)
  local rendered = {
    "",
    "--- worklog ---",
  }

  vim.list_extend(rendered, lines)

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
      table.insert(lines, string.format("%s %s", hours_string(item.duration), label_text(item)))
    end

    table.insert(lines, "")
  end

  table.insert(lines, "--- totals" .. header_suffix .. " ---")
  table.insert(lines, string.format("%s activity", hours_string(summary.activity_total)))
  table.insert(lines, string.format("%s workday", hours_string(summary.workday_total)))

  return lines
end

return M
