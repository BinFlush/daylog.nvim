local analyze = require("daylog.analyze")
local diagnostics = require("daylog.diagnostics")
local document = require("daylog.document")
local daybook = require("daylog.daybook")
local summary = require("daylog.summary")
local text = require("daylog.text")

local M = {}

local function strip_log_prefix(message)
  -- gsub (not match) so the prefix strips even from a multi-line message, where `.` in a
  -- `(.*)$` capture won't span the newline.
  return (message:gsub("^daylog:%s*", ""))
end

local function prefixed_file_error(path, message)
  return string.format("daylog: %s: %s", path, strip_log_prefix(message))
end

local function analyze_day(day)
  if text.is_empty(day.lines) then
    return nil, nil
  end

  local analysis = analyze.analyze(document.parse(day.lines))

  if #analysis.diagnostics > 0 then
    return nil, prefixed_file_error(day.path, diagnostics.message(analysis.diagnostics[1]))
  end

  -- A non-empty day with no log and no entries (e.g. a "day off" note) is skipped like an empty day, not an abort.
  if #analysis.log_blocks == 0 and not diagnostics.has_entry_node(analysis.document) then
    return nil, nil
  end

  local err = diagnostics.structural_or_missing_log_error(analysis)
  if err then
    return nil, prefixed_file_error(day.path, err)
  end

  -- Expose the day's own quantization bucket so the multi-day report can label
  -- each day section with its `q=`.
  local block = analyze.get_active_log(analysis)
  local day_summary = summary.summarize_block(block)

  return {
    date_label = day.date_label,
    path = day.path,
    summary = day_summary,
    -- The activity projection :Daylog export flattens; the summary's own rows, which split per
    -- granule (label, tag, location). Inert for the rendered report.
    activity_rows = day_summary.summary_items,
    quantize_minutes = block.quantize_minutes,
  },
    nil
end

function M.build_report(days)
  local report = {
    days = {},
  }
  local day_summaries = {}

  for _, day in ipairs(days) do
    local analyzed_day, err = analyze_day(day)
    if err then
      return nil, err
    end

    if analyzed_day then
      table.insert(report.days, analyzed_day)
      table.insert(day_summaries, analyzed_day.summary)
    end
  end

  if #report.days == 0 then
    return nil, "daylog: no daybook logs found"
  end

  report.summary = summary.combine_summaries(day_summaries)
  return report
end

local function build_days(settings, dates, read_lines)
  local days = {}

  for _, date in ipairs(dates) do
    local path = daybook.path_for_date(settings, date)

    table.insert(days, {
      date_label = daybook.date_label(date),
      path = path,
      lines = read_lines(path),
    })
  end

  return days
end

function M.build_daybook_report(settings, dates, read_lines)
  return M.build_report(build_days(settings, dates, read_lines))
end

-- Build a report over an explicit list of dates -- the single builder behind every `:Daylog report` form.
function M.build_dates_report(settings, dates, read_lines)
  local report, err = M.build_daybook_report(settings, dates, read_lines)
  if not report then
    return nil, err
  end

  -- Label by the resolved span (first/last days that held a log) and count, not the requested
  -- bounds; report.days is non-empty and chronological (build_report errors on zero).
  report.period_label = string.format(
    "%s..%s (%d found)",
    report.days[1].date_label,
    report.days[#report.days].date_label,
    #report.days
  )
  return report
end

function M.build_days_report(settings, now, count, read_lines)
  return M.build_dates_report(settings, daybook.trailing_dates(now, count), read_lines)
end

return M
