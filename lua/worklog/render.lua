local syntax = require("worklog.syntax")

local M = {}

local function decimal_hours_string(minutes)
  return string.format("%.2fh", minutes / 60)
end

local function hhmm_string(minutes)
  return string.format("%d:%02d", math.floor(minutes / 60), minutes % 60)
end

local function duration_string(minutes, duration_format)
  if duration_format == syntax.DURATION_HHMM then
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

  if item.logged then
    table.insert(parts, syntax.LOGGED_TOKEN)
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

local function logged_text(item)
  if item.logged then
    return "logged"
  end

  return "unlogged"
end

local function logged_line(prefix, item)
  return string.format("%s %s", prefix, logged_text(item))
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
  options = options or {}

  return {
    summary = options.summary_header or syntax.section_header("summary", kind),
    tag = options.tag_header or syntax.section_header("tags", kind),
    location = options.location_header or syntax.section_header("locations", kind),
    logged = options.logged_header or syntax.section_header("logged", kind),
    total = options.total_header or syntax.section_header("totals", kind),
    leading_blank = options.leading_blank ~= false,
  }
end

local function summary_item_line(item, kind, format, show_tag)
  if kind == "quantized" then
    return summary_line(
      string.format("%s (%+dm)", duration_string(item.duration, format), item.error_minutes or 0),
      item,
      show_tag
    )
  end

  return summary_line(duration_string(item.duration, format), item, show_tag)
end

local function metadata_line(item, kind, format, line_builder)
  if kind == "quantized" then
    return line_builder(
      string.format("%s (%+dm)", duration_string(item.duration, format), item.error_minutes or 0),
      item
    )
  end

  return line_builder(duration_string(item.duration, format), item)
end

-- Build a structured summary layout that records both rendered text and the
-- role each row plays.  Future commands can take a rendered summary row,
-- recompute the same layout, and recover the underlying summary item via the
-- `item` field.  `summary_lines` projects this layout to lines so user-facing
-- output stays in lockstep with the layout.
local function build_summary_layout(summary, kind, duration_format, options)
  local layout = {}
  local headers = section_headers(kind, options)
  local conflicts = text_tag_conflicts(summary.summary_items)
  local format = duration_format or syntax.DURATION_DECIMAL

  if headers.leading_blank then
    table.insert(layout, { kind = "blank", line = "" })
  end

  table.insert(layout, { kind = "header", section = "summary", line = headers.summary })

  for _, item in ipairs(summary.summary_items) do
    table.insert(layout, {
      kind = "summary_item",
      section = "summary",
      line = summary_item_line(item, kind, format, conflicts[item.text]),
      item = item,
    })
  end

  table.insert(layout, { kind = "blank", line = "" })

  if has_metadata_items(summary.tag_totals, "tag") then
    table.insert(layout, { kind = "header", section = "tag", line = headers.tag })

    for _, item in ipairs(summary.tag_totals or {}) do
      table.insert(layout, {
        kind = "tag_total",
        section = "tag",
        line = metadata_line(item, kind, format, tag_line),
        item = item,
      })
    end

    table.insert(layout, { kind = "blank", line = "" })
  end

  if has_metadata_items(summary.location_totals, "location") then
    table.insert(layout, { kind = "header", section = "location", line = headers.location })

    for _, item in ipairs(summary.location_totals or {}) do
      table.insert(layout, {
        kind = "location_total",
        section = "location",
        line = metadata_line(item, kind, format, location_line),
        item = item,
      })
    end

    table.insert(layout, { kind = "blank", line = "" })
  end

  if summary.logged_totals and #summary.logged_totals > 0 then
    table.insert(layout, { kind = "header", section = "logged", line = headers.logged })

    for _, item in ipairs(summary.logged_totals) do
      table.insert(layout, {
        kind = "logged_total",
        section = "logged",
        line = metadata_line(item, kind, format, logged_line),
        item = item,
      })
    end

    table.insert(layout, { kind = "blank", line = "" })
  end

  table.insert(layout, { kind = "header", section = "total", line = headers.total })

  if kind == "quantized" then
    if has_workday_excluded_items(summary.summary_items) then
      table.insert(layout, {
        kind = "total",
        section = "total",
        line = string.format(
          "%s (%+dm) activity",
          duration_string(summary.activity_total, format),
          summary.activity_error_minutes or 0
        ),
      })
    end

    table.insert(layout, {
      kind = "total",
      section = "total",
      line = string.format(
        "%s (%+dm) workday",
        duration_string(summary.workday_total, format),
        summary.workday_error_minutes or 0
      ),
    })
  else
    if has_workday_excluded_items(summary.summary_items) then
      table.insert(layout, {
        kind = "total",
        section = "total",
        line = string.format("%s activity", duration_string(summary.activity_total, format)),
      })
    end

    table.insert(layout, {
      kind = "total",
      section = "total",
      line = string.format("%s workday", duration_string(summary.workday_total, format)),
    })
  end

  return layout
end

local function append_summary_lines(lines, summary, kind, duration_format, options)
  for _, row in ipairs(build_summary_layout(summary, kind, duration_format, options)) do
    table.insert(lines, row.line)
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
    table.insert(header, syntax.OPTION_QUANTIZE .. "=" .. tostring(header_quantize_minutes))
  end

  if header_duration_format then
    table.insert(header, syntax.OPTION_DURATION .. "=" .. header_duration_format)
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

function M.summary_layout(summary, kind, duration_format, options)
  return build_summary_layout(summary, kind, duration_format, options)
end

-- Build the labeled section headers for one report section. `prefix` selects the
-- scope (day, week, range) and `label` is the date or period appended to each.
local function report_headers(prefix, label, leading_blank)
  return {
    leading_blank = leading_blank,
    summary_header = string.format("--- %s summary quantized %s ---", prefix, label),
    tag_header = string.format("--- %s tags quantized %s ---", prefix, label),
    location_header = string.format("--- %s locations quantized %s ---", prefix, label),
    logged_header = string.format("--- %s logged quantized %s ---", prefix, label),
    total_header = string.format("--- %s totals quantized %s ---", prefix, label),
  }
end

-- Render the per-day sections (unless aggregate-only) followed by the aggregate
-- section. `aggregate_prefix` is the only thing that differs between a week
-- report (`week`) and a trailing-days report (`range`).
local function period_report_lines(report, duration_format, options, aggregate_prefix)
  local lines = {}
  options = options or {}

  if not options.aggregate_only then
    for index, day in ipairs(report.days) do
      append_summary_lines(
        lines,
        day.summary,
        "quantized",
        duration_format,
        report_headers("day", day.date_label, index > 1)
      )
    end
  end

  append_summary_lines(
    lines,
    report.summary,
    "quantized",
    duration_format,
    report_headers(aggregate_prefix, report.period_label, #lines > 0)
  )

  return lines
end

function M.week_report_lines(report, duration_format, options)
  return period_report_lines(report, duration_format, options, "week")
end

function M.days_report_lines(report, duration_format, options)
  return period_report_lines(report, duration_format, options, "range")
end

return M
