local activity_hl = require("daylog.activity_hl")
local config = require("daylog.config")
local highlight = require("daylog.highlight")
local timebar_ui = require("daylog.timebar_ui")
local refresh_summaries = require("daylog.usecases.refresh_summaries")
local syntax = require("daylog.syntax")
local text = require("daylog.text")

local M = {}

-- Buffer-orchestration substrate (shell).
--
-- The single choke point through which every command's edit script reaches the
-- buffer, owning the refresh-guard flag and the diagnostic / highlight namespaces.

local function warn(message)
  vim.notify(message, vim.log.levels.WARN)
end

-- Tell the user what UTC offset change a current-time insert stamped, so a silently
-- shifted clock (DST/travel via auto_timezone) does not go unnoticed.
local function notify_offset_change(change)
  vim.notify(
    string.format(
      "daylog: UTC offset %s → %s recorded",
      syntax.utc_offset_token(change.from),
      syntax.utc_offset_token(change.to)
    ),
    vim.log.levels.INFO
  )
end

---@return string[]
local function buffer_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function buffer_is_empty()
  return text.is_empty(buffer_lines())
end

---@return integer
local function cursor_row()
  return vim.api.nvim_win_get_cursor(0)[1]
end

-- Guards refresh edits from re-triggering the auto-refresh autocmds; also signals
-- apply_result that apply_refresh publishes diagnostics itself.
local refreshing = false

local diagnostic_namespace = vim.api.nvim_create_namespace("daylog")

local highlight_namespace = vim.api.nvim_create_namespace("daylog-highlight")
local highlight_groups_defined = false

-- Resolve to a concrete buffer number: the sign_* API rejects the 0 = current-buffer
-- shorthand the nvim_buf_* API accepts (E158).
local function resolve_buf(buf)
  buf = buf or 0
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  return buf
end

-- Register the stray-cursor sign lazily on first use, so it works whether or not setup() ran.
local stray_sign_defined = false
local function ensure_stray_sign()
  if stray_sign_defined then
    return
  end
  vim.fn.sign_define("DaylogStray", { text = "▎", texthl = "DaylogStraySign" })
  stray_sign_defined = true
end

-- Register the daylog highlight groups lazily, as default links so a user's own overrides win.
local function ensure_highlight_groups()
  if highlight_groups_defined then
    return
  end

  for group, spec in pairs(highlight.GROUPS) do
    -- A string spec is a link target, a table an explicit attribute set; default = true keeps
    -- theme/user overrides winning.
    if type(spec) == "string" then
      vim.api.nvim_set_hl(0, group, { link = spec, default = true })
    else
      vim.api.nvim_set_hl(0, group, vim.tbl_extend("keep", spec, { default = true }))
    end
  end

  highlight_groups_defined = true
end

-- A colorscheme switch clears our default highlight groups; forget the cache so the next render
-- re-creates them.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("DaylogColorScheme", { clear = true }),
  callback = function()
    highlight_groups_defined = false
  end,
})

-- Mark the cursor's line when it sits above the active region (`daylog_active_start`; nil when
-- there is nothing to mark). Always unplaces then re-places, so a shifted or dropped sign can
-- never go stale.
local function render_stray(buf)
  buf = resolve_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.fn.sign_unplace("daylog_stray", { buffer = buf })

  local active_start = vim.b[buf].daylog_active_start
  if not active_start then
    return
  end

  -- Read the cursor from a window actually showing `buf` (highlight passes also run over
  -- non-current buffers); no window showing it, no mark.
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= buf then
    win = vim.fn.win_findbuf(buf)[1]
  end
  if not win then
    return
  end

  local row = vim.api.nvim_win_get_cursor(win)[1]
  if row < active_start then
    ensure_stray_sign()
    vim.fn.sign_place(0, "daylog_stray", "DaylogStray", buf, { lnum = row, priority = 6 })
  end
end

