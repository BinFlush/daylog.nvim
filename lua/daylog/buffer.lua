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
-- buffer, keeping diagnostics and highlights in sync and guarding the auto-refresh
-- loop. Owns the refresh-guard flag and the diagnostic / highlight namespaces;
-- nothing outside this module touches them.

local function warn(message)
  vim.notify(message, vim.log.levels.WARN)
end

-- Tell the user, on the rare current-time insert that recorded a UTC offset change
-- (DST/travel via auto_timezone), what was stamped -- so a silently shifted clock
-- does not go unnoticed. `from` is always a real offset (the in-effect baseline).
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

-- Guards the refresh edits from re-triggering the auto-refresh autocmds, and
-- signals apply_result that apply_refresh will publish diagnostics itself.
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

-- The active-log and stray sign defs are registered lazily on first use (mirroring the
-- highlight groups), so they work whether or not setup() ran.
-- One sign per palette colour: a `▎` in the activity's foreground colour (DaylogSignN). The active
-- indicator places the matching one on each row, so the margin reads as a per-activity colour bar.
local activity_signs_defined = false
local function ensure_activity_signs()
  if activity_signs_defined then
    return
  end
  for i = 1, highlight.PALETTE_SIZE do
    vim.fn.sign_define("DaylogActivitySign" .. i, { text = "▌", texthl = "DaylogSign" .. i })
  end
  activity_signs_defined = true
end

-- The activity sign name for a colour index (cycling through the palette).
local function activity_sign(color_index)
  return "DaylogActivitySign" .. ((color_index - 1) % highlight.PALETTE_SIZE + 1)
end

local stray_sign_defined = false
local function ensure_stray_sign()
  if stray_sign_defined then
    return
  end
  vim.fn.sign_define("DaylogStray", { text = "▎", texthl = "DaylogStraySign" })
  stray_sign_defined = true
end

-- Register the daylog highlight groups as default links (so a user's own
-- highlight overrides win). Done lazily on first highlight so it works whether or
-- not setup() ran.
local function ensure_highlight_groups()
  if highlight_groups_defined then
    return
  end

  for group, spec in pairs(highlight.GROUPS) do
    -- A string spec is a link target; a table is an explicit attribute set (the headers
    -- use { bold = true } so they read as structure in any theme, not only where a linked
    -- group happens to differ from Comment). default = true keeps theme/user overrides winning.
    if type(spec) == "string" then
      vim.api.nvim_set_hl(0, group, { link = spec, default = true })
    else
      vim.api.nvim_set_hl(0, group, vim.tbl_extend("keep", spec, { default = true }))
    end
  end

  highlight_groups_defined = true
end

-- The red "you've strayed off the active log" mark: a soft-red bar on the cursor's line whenever
-- it sits above the active region (`vim.b.daylog_active_start`, cached by render_active_bar; nil
-- when there is nothing to mark -- disabled, fewer than two logs, or the file is not clean).
-- Always clears the group and re-places, so an edit that shifts the sign (an `O` above) or drops
-- it (a summary regen replacing the line) can never leave it stale -- one sign op per cursor move,
-- synchronous, so no flicker.
local function render_stray(buf)
  buf = resolve_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.fn.sign_unplace("daylog_stray", { buffer = buf })

  local active_start = vim.b[buf].daylog_active_start
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if active_start and row < active_start then
    ensure_stray_sign()
    vim.fn.sign_place(0, "daylog_stray", "DaylogStray", buf, { lnum = row, priority = 6 })
  end
end

