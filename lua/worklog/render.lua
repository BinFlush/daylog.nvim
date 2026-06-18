local syntax = require("worklog.syntax")

local M = {}

-- Layout row kinds for the structured summary layout. `summary_item` is read by
-- usecases (e.g. log_current) to recover the underlying item, so it is exported.
local LAYOUT_KIND = {
  BLANK = "blank",
  HEADER = "header",
  SUMMARY_ITEM = "summary_item",
  TAG_TOTAL = "tag_total",
  LOCATION_TOTAL = "location_total",
  LOGGED_TOTAL = "logged_total",
  TOTAL = "total",
}
M.LAYOUT_KIND = LAYOUT_KIND

local function decimal_hours_string(minutes)
  return string.format("%.2fh", minutes / 60)
end

local function hhmm_string(minutes)
  return string.format("%d:%02d", math.floor(minutes / 60), minutes % 60)
end

local function duration_string(minutes, duration_format)
  if duration_format == syntax.DURATION_HM then
    return hhmm_string(minutes)
  end

  return decimal_hours_string(minutes)
end

-- Distribute the 2-decimal-hour (centihour) display of a section's durations with
-- the largest-remainder method -- the same approach quantize.lua uses for minutes
-- -- so the rendered rows sum exactly to the section's displayed total
-- `round(total_minutes / 60, 2)`. Every duration is a whole minute, so each row's
-- centihour value `m*100/60` has remainder 0, 1/3, or 2/3 (ranked by `(m*5) mod 3`,
-- integer and tie-broken by first-seen order). When the naive per-row rounding
-- already foots, this returns the identical centihours -- so it is a no-op for any
-- already-footing summary and only corrects the broken ones.
local function foot_decimal_centihours(durations, total_minutes)
  local target = math.floor(total_minutes * 100 / 60 + 0.5)
  local centi = {}
  local ranked = {}
  local base_sum = 0

  for i, minutes in ipairs(durations) do
    local floored = math.floor(minutes * 100 / 60)
    centi[i] = floored
    base_sum = base_sum + floored
    ranked[i] = { index = i, residue = (minutes * 5) % 3 }
  end

  table.sort(ranked, function(a, b)
    if a.residue == b.residue then
      return a.index < b.index
    end
    return a.residue > b.residue
  end)

  for i = 1, target - base_sum do
    local row = ranked[i]
    if row then
      centi[row.index] = centi[row.index] + 1
    end
  end

  return centi
end

-- The displayed duration string for each item in one section. `hm` minutes are
-- exact and already foot; `dec` rows are footed (above) so they sum to the
-- displayed section total. The items' minute durations sum to `total_minutes` by
-- construction (the quantization invariant).
local function section_duration_strings(items, total_minutes, format)
  local strings = {}

  if format == syntax.DURATION_HM then
    for i, item in ipairs(items) do
      strings[i] = hhmm_string(item.duration)
    end
    return strings
  end

  local durations = {}
  for i, item in ipairs(items) do
    durations[i] = item.duration
  end

  local centi = foot_decimal_centihours(durations, total_minutes)
  for i = 1, #items do
    strings[i] = string.format("%.2fh", centi[i] / 100)
  end

  return strings
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

local function section_headers(format, options)
  options = options or {}

  return {
    summary = options.summary_header or syntax.summary_header(options.quantize_minutes, format),
    tag = options.tag_header or syntax.section_header(syntax.SECTION.TAGS),
    location = options.location_header or syntax.section_header(syntax.SECTION.LOCATIONS),
    logged = options.logged_header or syntax.section_header(syntax.SECTION.LOGGED),
    total = options.total_header or syntax.section_header(syntax.SECTION.TOTALS),
    leading_blank = options.leading_blank ~= false,
  }
end

local function summary_item_line(item, duration_str, show_tag)
  return summary_line(
    string.format("%s (%+dm)", duration_str, item.error_minutes or 0),
    item,
    show_tag
  )
end

local function metadata_line(item, duration_str, line_builder)
  return line_builder(string.format("%s (%+dm)", duration_str, item.error_minutes or 0), item)
end

