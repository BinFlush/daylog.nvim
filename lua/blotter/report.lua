local buffer = require("blotter.buffer")
local config = require("blotter.config")
local journal_io = require("blotter.journal_io")
local render = require("blotter.render")
local week = require("blotter.week")

local M = {}

-- Multi-day report scratch buffers (shell).
--
-- Builds a report object for a week/days spec, renders it, opens it as a read-only
-- scratch buffer tagged with its spec, and refreshes open reports in place when a
-- dependent journal buffer changes.

local warn = buffer.warn
local with_preserved_cursor = buffer.with_preserved_cursor
local highlight_buffer = buffer.highlight_buffer
local expanded_journal_settings = journal_io.expanded_journal_settings
local journal_lines = journal_io.journal_lines

local function unique_buffer_name(base_name)
  if vim.fn.bufexists(base_name) == 0 then
    return base_name
  end

  local suffix = 2
  local candidate = base_name .. "#" .. suffix

  while vim.fn.bufexists(candidate) == 1 do
    suffix = suffix + 1
    candidate = base_name .. "#" .. suffix
  end

  return candidate
end

local function open_report_buffer(lines, name)
  vim.cmd("botright new")
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
  vim.bo.buflisted = false
  vim.bo.swapfile = false
  if name then
    vim.api.nvim_buf_set_name(0, unique_buffer_name(name))
  end
  vim.bo.modifiable = true
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.bo.modified = false
  vim.bo.modifiable = false

  -- Reports are scratch buffers (no blotter filetype, so no ftplugin), so apply
  -- the parser-driven highlighter directly. The same recognizer handles the
  -- labeled multi-day section headers and their duration rows.
  highlight_buffer(0)
end

-- Build the report object for a spec, reading each day through journal_lines so
-- open buffers (saved or not) are reflected. Returns the report (its days each
-- carrying a path) or nil and an error message. Shared by the line renderer and the
-- report rename, so both see the same period and days.
local function build_report_for_spec(spec)
  local settings = expanded_journal_settings()
  if settings == nil then
    return nil, "blotter: journal.root is not configured"
  end

  if spec.kind == "week" then
    return week.build_week_report(settings, spec.anchor, journal_lines)
  end

  return week.build_days_report(settings, spec.anchor, spec.count, journal_lines)
end

-- Build the display lines for a report spec. Returns the lines and the period
-- label, or nil and an error message.
local function build_report_lines(spec)
  local report, err = build_report_for_spec(spec)
  if not report then
    return nil, err
  end

  local options = { aggregate_only = spec.aggregate_only }
  local duration_format = config.get().defaults.duration_format
  local render_report = spec.kind == "week" and render.week_report_lines or render.days_report_lines

  return render_report(report, duration_format, options), report.period_label
end

local function report_buffer_name(spec, label)
  local prefix
  if spec.kind == "week" then
    prefix = spec.aggregate_only and "blotter-week-summary-" or "blotter-week-"
  else
    prefix = spec.aggregate_only and "blotter-days-summary-" or "blotter-days-"
  end

  return prefix .. label .. ".blot"
end

-- Open a fresh scratch report for a spec and tag the buffer with that spec, so
-- the auto-summary autocmds can rebuild it in place when a dependent journal
-- buffer changes. The anchor is pinned at open time, so the report keeps
-- covering the same period for as long as it stays open.
local function open_report(spec)
  local lines, label_or_err = build_report_lines(spec)
  if not lines then
    warn(label_or_err)
    return
  end

  open_report_buffer(lines, report_buffer_name(spec, label_or_err))
  vim.api.nvim_buf_set_var(0, "blotter_report", spec)
end

-- Rebuild every open report buffer from its stored spec, mirroring how the
-- in-file summaries refresh. A build failure (e.g. a dependent day is mid-edit
-- and invalid) leaves the last good report untouched rather than flicker, and
-- an unchanged report is left alone so the cursor never jumps needlessly.
local function refresh_report_windows()
  local refreshed = {}

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ok, spec = pcall(vim.api.nvim_buf_get_var, buf, "blotter_report")

    if ok and type(spec) == "table" and not refreshed[buf] then
      refreshed[buf] = true
      local lines = build_report_lines(spec)

      if lines and not vim.deep_equal(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
        with_preserved_cursor(win, buf, function()
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
          vim.bo[buf].modified = false
          vim.bo[buf].modifiable = false
          highlight_buffer(buf)
        end)
      end
    end
  end
end

M.build_report_for_spec = build_report_for_spec
M.open_report = open_report
M.refresh_report_windows = refresh_report_windows

return M
