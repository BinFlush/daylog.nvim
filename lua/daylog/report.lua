local buffer = require("daylog.buffer")
local config = require("daylog.config")
local daybook = require("daylog.daybook")
local daybook_io = require("daylog.daybook_io")
local export = require("daylog.export")
local render = require("daylog.render")
local week = require("daylog.week")

local M = {}

-- Multi-day report scratch buffers (shell).
--
-- Builds a report for a spec, opens it as a read-only scratch buffer tagged with its spec, and
-- refreshes open reports in place when a dependent daybook buffer changes.

local warn = buffer.warn
local with_preserved_cursor = buffer.with_preserved_cursor
local highlight_buffer = buffer.highlight_buffer
local expanded_daybook_settings = daybook_io.expanded_daybook_settings
local daybook_lines = daybook_io.daybook_lines

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

-- Open a fresh read-only scratch buffer in a bottom split, named `name`, holding `lines`.
local function fill_scratch(lines, name)
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
end

local function open_report_buffer(lines, name)
  fill_scratch(lines, name)
  -- Scratch buffers get no ftplugin, so apply the parser-driven highlighter directly.
  highlight_buffer(0)
end

-- Build the report object for a spec, reading each day through daybook_lines so open buffers
-- (saved or not) are reflected. Returns the report, or nil and an error message.
local function build_report_for_spec(spec)
  local settings = expanded_daybook_settings()
  if settings == nil then
    return nil, "daylog: daybook.root is not configured"
  end

  return week.build_dates_report(settings, spec.dates, daybook_lines)
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

  return render.days_report_lines(report, duration_format, options), report.period_label
end

local function report_buffer_name(spec)
  -- Name by the requested range, not the resolved header label (unsuited to a filename).
  local prefix = spec.aggregate_only and "daylog-days-summary-" or "daylog-days-"
  return prefix .. spec.request_label .. ".day"
end

-- Open a fresh scratch report and tag the buffer with its spec so autocmds can rebuild it in
-- place. The date list is pinned at open time, so the report keeps its span while open.
local function open_report(spec)
  local lines, label_or_err = build_report_lines(spec)
  if not lines then
    warn(label_or_err)
    return
  end

  open_report_buffer(lines, report_buffer_name(spec))
  vim.api.nvim_buf_set_var(0, "log_report", spec)
  -- No daylog filetype here, so apply the keymaps directly: <leader>dl / dL / dR act on the report.
  require("daylog.keymaps").apply(0)
end

-- Write the export string to `path` (creating the parent dir if needed). Returns the string, or nil
-- after warning on a write failure.
local function write_export(text, path, row_count)
  local full = vim.fn.expand(path)
  local dir = vim.fn.fnamemodify(full, ":h")
  if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end

  local ok =
    pcall(vim.fn.writefile, vim.split((text:gsub("\n$", "")), "\n", { plain = true }), full)
  if not ok then
    warn("daylog: could not write the export to " .. full)
    return nil
  end

  vim.notify(
    string.format("daylog: exported %d row(s) to %s", row_count, full),
    vim.log.levels.INFO
  )
  return text
end

-- Build the CSV/JSON export for a spec. With a `path` it writes the file; otherwise it opens a read-only
-- scratch buffer with the matching filetype (a snapshot -- unlike a report it is not auto-refreshed).
-- Returns the rendered string, or nil on error (already warned).
local function open_export(spec, format, path)
  local report, err = build_report_for_spec(spec)
  if not report then
    warn(err)
    return nil
  end

  local text = export[format](report)

  if path and path ~= "" then
    return write_export(text, path, export.row_count(report))
  end

  local name = "daylog-export-" .. (spec.request_label or "export") .. "." .. format
  fill_scratch(vim.split((text:gsub("\n$", "")), "\n", { plain = true }), name)
  vim.bo.filetype = format
  return text
end

-- One end of a `:Daylog report` range: a named token (`today`, `monday`, ...) or a `YYYY-MM-DD`
-- literal resolved against `now`; or, when the bound is omitted, the daybook extreme that
-- `fallback` returns (earliest for the start, latest for the end). Returns ts, or nil + err.
local function resolve_range_bound(token, now, fallback)
  if token then
    local ts = daybook.resolve_date(token, now)
    if not ts then
      return nil, "daylog: invalid date: " .. token
    end
    return ts
  end

  local settings = expanded_daybook_settings()
  if settings == nil then
    return nil, "daylog: daybook.root is not configured"
  end
  local ts = fallback(settings)
  if not ts then
    return nil, "daylog: no daybook logs found"
  end
  return ts