-- Build a structured summary layout that records both rendered text and the
-- role each row plays.  Future commands can take a rendered summary row,
-- recompute the same layout, and recover the underlying summary item via the
-- `item` field.  `summary_lines` projects this layout to lines so user-facing
-- output stays in lockstep with the layout.
local function build_summary_layout(summary, duration_format, options)
  local layout = {}
  local format = duration_format or syntax.DURATION_DECIMAL
  local headers = section_headers(format, options)
  local conflicts = text_tag_conflicts(summary.summary_items)

  if headers.leading_blank then
    table.insert(layout, { kind = LAYOUT_KIND.BLANK, line = "" })
  end

  table.insert(layout, { kind = LAYOUT_KIND.HEADER, section = "summary", line = headers.summary })

  local summary_durations =
    section_duration_strings(summary.summary_items, summary.activity_total, format)
  for i, item in ipairs(summary.summary_items) do
    table.insert(layout, {
      kind = LAYOUT_KIND.SUMMARY_ITEM,
      section = "summary",
      line = summary_item_line(item, summary_durations[i], conflicts[item.text]),
      item = item,
    })
  end

  table.insert(layout, { kind = LAYOUT_KIND.BLANK, line = "" })

  if has_metadata_items(summary.tag_totals, "tag") then
    table.insert(layout, { kind = LAYOUT_KIND.HEADER, section = "tag", line = headers.tag })

    local tag_durations =
      section_duration_strings(summary.tag_totals or {}, summary.activity_total, format)
    for i, item in ipairs(summary.tag_totals or {}) do
      table.insert(layout, {
        kind = LAYOUT_KIND.TAG_TOTAL,
        section = "tag",
        line = metadata_line(item, tag_durations[i], tag_line),
        item = item,
      })
    end

    table.insert(layout, { kind = LAYOUT_KIND.BLANK, line = "" })
  end

  if has_metadata_items(summary.location_totals, "location") then
    table.insert(
      layout,
      { kind = LAYOUT_KIND.HEADER, section = "location", line = headers.location }
    )

    local location_durations =
      section_duration_strings(summary.location_totals or {}, summary.activity_total, format)
    for i, item in ipairs(summary.location_totals or {}) do
      table.insert(layout, {
        kind = LAYOUT_KIND.LOCATION_TOTAL,
        section = "location",
        line = metadata_line(item, location_durations[i], location_line),
        item = item,
      })
    end

    table.insert(layout, { kind = LAYOUT_KIND.BLANK, line = "" })
  end

  if summary.logged_totals and #summary.logged_totals > 0 then
    table.insert(layout, { kind = LAYOUT_KIND.HEADER, section = "logged", line = headers.logged })

    local logged_durations =
      section_duration_strings(summary.logged_totals, summary.workday_total, format)
    for i, item in ipairs(summary.logged_totals) do
      table.insert(layout, {
        kind = LAYOUT_KIND.LOGGED_TOTAL,
        section = "logged",
        line = metadata_line(item, logged_durations[i], logged_line),
        item = item,
      })
    end

    table.insert(layout, { kind = LAYOUT_KIND.BLANK, line = "" })
  end

  table.insert(layout, { kind = LAYOUT_KIND.HEADER, section = "total", line = headers.total })

  if has_workday_excluded_items(summary.summary_items) then
    table.insert(layout, {
      kind = LAYOUT_KIND.TOTAL,
      section = "total",
      line = string.format(
        "%s (%+dm) activity",
        duration_string(summary.activity_total, format),
        summary.activity_error_minutes or 0
      ),
    })
  end

  table.insert(layout, {
    kind = LAYOUT_KIND.TOTAL,
    section = "total",
    line = string.format(
      "%s (%+dm) workday",
      duration_string(summary.workday_total, format),
      summary.workday_error_minutes or 0
    ),
  })

  return layout
end

local function append_summary_lines(lines, summary, duration_format, options)
  for _, row in ipairs(build_summary_layout(summary, duration_format, options)) do
    table.insert(lines, row.line)
  end
end

function M.worklog_header_line(
  header_tag,
  header_location,
  header_offset,
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

  -- Only a numeric offset is rendered; a non-number (e.g. an unresolved "auto"
  -- sentinel that somehow reached here) is treated as no offset rather than
  -- crashing the formatter -- fail-safe, like an absent tag or location.
  if type(header_offset) == "number" then
    table.insert(header, syntax.utc_offset_token(header_offset))
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
  header_offset,
  header_quantize_minutes,
  header_duration_format
)
  local rendered = {
    "",
    M.worklog_header_line(
      header_tag,
      header_location,
      header_offset,
      header_quantize_minutes,
      header_duration_format
    ),
  }

  extend_lines(rendered, lines)

  return rendered
end

function M.summary_lines(summary, duration_format, options)
  local lines = {}
  append_summary_lines(lines, summary, duration_format, options)
  return lines
end

function M.summary_layout(summary, duration_format, options)
  return build_summary_layout(summary, duration_format, options)
end

-- The trailing ` q=N` token on a per-day report summary header, so a multi-day
-- report shows each day's own quantization bucket. Nothing is added when
-- `quantize_minutes` is nil (e.g. the aggregate section).
local function quantize_suffix(quantize_minutes)
  if not quantize_minutes then
    return ""
  end

  return string.format(" q=%d", quantize_minutes)
end

-- Build the labeled section headers for one report section. `prefix` selects the
-- scope (day, week, range) and `label` is the date or period appended to each.
-- `quantize_minutes` annotates the summary header with that section's bucket.
local function report_headers(prefix, label, leading_blank, quantize_minutes)
  return {
    leading_blank = leading_blank,
    summary_header = string.format(
      "--- %s summary %s%s ---",
      prefix,
      label,
      quantize_suffix(quantize_minutes)
    ),
    tag_header = string.format("--- %s tags %s ---", prefix, label),
    location_header = string.format("--- %s locations %s ---", prefix, label),
    logged_header = string.format("--- %s logged %s ---", prefix, label),
    total_header = string.format("--- %s totals %s ---", prefix, label),
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
        duration_format,
        report_headers("day", day.date_label, index > 1, day.quantize_minutes)
      )
    end
  end

  append_summary_lines(
    lines,
    report.summary,
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
