local M = {}

local function decimal_hours_string(minutes)
  return string.format("%.2fh", minutes / 60)
end

local function hhmm_string(minutes)
  return string.format("%d:%02d", math.floor(minutes / 60), minutes % 60)
end

local function duration_string(minutes, duration_format)
  if duration_format == "hhmm" then
    return hhmm_string(minutes)
  end

  return decimal_hours_string(minutes)
end

local function summary_item_label(item, show_tag)
  local parts = {}

  if item.text ~= "" then
    table.insert(parts, item.text)
  end

  if show_tag and item.tag then
    table.insert(parts, "#" .. item.tag)
  end

  return table.concat(parts, " ")
end

local function summary_line(prefix, item, show_tag)
  local text = summary_item_label(item, show_tag)

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

local function text_tag_conflicts(items)
  local tags_by_text = {}
  local conflicts = {}

  for _, item in ipairs(items or {}) do
    local key = item.tag == nil and "\31" or item.tag
    local text_tags = tags_by_text[item.text]

    if not text_tags then
      text_tags = {}
      tags_by_text[item.text] = text_tags
    elseif not text_tags[key] then
      conflicts[item.text] = true
    end

    text_tags[key] = true
  end

  return conflicts
end

local function has_metadata_items(items, field)
  for _, item in ipairs(items or {}) do
    if item[field] ~= nil then
      return true
    end
  end

  return false
end

local function has_workday_excluded_items(items)
  for _, item in ipairs(items or {}) do
    if item.workday_excluded then
      return true
    end
  end

  return false
end

local function section_headers(kind, options)
  local header_suffix = kind == "quantized" and " quantized" or " exact"
  options = options or {}

  return {
    summary = options.summary_header or ("--- summary" .. header_suffix .. " ---"),
    tag = options.tag_header or ("--- tags" .. header_suffix .. " ---"),
    location = options.location_header or ("--- locations" .. header_suffix .. " ---"),
    total = options.total_header or ("--- totals" .. header_suffix .. " ---"),
    leading_blank = options.leading_blank ~= false,
  }
end

local function append_summary_lines(lines, summary, kind, duration_format, options)
  local headers = section_headers(kind, options)
  local conflicts = text_tag_conflicts(summary.summary_items)
  local format = duration_format or "decimal"

  if headers.leading_blank then
    table.insert(lines, "")
  end

  table.insert(lines, headers.summary)

  for _, item in ipairs(summary.summary_items) do
    if kind == "quantized" then
      table.insert(
        lines,
        summary_line(
          string.format(
            "%s (%+dm)",
            duration_string(item.duration, format),
            item.error_minutes or 0
          ),
          item,
          conflicts[item.text]
        )
      )
    else
      table.insert(
        lines,
        summary_line(duration_string(item.duration, format), item, conflicts[item.text])
      )
    end
  end

  table.insert(lines, "")

  if kind == "exact" then
    if has_metadata_items(summary.tag_totals, "tag") then
      table.insert(lines, headers.tag)

      for _, item in ipairs(summary.tag_totals or {}) do
        table.insert(lines, tag_line(duration_string(item.duration, format), item))
      end

      table.insert(lines, "")
    end

    if has_metadata_items(summary.location_totals, "location") then
      table.insert(lines, headers.location)

      for _, item in ipairs(summary.location_totals or {}) do
        table.insert(lines, location_line(duration_string(item.duration, format), item))
      end

      table.insert(lines, "")
    end
  elseif kind == "quantized" then
    if has_metadata_items(summary.tag_totals, "tag") then
      table.insert(lines, headers.tag)

      for _, item in ipairs(summary.tag_totals or {}) do
        table.insert(
          lines,
          tag_line(
            string.format(
              "%s (%+dm)",
              duration_string(item.duration, format),
              item.error_minutes or 0
            ),
            item
          )
        )
      end

      table.insert(lines, "")
    end

    if has_metadata_items(summary.location_totals, "location") then
      table.insert(lines, headers.location)

      for _, item in ipairs(summary.location_totals or {}) do
        table.insert(
          lines,
          location_line(
            string.format(
              "%s (%+dm)",
              duration_string(item.duration, format),
              item.error_minutes or 0
            ),
            item
          )
        )
      end

      table.insert(lines, "")
    end
  end

  table.insert(lines, headers.total)

  if kind == "quantized" then
    if has_workday_excluded_items(summary.summary_items) then
      table.insert(
        lines,
        string.format(
          "%s (%+dm) activity",
          duration_string(summary.activity_total, format),
          summary.activity_error_minutes or 0
        )
      )
    end

    table.insert(
      lines,
      string.format(
        "%s (%+dm) workday",
        duration_string(summary.workday_total, format),
        summary.workday_error_minutes or 0
      )
    )
  else
    if has_workday_excluded_items(summary.summary_items) then
      table.insert(
        lines,
        string.format("%s activity", duration_string(summary.activity_total, format))
      )
    end

    table.insert(lines, string.format("%s workday", duration_string(summary.workday_total, format)))
  end
end

function M.worklog_header_line(
  header_tag,
  header_location,
  header_quantize_minutes,
  header_duration_format
)
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

  if header_duration_format then
    table.insert(header, "duration=" .. header_duration_format)
  end

  return table.concat(header, " ") .. " ---"
end

function M.worklog_lines(
  lines,
  header_tag,
  header_location,
  header_quantize_minutes,
  header_duration_format
)
  local rendered = {
    "",
    M.worklog_header_line(
      header_tag,
      header_location,
      header_quantize_minutes,
      header_duration_format
    ),
  }

  extend_lines(rendered, lines)

  return rendered
end

function M.summary_lines(summary, kind, duration_format, options)
  local lines = {}
  append_summary_lines(lines, summary, kind, duration_format, options)
  return lines
end

function M.week_report_lines(report, duration_format)
  local lines = {}

  for index, day in ipairs(report.days) do
    append_summary_lines(lines, day.summary, "quantized", duration_format, {
      leading_blank = index > 1,
      summary_header = "--- day summary quantized " .. day.date_label .. " ---",
      tag_header = "--- day tags quantized " .. day.date_label .. " ---",
      location_header = "--- day locations quantized " .. day.date_label .. " ---",
      total_header = "--- day totals quantized " .. day.date_label .. " ---",
    })
  end

  append_summary_lines(lines, report.summary, "quantized", duration_format, {
    leading_blank = #lines > 0,
    summary_header = "--- week summary quantized " .. report.week_label .. " ---",
    tag_header = "--- week tags quantized " .. report.week_label .. " ---",
    location_header = "--- week locations quantized " .. report.week_label .. " ---",
    total_header = "--- week totals quantized " .. report.week_label .. " ---",
  })

  return lines
end

return M