-- Place the per-activity colour bar in the left margin: a `▎` coloured by each row's activity (the
-- entries, the notes beneath them, and the main summary rows), so an activity reads as one connected
-- colour everywhere. Gated on the cached `daylog_clean` flag so a diagnostic hides it without
-- re-checking warnings here. Runs on the LIVE highlight pass (every keystroke), so it tracks edits
-- and is restored whenever an edit drops the signs; `daylog_active_start` (the stray mark's boundary)
-- is cached alongside.
local function render_indicator(buf, lines, analysis)
  vim.fn.sign_unplace("daylog_active", { buffer = buf })

  local active_start = nil
  if config.get().active_indicator and vim.b[buf].daylog_clean then
    local indicator = highlight.indicator_rows(lines, analysis)
    if indicator.active_start then
      active_start = indicator.active_start
      ensure_activity_signs()
      for row, color_index in pairs(indicator.rows) do
        vim.fn.sign_place(
          0,
          "daylog_active",
          activity_sign(color_index),
          buf,
          { lnum = row, priority = 5 }
        )
      end
    end
  end

  vim.b[buf].daylog_active_start = active_start
end

-- Apply the parser-driven highlight spans to a buffer as extmarks (replacing the previous set)
-- and re-place the active-log bar + stray mark from the current text/cursor. The single LIVE
-- path: daylog files attach it via the ftplugin (every keystroke, including insert), report
-- buffers call it directly, and the edit-applying shell refreshes it after programmatic edits
-- (which fire no change autocmds). Narrower token spans carry a higher priority than the
-- whole-line base ones, so a tag inside a header wins at its cells. The bars track live, but
-- their clean/dirty gate is frozen here (cached `daylog_clean`); refresh_indicators updates the
-- gate on settle, so the bars never flicker through a half-typed warning.
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

-- Flip the global time bar on/off (timebar_ui owns the state) and redraw every visible daylog buffer
-- so the change shows at once across splits (others pick it up via the ftplugin when navigated to).
local function toggle_time_bar()
  timebar_ui.toggle()
  -- Collect the on-screen daylog buffers before redrawing any: a redraw can open or close a strip
  -- window, which would invalidate a window id still pending in a single combined loop.
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

-- Refresh the clean/dirty gate (any diagnostic in any log hides the bars) and re-render. The
-- SETTLE path -- normal-mode edits, leaving insert, command edits, load -- so the gate (and the
-- heavier refresh_summaries it needs) holds steady through an insert session, matching when the
-- diagnostics themselves refresh.
local function refresh_indicators(buf)
  buf = resolve_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.b[buf].daylog_clean = #refresh_summaries.run(lines).warnings == 0
  highlight_buffer(buf)
end

-- Publish the log's problems (e.g. out-of-order timestamps) as buffer
-- diagnostics. They are recomputed and replace the previous set on every refresh,
-- so they clear themselves as soon as the log is valid again -- however it
-- was fixed -- and render inline in any mode.
local function publish_diagnostics(warnings)
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

  vim.diagnostic.set(diagnostic_namespace, 0, items)
end

-- Recompute and publish the buffer's log diagnostics from its current text.
local function refresh_diagnostics()
  publish_diagnostics(refresh_summaries.run(buffer_lines()).warnings)
end

local function apply_result(result)
  -- A row-only cursor follow (e.g. a balanced summary row that reordered) keeps the
  -- user's column: capture it before the edits move things, then clamp it to the
  -- destination line below.
  local preserved_col
  if result.cursor_row then
    preserved_col = vim.api.nvim_win_get_cursor(0)[2]
  end

  -- Apply edits in the order given -- never reorder or sort them. refresh_summaries.run
  -- composes header-recovery edits (in the original coordinates) ahead of summary edits
  -- (in the post-recovery coordinates) as two ordered phases; a recovery that inserts a
  -- synthesized log header shifts rows, so reordering these together would corrupt the
  -- result. (Guarded by a core_commands test that drives an insert-based recovery here.)
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
    vim.cmd("startinsert!")
  end

  if result.offset_change then
    notify_offset_change(result.offset_change)
  end

  -- Keep buffer diagnostics current after any edit. This is the single choke
  -- point every edit path flows through. apply_refresh already publishes from its
  -- own analysis (and sets `refreshing` around its edit), so skip while it runs.
  if not refreshing then
    refresh_diagnostics()
  end

  -- Programmatic edits do not fire the change autocmds the ftplugin highlighter
  -- listens on, so refresh highlights from this single edit choke point too.
  if vim.bo.filetype == "daylog" then
    -- A command edit re-evaluates the gate; the auto-refresh path only re-renders (cached gate),
    -- restoring any bar signs its summary edits dropped without a mid-insert gate change.
    if not refreshing then
      refresh_indicators(0)
    else
      highlight_buffer(0)
    end
  end
end

-- Run a use case over the current buffer and apply its edit script, warning on
-- failure. Extra arguments are forwarded to the use case after the buffer lines.
local function run_buffer_usecase(run, ...)
  local result, err = run(buffer_lines(), ...)
  if not result then
    warn(err)
    return false
  end

  apply_result(result)
  return true
end

-- Run `fn` (which may resize or replace the buffer's lines) while preserving the
-- cursor in `win`, restoring it afterwards clamped to the buffer's new line count and
-- the landing line's length, so a shrunk buffer or a shorter line never throws.
local function with_preserved_cursor(win, buf, fn)
  local cursor = vim.api.nvim_win_get_cursor(win)
  fn()
  local line_count = vim.api.nvim_buf_line_count(buf)
  local row = math.min(cursor[1], line_count)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  vim.api.nvim_win_set_cursor(win, { row, math.min(cursor[2], #line) })
end

-- True (after warning) when the current buffer is no longer `target_buf`: an async
-- picker's selection arrived after the user moved away, so the edit must abort rather
-- than touch the wrong buffer. `op` names the aborted operation in the warning.
local function buffer_changed(target_buf, op)
  if vim.api.nvim_get_current_buf() == target_buf then
    return false
  end

  warn("daylog: buffer changed during selection; aborting " .. op)
  return true
end

-- run_buffer_usecase for an async callback (a picker selection that may arrive after the user
-- moved away): abort with a warning when the current buffer is no longer `target_buf` (`op`
-- names it), otherwise run-and-apply. The synchronous twin of run_buffer_usecase.
local function run_pinned_usecase(target_buf, op, run, ...)
  if buffer_changed(target_buf, op) then
    return false
  end
  return run_buffer_usecase(run, ...)
end

-- Rebuild every log's existing summary to match its entries, and publish the
-- buffer diagnostics for any problems found. A no-op edit-wise when all summaries
-- are already current. `join` merges the edit into the previous undo block, used
-- by the autocmd-driven refreshes so one keystroke stays one undo step.
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
  pcall(function()
    if join then
      pcall(vim.cmd, "undojoin")
    end

    with_preserved_cursor(0, 0, function()
      apply_result(result)
    end)
  end)
  refreshing = false
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
