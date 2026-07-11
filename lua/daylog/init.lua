-- Public verb facade and setup() composition root (shell).

local append_copy = require("daylog.usecases.append_copy")
local auto_summary = require("daylog.auto_summary")
local autosave = require("daylog.autosave")
local balance_summary = require("daylog.usecases.balance_summary")
local buffer = require("daylog.buffer")
local commands = require("daylog.commands")
local config = require("daylog.config")
local current_time = require("daylog.current_time")
local daybook_io = require("daylog.daybook_io")
local days = require("daylog.days")
local filetype = require("daylog.filetype")
local insert = require("daylog.insert")
local keymaps = require("daylog.keymaps")
local log_current = require("daylog.usecases.log_current")
local map = require("daylog.map")
local order_logs = require("daylog.usecases.order_logs")
local pick = require("daylog.pick")
local rename = require("daylog.rename")
local repeat_current = require("daylog.usecases.repeat_current")
local report_buffers = require("daylog.report")
local sources_registry = require("daylog.sources.registry")
local sources_sync = require("daylog.sources.sync")
local sources_wire = require("daylog.sources.wire")
local split_summary = require("daylog.usecases.split_summary")

local M = {}

M.highlight_buffer = buffer.highlight_buffer
M.refresh_indicators = buffer.refresh_indicators
M.render_stray = buffer.render_stray
M.rename_summary = rename.summary
M.map_summary = map.summary
M.map_clear = map.clear

-- Public verb API (require("daylog").<verb>): the interface :Daylog and user keymaps dispatch to.

M.today = days.today
M.day = days.day
M.next_day = days.next_day
M.prev_day = days.prev_day
M.open_relative_day = days.open_relative_day

M.insert = insert.insert
M.insert_now = insert.insert_now
M.insert_from_source = insert.insert_from_source
M.insert_unified = insert.insert_unified

M.report = report_buffers.report
M.export = report_buffers.export

-- Install the daybook post-commit audit hook (see docs/version-control.md). Lazy-required so this
-- rarely-used tooling never loads on the common path.
function M.install_commit_audit_hook(opts)
  return require("daylog.commit_audit_install").run(opts)
end

-- Refresh the on-disk cache for one source, or every configured source.
function M.sync(name)
  if name and name ~= "" then
    if not sources_registry.get(name) then
      buffer.warn("daylog: unknown source '" .. name .. "'")
      return
    end

    sources_sync.sync(name, { silent = false })
    return
  end

  local names = sources_registry.names()
  if #names == 0 then
    buffer.warn("daylog: no sources configured")
    return
  end

  for _, source_name in ipairs(names) do
    sources_sync.sync(source_name, { silent = false })
  end
end

function M.copy()
  buffer.run_buffer_usecase(append_copy.run)
end

-- Scaffold a fresh, empty log into the current buffer; the scaffold and defaults live in daybook_io.
function M.new_log()
  daybook_io.insert_new_log()
end

function M.repeat_()
  if current_time.guard_current_time("repeat") then
    return
  end

  buffer.run_buffer_usecase(
    repeat_current.run,
    buffer.cursor_row(),
    os.date("%H:%M"),
    daybook_io.live_offset()
  )
end

function M.order()
  local result, err = order_logs.run(buffer.buffer_lines())
  if not result then
    buffer.warn(err)
    return
  end

  buffer.apply_result(result)

  if result.warnings and #result.warnings > 0 then
    buffer.warn(
      "daylog: ordering set the tag/location/utc offset of order-dependent entries; review: "
        .. table.concat(result.warnings, ", ")
    )
  end
end

-- Log the cursor's summary row: open the frecency names picker at the row's level and ADD the chosen
-- names to the slice -- a fresh mark when the row is unlogged, else the names union onto its existing
-- marker. `:Daylog! log` / `<leader>dL` (M.unlog) removes names. A non-loggable cursor surfaces the
-- usecase's error.
function M.log()
  -- On a report buffer, the log fans out across the relevant day files (like rename).
  local report_spec = report_buffers.spec_for()
  if report_spec then
    require("daylog.log").from_report(report_spec, false)
    return
  end

  local row = buffer.cursor_row()
  local peek, err = log_current.peek(buffer.buffer_lines(), row)

  if not peek then
    buffer.warn(err)
    return
  end

  local target_buf = vim.api.nvim_get_current_buf()
  pick.pick_names(peek.level, {
    on_select = function(names)
      buffer.run_pinned_usecase(target_buf, "log", function(lines)
        return log_current.run(lines, row, names)
      end)
    end,
    on_cancel = function() end,
  })
