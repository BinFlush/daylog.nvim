local syntax = require("daylog.syntax")

local M = {}

-- Layout row kinds for the structured summary layout. `summary_item` is read by
-- usecases (e.g. log_current) to recover the underlying item, so it is exported.
local LAYOUT_KIND = {
  BLANK = "blank",
  HEADER = "header",
  SUMMARY_ITEM = "summary_item",
  TAG_TOTAL = "tag_total",
  LOCATION_TOTAL = "location_total",
  TOTAL = "total",
}
M.LAYOUT_KIND = LAYOUT_KIND

local function hhmm_string(minutes)
  return string.format("%d:%02d", math.floor(minutes / 60), minutes % 60)
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
    table.insert(parts, syntax.logged_token("s"))
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

-- The totals section is a single `workday` row -- the whole counted day (uncounted time is a blank
-- entry, which reaches no report).
local function total_label()
  return "workday"
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

local function section_headers(format, options)
  options = options or {}

  return {
    summary = options.summary_header or syntax.summary_header(options.quantize_minutes, format),
    tag = options.tag_header or syntax.section_header(syntax.SECTION.TAGS),
    location = options.location_header or syntax.section_header(syntax.SECTION.LOCATIONS),
    total = options.total_header or syntax.section_header(syntax.SECTION.TOTALS),
    leading_blank = options.leading_blank ~= false,
  }
end

-- A duration string with its quantization rounding marker appended ("1.00h (+5m)"): every
-- summary row shows the minutes it gained or lost to bucket rounding.
local function duration_with_error(duration_str, error_minutes)
  return string.format("%s (%+dm)", duration_str, error_minutes or 0)
end

local function summary_item_line(item, duration_str, show_tag)
  return summary_line(duration_with_error(duration_str, item.error_minutes), item, show_tag)
end

-- A metadata row (#tag / @location): the duration + rounding marker, then the row's label
-- (`label_fn(item)`, never empty for these). A row in the section's logged slice carries its level's
-- marker (a logged `#ClientA` tag row renders `... #ClientA !T`).
local function metadata_line(item, duration_str, label_fn, level)
  local prefix = duration_with_error(duration_str, item.error_minutes)
  local label = label_fn(item)
  if item.logged and level then
    label = label .. " " .. syntax.logged_token(level)
  end
  return string.format("%s %s", prefix, label)
end

-- Append the manual rounding-balance marker (round±N) when a row or total carries a
-- nonzero cumulative nudge, so a manual adjustment is visible on every affected
-- summary line (and can be re-adjusted from there). A zero nudge adds nothing, so a
-- summary with no manual balancing renders exactly as before.
local function with_nudge(line, nudge)
  if nudge and nudge ~= 0 then
    return line .. " " .. syntax.round_nudge_token(nudge)
  end

  return line
end

-- Append one flat metadata section -- tag or location -- to the layout when `opts.present`: its
-- header, a duration-footed row per item (carrying any nudge marker and, for a logged-slice row, its
-- `opts.level` marker), and a trailing blank. The sections differ only in kind / header / label builder
-- (`label_fn`) / level marker / footing base (`opts.total` is the section's own total), so they share
-- this one shape.
local function append_metadata_section(layout, items, opts)
  if not opts.present then
    return
  end

  table.insert(layout, { kind = LAYOUT_KIND.HEADER, section = opts.section, line = opts.header })

  local durations = section_duration_strings(items or {}, opts.total, opts.format)
  for i, item in ipairs(items or {}) do
    table.insert(layout, {
      kind = opts.kind,
      section = opts.section,
      line = with_nudge(metadata_line(item, durations[i], opts.label_fn, opts.level), item.nudge),
      item = item,
    })
  end

  table.insert(layout, { kind = LAYOUT_KIND.BLANK, line = "" })
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
      line = with_nudge(
        summary_item_line(item, summary_durations[i], conflicts[item.text]),
        item.nudge
      ),
      item = item,
    })
  end

  table.insert(layout, { kind = LAYOUT_KIND.BLANK, line = "" })

  append_metadata_section(layout, summary.tag_totals, {
    present = has_metadata_items(summary.tag_totals, "tag"),
    section = "tag",
    kind = LAYOUT_KIND.TAG_TOTAL,
    header = headers.tag,
    total = summary.activity_total,
    format = format,
    label_fn = tag_text,
    level = "t",
  })

  append_metadata_section(layout, summary.location_totals, {
    present = has_metadata_items(summary.location_totals, "location"),
    section = "location",
    kind = LAYOUT_KIND.LOCATION_TOTAL,
    header = headers.location,
    total = summary.activity_total,
    format = format,
    label_fn = location_text,
    level = "l",
  })

  table.insert(layout, { kind = LAYOUT_KIND.HEADER, section = "total", line = headers.total })

  -- The totals are a single `workday` cell = the whole counted day, loggable via !W (so it can split
  -- into a reported and a remaining row). It foots to the activity total, so section_duration_strings
  -- distributes the display rounding across its row(s).
  local total_durations =
    section_duration_strings(summary.total_rows or {}, summary.activity_total, format)
  for i, item in ipairs(summary.total_rows or {}) do
    table.insert(layout, {
      kind = LAYOUT_KIND.TOTAL,
      section = "total",
      total = total_label(item),
      line = with_nudge(metadata_line(item, total_durations[i], total_label, "w"), item.nudge),
      item = item,
    })
  end

  return layout
