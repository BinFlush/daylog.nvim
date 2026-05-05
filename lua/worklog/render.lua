local M = {}

local function hours_string(minutes)
  return string.format("%.2fh", minutes / 60)
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
    local item_suffix = item.excluded and " (ooo)" or ""

    if kind == "quantized" then
      table.insert(lines, string.format("%s (%+dm) %s%s", hours_string(item.duration), item.error_minutes or 0, item.text, item_suffix))
    else
      table.insert(lines, string.format("%s %s%s", hours_string(item.duration), item.text, item_suffix))
    end
  end

  table.insert(lines, "")
  table.insert(lines, "--- totals" .. header_suffix .. " ---")
  table.insert(lines, string.format("%s activity", hours_string(summary.activity_total)))
  table.insert(lines, string.format("%s workday", hours_string(summary.workday_total)))

  return lines
end

return M
