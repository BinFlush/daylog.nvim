local analyze = require("worklog.analyze")
local document = require("worklog.document")
local journal = require("worklog.journal")
local summary = require("worklog.summary")
local support = require("worklog.usecases.support")

local M = {}

local function empty_lines(lines)
  return lines == nil or #lines == 0 or (#lines == 1 and lines[1] == "")
end

local function strip_worklog_prefix(message)
  return message:match("^worklog:%s*(.*)$") or message
end

local function prefixed_file_error(path, message)
  return string.format("worklog: %s: %s", path, strip_worklog_prefix(message))
end

local function diagnostic_error(diagnostic)
  if diagnostic.code == "invalid_entry" then
    return support.invalid_entry_error(diagnostic)
  end

  if diagnostic.code == "unordered_timestamps" then
    return support.unordered_error(diagnostic)
  end

  return "worklog: " .. diagnostic.message
end

local function analyze_day(day)
  if empty_lines(day.lines) then
    return nil, nil
  end

  local analysis = analyze.analyze(document.parse(day.lines))

  if #analysis.diagnostics > 0 then
    return nil, prefixed_file_error(day.path, diagnostic_error(analysis.diagnostics[1]))
  end

  local err = support.structural_or_missing_worklog_error(analysis)
  if err then
    return nil, prefixed_file_error(day.path, err)
  end

  return {
    date_label = day.date_label,
    path = day.path,
    summary = summary.quantized_summarize_block(analyze.get_active_worklog(analysis)),
  },
    nil
end

function M.build_report(days, week_label)
  local report = {
    week_label = week_label,
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
    return nil, "worklog: no journal worklogs found for week " .. week_label
  end

  report.summary = summary.combine_quantized_summaries(day_summaries)
  return report
end

function M.build_journal_report(settings, now, read_lines)
  local days = {}

  for _, date in ipairs(journal.iso_week_dates(now)) do
    local path = journal.path_for_date(settings, date)

    table.insert(days, {
      date_label = journal.date_label(date),
      path = path,
      lines = read_lines(path),
    })
  end

  return M.build_report(days, journal.week_label(now))
end

return M