-- Place the per-activity colour bar in the left margin, gated on the cached `daylog_clean` flag so
-- a diagnostic hides it. Runs on the live highlight pass; caches `daylog_active_start` alongside.
local function render_indicator(buf, lines, analysis)
  vim.fn.sign_unplace("daylog_active", { buffer = buf })

  local active_start = nil
  if config.get().active_indicator and vim.b[buf].daylog_clean then
    local indicator = highlight.indicator_rows(lines, analysis)
    if indicator.active_start then
      active_start = indicator.active_start
      for row, color_index in pairs(indicator.rows) do
        vim.fn.sign_place(
          0,
          "daylog_active",
          activity_hl.activity_sign(color_index),
          buf,
          { lnum = row, priority = 5 }
        )
      end
    end
  end

  vim.b[buf].daylog_active_start = active_start
end

-- Apply the parser-driven highlight spans as extmarks and re-place the bars from the current
-- text/cursor. The single live path; the edit-applying shell must call it after programmatic
-- edits, which fire no change autocmds. The clean/dirty gate is frozen here (cached
-- `daylog_clean`); refresh_indicators updates it on settle so the bars never flicker.
local function highlight_buffer(buf)
  buf = resolve_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  ensure_highlight_groups()
  vim.api.nvim_buf_clear_namespace(buf, highlight_namespace, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- One parse + analyze for the whole pass, shared by the spans, the indicator, and the bar.
  local parsed, analysis = highlight.parse_and_analyze(lines)
  for _, span in ipairs(highlight.spans(lines, parsed, analysis)) do
    vim.api.nvim_buf_set_extmark(buf, highlight_namespace, span.line, span.col_start, {
      end_col = span.col_end,
      hl_group = span.group,
      priority = span.priority,
    })
  end

  render_indicator(buf, lines, analysis)
  render_stray(buf)
  timebar_ui.render(buf, lines, analysis)
end

-- Flip the global time bar on/off and redraw every visible daylog buffer so it shows across splits.
local function toggle_time_bar()
  timebar_ui.toggle()
  -- Collect the buffers before redrawing any: a redraw can open/close a strip window and
  -- invalidate a pending window id.
  local daylog_bufs = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local win_buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[win_buf].filetype == "daylog" then
      daylog_bufs[win_buf] = true
    end
  end
  for win_buf in pairs(daylog_bufs) do
    highlight_buffer(win_buf)
  end
end

-- Publish the log's problems as diagnostics on `buf`, replacing the previous set so they clear
-- themselves once the log is valid again.
local function publish_diagnostics(warnings, buf)
  local items = {}

  for _, warning in ipairs(warnings or {}) do
    table.insert(items, {
      lnum = math.max((warning.row or 1) - 1, 0),
      col = 0,
      severity = vim.diagnostic.severity.WARN,
      source = "daylog",
      message = warning.message,
    })
  end

  vim.diagnostic.set(diagnostic_namespace, resolve_buf(buf), items)
end

-- Refresh the clean/dirty gate, publish its warnings as diagnostics, and re-render. The settle
-- path (normal-mode edits, leaving insert, command edits, load), so the gate holds steady through
-- an insert session.
local function refresh_indicators(buf)
  buf = resolve_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local warnings = refresh_summaries.run(lines).warnings
  publish_diagnostics(warnings, buf)
  vim.b[buf].daylog_clean = #warnings == 0
  highlight_buffer(buf)
end

local function refresh_diagnostics()
  publish_diagnostics(refresh_summaries.run(buffer_lines()).warnings)
end

local function apply_result(result)
  -- A row-only cursor follow keeps the user's column: capture it before the edits move things.
  local preserved_col
  if result.cursor_row then
    preserved_col = vim.api.nvim_win_get_cursor(0)[2]
  end

  -- Apply edits in the order given -- never reorder: recovery edits (original coordinates) precede
  -- summary edits (post-recovery coordinates), so reordering would corrupt the result.
  for _, edit in ipairs(result.edits or {}) do
    vim.api.nvim_buf_set_lines(0, edit.start_index, edit.end_index, false, edit.lines)
  end

  if result.cursor then
    vim.api.nvim_win_set_cursor(0, result.cursor)
  elseif result.cursor_row then
    local line = vim.api.nvim_buf_get_lines(0, result.cursor_row - 1, result.cursor_row, false)[1]
      or ""
    vim.api.nvim_win_set_cursor(0, { result.cursor_row, math.min(preserved_col, #line) })
  end

  if result.startinsert then
    -- `startinsert!` appends at end-of-line; "cursor" keeps insert at the column the usecase placed.
    vim.cmd(result.startinsert == "cursor" and "startinsert" or "startinsert!")
  end

  if result.offset_change then
    notify_offset_change(result.offset_change)
  end

  -- Keep diagnostics current after any edit; apply_refresh already publishes from its own
  -- analysis (guarded by `refreshing`), so skip while it runs.
  if not refreshing then
    refresh_diagnostics()
  end

  -- Programmatic edits fire no change autocmds, so refresh highlights from this choke point too.
  if vim.bo.filetype == "daylog" then
    -- A command edit re-evaluates the gate; the auto-refresh path only re-renders (cached gate).
    if not refreshing then
      refresh_indicators(0)
    else
      highlight_buffer(0)
    end
  end
end

-- Run a use case over the current buffer and apply its edit script, warning on failure.
local function run_buffer_usecase(run, ...)
  local result, err = run(buffer_lines(), ...)
  if not result then
    warn(err)
    return false
  end

  apply_result(result)
  return true
end

-- Run `fn` while preserving the cursor in `win`, restoring it clamped to the new line count and
-- landing line's length so a shrunk buffer never throws.
local function with_preserved_cursor(win, buf, fn)
  local cursor = vim.api.nvim_win_get_cursor(win)
  fn()
  local line_count = vim.api.nvim_buf_line_count(buf)
  local row = math.min(cursor[1], line_count)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  vim.api.nvim_win_set_cursor(win, { row, math.min(cursor[2], #line) })
end

-- True (after warning) when the current buffer is no longer `target_buf`: an async selection
-- arrived after the user moved away, so the edit must abort. `op` names it in the warning.
local function buffer_changed(target_buf, op)
  if vim.api.nvim_get_current_buf() == target_buf then
    return false
  end

  warn("daylog: buffer changed during selection; aborting " .. op)
  return true
end

-- run_buffer_usecase for an async callback: abort when the current buffer is no longer
-- `target_buf` (`op` names it), otherwise run-and-apply.
local function run_pinned_usecase(target_buf, op, run, ...)
  if buffer_changed(target_buf, op) then
    return false
  end
  return run_buffer_usecase(run, ...)
end

-- Rebuild every log's summary to match its entries and publish diagnostics; a no-op edit-wise when
-- current. `join` merges the edit into the previous undo block so one keystroke stays one undo step.
local function apply_refresh(join)
  if refreshing then
    return
  end

  local result = refresh_summaries.run(buffer_lines())
  publish_diagnostics(result.warnings)

  if not result.edits or #result.edits == 0 then
    return
  end

  refreshing = true
  local ok, err = pcall(function()
    if join then
      pcall(vim.cmd, "undojoin")
    end

    with_preserved_cursor(0, 0, function()
      apply_result(result)
    end)
  end)
  refreshing = false

  if not ok then
    warn("daylog: summary refresh failed: " .. tostring(err))
  end
end

M.warn = warn
M.buffer_lines = buffer_lines
M.buffer_is_empty = buffer_is_empty
M.cursor_row = cursor_row
M.highlight_buffer = highlight_buffer
M.refresh_indicators = refresh_indicators
M.render_stray = render_stray
M.toggle_time_bar = toggle_time_bar
M.publish_diagnostics = publish_diagnostics
M.apply_result = apply_result
M.run_buffer_usecase = run_buffer_usecase
M.run_pinned_usecase = run_pinned_usecase
M.with_preserved_cursor = with_preserved_cursor
M.buffer_changed = buffer_changed
M.apply_refresh = apply_refresh

return M
