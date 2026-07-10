local buffer = require("daylog.buffer")
local config = require("daylog.config")
local pick = require("daylog.pick")
local daybook_io = require("daylog.daybook_io")
local render = require("daylog.render")
local report_buffers = require("daylog.report")
local report_write = require("daylog.report_write")
local report_cursor = require("daylog.usecases.report_cursor")
local support = require("daylog.usecases.support")
local log_current = require("daylog.usecases.log_current")

local M = {}

-- Logging from a multi-day report (shell).
--
-- `:Daylog log` / `:Daylog! log` on a report row mark (or clear) the item the row stands for across the
-- relevant day files: a per-day row in that one file, an aggregate row across every day of the period.
-- The report stays a pure projection -- the mark is computed and written per source file (by value, via
-- log_current), mirroring rename_from_report. The single-buffer log path stays in init.lua/log_current.

local warn = buffer.warn
local cursor_row = buffer.cursor_row
local buffer_changed = buffer.buffer_changed
local daybook_lines = daybook_io.daybook_lines
local build_report_for_spec = report_buffers.build_report_for_spec
local refresh_report_windows = report_buffers.refresh_report_windows

local LEVEL_LABEL = { s = "activity", t = "tag", l = "location", w = "workday" }

-- The confirm sentence for a report-wide log/unlog (the affected files are listed by report_write).
local function action_sentence(target, names, unlog)
  local what = target.value and string.format("%s '%s'", LEVEL_LABEL[target.level], target.value)
    or LEVEL_LABEL[target.level]
  if unlog then
    return "unlog " .. what
  end
  if names and #names > 0 then
    return string.format("log %s under [%s]", what, table.concat(names, ", "))
  end
  return "log " .. what
end

-- Mark (or clear) `target` across `paths` under `names`, after confirmation. A day lacking the item --
-- or, for unlog, not logged -- is skipped; a real error aborts before any file is written.
local function apply(target, paths, names, unlog, target_buf)
  if buffer_changed(target_buf, unlog and "unlog" or "log") then
    return
  end

  local changes = {}
  for _, path in ipairs(paths) do
    local lines = daybook_lines(path)
    if lines then
      local result, run_err
      if unlog then
        result, run_err = log_current.run_unlog_by_value(lines, target, names)
      else
        result, run_err = log_current.run_by_value(lines, target, names)
      end
      if result then
        changes[#changes + 1] = { path = path, lines = support.apply_edits(lines, result.edits) }
      elseif run_err then
        warn(run_err)
        return
      end
    end
  end

  if #changes == 0 then
    warn(
      string.format(
        "daylog: no day in this report has that %s%s",
        LEVEL_LABEL[target.level],
        unlog and " logged" or ""
      )
    )
    return
  end

  if not report_write.confirm(action_sentence(target, names, unlog), changes) then
    return
  end

  report_write.apply_changes(changes)
  refresh_report_windows()
end

-- Log (or, with `unlog`, unlog) the report row under the cursor across its day files. The name picker
-- opens ONCE; the chosen name-set applies to every target file.
function M.from_report(spec, unlog)
  local report, err = build_report_for_spec(spec)
  if not report then
    warn(err)
    return
  end

  local duration_format = config.get().defaults.duration_format
  local layout =
    render.days_report_layout(report, duration_format, { aggregate_only = spec.aggregate_only })

  local resolved, resolve_err =
    report_cursor.resolve(layout, cursor_row(), log_current.classify_report_row)
  if not resolved then
    warn(resolve_err)
    return
  end

  local target = resolved.target
  local paths = report_write.target_paths(report, resolved)
  local target_buf = vim.api.nvim_get_current_buf()

  local function fan_out(names)
    apply(target, paths, names, unlog, target_buf)
  end

  if unlog then
    -- With several logged names, choose which to remove; with one or none, clear the marker outright.
    local names = target.names or {}
    if #names < 2 then
      fan_out(nil)
      return
    end
    pick.pick_names_from(names, { on_select = fan_out, on_cancel = function() end })
    return
  end

  pick.pick_names(target.level, { on_select = fan_out, on_cancel = function() end })
end

return M