end

local function append_summary_lines(lines, summary, duration_format, options)
  for _, row in ipairs(build_summary_layout(summary, duration_format, options)) do
    table.insert(lines, row.line)
  end
end

function M.log_header_line(
  header_tag,
  header_location,
  header_offset,
  header_quantize_minutes,
  header_duration_format
)
  local header = { "--- log" }

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

function M.log_lines(
  lines,
  header_tag,
  header_location,
  header_offset,
  header_quantize_minutes,
  header_duration_format
)
  local rendered = {
    "",
    M.log_header_line(
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
    total_header = string.format("--- %s totals %s ---", prefix, label),
  }
end

-- The ordered sections of a period report: each per-day section (unless
-- aggregate-only) followed by the aggregate section. Each carries the summary and
-- the labeled headers to render it with; the per-day sections also carry the date
-- label and source path so the layout can trace a row back to one file.
-- The aggregate section's headers use the `range` prefix, distinct from the per-day
-- sections' `day`.
local function report_sections(report, options)
  options = options or {}
  local sections = {}

  if not options.aggregate_only then
    for index, day in ipairs(report.days) do
      sections[#sections + 1] = {
        scope = "day",
        date_label = day.date_label,
        path = day.path,
        summary = day.summary,
        headers = report_headers("day", day.date_label, index > 1, day.quantize_minutes),
      }
    end
  end

  -- The aggregate gets a leading blank only when day sections precede it, matching
  -- the original `#lines > 0` test.
  sections[#sections + 1] = {
    scope = "aggregate",
    summary = report.summary,
    headers = report_headers("range", report.period_label, #sections > 0),
  }

  return sections
end

local function period_report_lines(report, duration_format, options)
  local lines = {}

  for _, section in ipairs(report_sections(report, options)) do
    append_summary_lines(lines, section.summary, duration_format, section.headers)
  end

  return lines
end

-- The flat layout of a period report: one entry per rendered line (so a 1-based
-- line number indexes straight into it), each tagged with the section it belongs
-- to -- a per-day section (scope "day", with its date_label/path) or the aggregate
-- (scope "aggregate"). Built from the same sections as period_report_lines, so the
-- rows stay in lockstep with what the buffer shows; cursor resolution reads `kind`,
-- `item`, and `scope` off a row.
local function period_report_layout(report, duration_format, options)
  local rows = {}

  for _, section in ipairs(report_sections(report, options)) do
    for _, row in ipairs(build_summary_layout(section.summary, duration_format, section.headers)) do
      row.scope = section.scope
      row.date_label = section.date_label
      row.path = section.path
      rows[#rows + 1] = row
    end
  end

  return rows
end

function M.days_report_lines(report, duration_format, options)
  return period_report_lines(report, duration_format, options)
end

function M.days_report_layout(report, duration_format, options)
  return period_report_layout(report, duration_format, options)
end

return M