end

-- Unlog the cursor's slice (`:Daylog! log` / `<leader>dL`). With several logged names it opens a picker
-- over them to choose which to remove; with one or none it clears the marker outright (the usecase
-- refuses an unlogged row).
function M.unlog()
  local report_spec = report_buffers.spec_for()
  if report_spec then
    require("daylog.log").from_report(report_spec, true)
    return
  end

  local row = buffer.cursor_row()
  local peek, err = log_current.peek(buffer.buffer_lines(), row)

  if not peek then
    buffer.warn(err)
    return
  end

  local names = peek.names or {}
  if #names < 2 then
    buffer.run_buffer_usecase(log_current.run_unlog, row)
    return
  end

  local target_buf = vim.api.nvim_get_current_buf()
  pick.pick_names_from(names, {
    on_select = function(remove)
      buffer.run_pinned_usecase(target_buf, "log", function(lines)
        return log_current.run_unlog(lines, row, remove)
      end)
    end,
    on_cancel = function() end,
  })
end

-- Manually balance summary rounding by `delta` q-steps (signed; 0 clears the nudge); the
-- cursor may sit on a summary row or an entry.
function M.balance(arg)
  local delta = 1

  if arg ~= nil and arg ~= "" then
    -- Match a signed decimal integer before tonumber, so hex/exponent literals (0x2, 1e1) warn
    -- rather than silently balancing -- mirroring commands.parse_positive_integer's `^%d+$` guard.
    if not tostring(arg):match("^[%+%-]?%d+$") then
      buffer.warn("daylog: balance expects an integer step count, e.g. +1, -2, or 0 to clear")
      return
    end
    delta = tonumber(arg)
  end

  buffer.run_buffer_usecase(balance_summary.run, buffer.cursor_row(), delta)
end

-- Split the cursor activity into weighted sub-activities; `fargs` are positive weights (none
-- means an even two-way split). Total time is preserved.
function M.split(fargs)
  local weights = {}

  for _, arg in ipairs(fargs or {}) do
    local w = tonumber(arg)
    if w == nil or w <= 0 then
      buffer.warn("daylog: split weights must be positive numbers, e.g. :Daylog split 2 1 1")
      return
    end
    weights[#weights + 1] = w
  end

  if #weights == 1 then
    buffer.warn("daylog: split needs at least two weights, or none for an even split")
    return
  end

  buffer.run_buffer_usecase(split_summary.run, buffer.cursor_row(), weights)
end

-- Rebuild every existing summary in the current buffer to match its entries.
function M.refresh()
  buffer.apply_refresh(false)
end

-- Map the cursor entry/summary row to a label. opts.clear removes it; opts.value sets it
-- directly; opts.source opens that tracker's picker; opts.range maps a visual range.
function M.map(opts)
  opts = opts or {}
  if opts.clear then
    return M.map_clear(opts.range)
  end
  return M.map_summary(opts.value, opts.source, opts.range)
end

-- Rename what a summary row reports under. opts.value renames directly; opts.source opens that
-- tracker's picker; neither opens the unified recent+sources picker.
function M.rename(opts)
  opts = opts or {}
  return M.rename_summary(opts.value, opts.source, opts.range)
end

-- Show the keymap cheatsheet popup (:Daylog keys, and g? in the default set).
function M.keys()
  require("daylog.keys").show()
end

-- Toggle the colour-coded time bar (initial state from the `time_bar` config); the toggle is
-- global, not per buffer.
function M.bar()
  if vim.bo.filetype ~= "daylog" then
    buffer.warn("daylog: the time bar is shown in daylog files")
    return
  end
  buffer.toggle_time_bar()
end

function M.setup(options)
  config.setup(options)
  filetype.register()
  sources_wire.instantiate()
  commands.register()

  auto_summary.setup(config.get().auto_summary)
  autosave.setup(config.get().autosave)
  keymaps.setup()
end

return M