end

-- Resolve a `:Daylog report` range request into a pinned date list. An omitted start resolves to
-- the earliest logged day, an omitted end to the latest; a reversed range is rejected.
local function resolve_range_dates(request)
  local now = os.time()

  local from_ts, from_err = resolve_range_bound(request.from, now, daybook_io.earliest_daybook_date)
  if not from_ts then
    return nil, from_err
  end

  local to_ts, to_err = resolve_range_bound(request.to, now, daybook_io.latest_daybook_date)
  if not to_ts then
    return nil, to_err
  end

  -- Compare the resolved bounds unconditionally: an open bound resolved to a daybook extreme can still
  -- cross the given one ("..2020" when all logs are later), which should read as a reversed range, not
  -- the misleading "no daybook logs found" an empty span would otherwise produce.
  if from_ts > to_ts then
    return nil, "daylog: range start is after end"
  end

  return daybook.range_dates(from_ts, to_ts)
end

-- Resolve a parsed report request -- `{ count = N }` or `{ from, to }` -- into its concrete
-- date list: a count pins the trailing days ending today, a range resolves each bound.
-- Returns the dates, or nil and an error message.
local function resolve_report_dates(request)
  if request.count then
    return daybook.trailing_dates(os.time(), request.count)
  end

  return resolve_range_dates(request)
end

-- Open a multi-day report over `range`: a count ("7"), a "FROM..TO" token range, or a pre-parsed
-- request table (`{ count = N }` / `{ from, to }`). `aggregate_only` shows only the period total.
function M.report(range, aggregate_only)
  local request = type(range) == "table" and range or daybook.parse_report_range(range or "")
  if not request then
    warn("daylog: report expects a day count or a FROM..TO range (e.g. 7, monday..today, ..today)")
    return
  end

  local dates, err = resolve_report_dates(request)
  if not dates then
    warn(err)
    return
  end

  -- Buffer name keeps the requested range (stable); the header label resolves to days found.
  local request_label = #dates > 0 and daybook.date_range_label(dates[1], dates[#dates]) or nil

  open_report({
    dates = dates,
    request_label = request_label,
    aggregate_only = aggregate_only or false,
  })
end

-- Export a range's activities as CSV or JSON. With a `path` it writes the file (creating parent dirs);
-- otherwise it opens a read-only preview buffer to yank or `:w <path>` yourself. Returns the rendered
-- string for scripting. `range` reuses the report date vocabulary (a count "7", a "FROM..TO" token
-- range, named tokens), defaulting to today. The numbers match `:Daylog report`.
function M.export(format, range, path)
  format = type(format) == "string" and format:lower() or ""
  if format ~= "csv" and format ~= "json" then
    warn("daylog: export expects a format: csv or json")
    return
  end

  local request
  if range == nil or range == "" then
    request = { count = 1 }
  else
    request = daybook.parse_report_range(range)
  end
  if not request then
    warn("daylog: export range expects a day count or a FROM..TO range (e.g. 7, monday..today)")
    return
  end

  local dates, err = resolve_report_dates(request)
  if not dates then
    warn(err)
    return
  end

  local request_label = #dates > 0 and daybook.date_range_label(dates[1], dates[#dates]) or "export"
  return open_export({ dates = dates, request_label = request_label }, format, path)
end

-- The report spec stored on `buf` (current when nil), or nil when it is not a daylog report.
-- Centralizes the pcall + type-check against the "log_report" var.
function M.spec_for(buf)
  local ok, spec = pcall(vim.api.nvim_buf_get_var, buf or 0, "log_report")
  if ok and type(spec) == "table" then
    return spec
  end
  return nil
end

-- Rebuild every open report buffer from its stored spec. A build failure leaves the last good
-- report untouched, and an unchanged report is left alone so the cursor never jumps.
local function refresh_report_windows()
  local refreshed = {}

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local spec = M.spec_for(buf)

    if spec and not refreshed[buf] then
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
M.open_export = open_export
M.refresh_report_windows = refresh_report_windows

return M
