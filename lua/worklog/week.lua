local analyze = require("worklog.analyze")
local diagnostics = require("worklog.diagnostics")
local document = require("worklog.document")
local journal = require("worklog.journal")
local summary = require("worklog.summary")

local M = {}

-- Mirrors init's lines_are_empty and new_worklog's empty_buffer: no lines, or only
-- blank/whitespace lines. Every layer must agree on what "empty" means.
local function empty_lines(lines)
  if lines == nil then
    return true
  end

  for _, line in ipairs(lines) do
    if line:find("%S") then
      return false
    end
  end

  return true
end

local function strip_worklog_prefix(message)
  return message:match("^worklog:%s*(.*)$") or message
end

local function prefixed_file_error(path, message)
  return string.format("worklog: %s: %s", path, strip_worklog_prefix(message))
end

local function analyze_day(day)
  if empty_lines(day.lines) then
    return nil, nil
  end

  local analysis = analyze.analyze(document.parse(day.lines))

  if #analysis.diagnostics > 0 then
    return nil, prefixed_file_error(day.path, diagnostics.message(analysis.diagnostics[1]))
  end

  -- A non-empty day with no worklog and no timestamped entries (e.g. a "day off"
  -- note) is skipped like an empty day instead of aborting the whole report.
  if #analysis.worklog_blocks == 0 and not diagnostics.has_entry_node(analysis.document) then
    return nil, nil
  end

  local err = diagnostics.structural_or_missing_worklog_error(analysis)
  if err then
    return nil, prefixed_file_error(day.path, err)
  end

  -- Expose the day's own quantization bucket so the multi-day report can label
  -- each day section with its `q=`.
  local block = analyze.get_active_worklog(analysis)

  return {
    date_label = day.date_label,
    path = day.path,
    summary = summary.summarize_block(block),
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
    return nil, "worklog: no journal worklogs found"
  end

  report.summary = summary.combine_summaries(day_summaries)
  return report
end

local function build_days(settings, dates, read_lines)
  local days = {}

  for _, date in ipairs(dates) do
    local path = journal.path_for_date(settings, date)

    table.insert(days, {
      date_label = journal.date_label(date),
      path = path,
      lines = read_lines(path),
    })
  end

  return days
end

function M.build_journal_report(settings, dates, read_lines)
  return M.build_report(build_days(settings, dates, read_lines))
end

function M.build_week_report(settings, now, read_lines)
  local report, err = M.build_journal_report(settings, journal.iso_week_dates(now), read_lines)
  if not report then
    return nil, err
  end

  report.period_label = journal.week_label(now)
  return report
end

function M.build_days_report(settings, now, count, read_lines)
  local dates = journal.trailing_dates(now, count)
  local report, err = M.build_journal_report(settings, dates, read_lines)
  if not report then
    return nil, err
  end

  report.period_label = journal.date_range_label(dates[1], dates[#dates])
  return report
end

return M
