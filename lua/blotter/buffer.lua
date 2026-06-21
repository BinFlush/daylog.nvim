local highlight = require("blotter.highlight")
local refresh_summaries = require("blotter.usecases.refresh_summaries")
local text = require("blotter.text")

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

local diagnostic_namespace = vim.api.nvim_create_namespace("blotter")

local highlight_namespace = vim.api.nvim_create_namespace("blotter-highlight")
local highlight_groups_defined = false

-- Register the blotter highlight groups as default links (so a user's own
-- highlight overrides win). Done lazily on first highlight so it works whether or
-- not setup() ran.
local function ensure_highlight_groups()
  if highlight_groups_defined then
    return
  end

  for group, link in pairs(highlight.GROUPS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end

  highlight_groups_defined = true
end

-- Apply the parser-driven highlight spans to a buffer as extmarks, replacing the
-- previous set. This is the single highlighting path: blotter files attach it via
-- the ftplugin, the report buffers call it directly, and the edit-applying shell
-- refreshes it after programmatic edits (which do not fire change autocmds). The
-- narrower token spans carry a higher priority than the whole-line base ones, so
-- a tag inside a header wins at its cells.
local function highlight_buffer(buf)
  buf = buf or 0
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  ensure_highlight_groups()
  vim.api.nvim_buf_clear_namespace(buf, highlight_namespace, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, span in ipairs(highlight.spans(lines)) do
    vim.api.nvim_buf_set_extmark(buf, highlight_namespace, span.line, span.col_start, {
      end_col = span.col_end,
      hl_group = span.group,
      priority = span.priority,
    })
  end
end

-- Publish the blotter's problems (e.g. out-of-order timestamps) as buffer
-- diagnostics. They are recomputed and replace the previous set on every refresh,
-- so they clear themselves as soon as the blotter is valid again -- however it
-- was fixed -- and render inline in any mode.
local function publish_diagnostics(warnings)
  local items = {}

  for _, warning in ipairs(warnings or {}) do
    table.insert(items, {
      lnum = math.max((warning.row or 1) - 1, 0),
      col = 0,
      severity = vim.diagnostic.severity.WARN,
      source = "blotter",
      message = warning.message,
    })
  end

  vim.diagnostic.set(diagnostic_namespace, 0, items)
end

-- Recompute and publish the buffer's blotter diagnostics from its current text.
local function refresh_diagnostics()
  publish_diagnostics(refresh_summaries.run(buffer_lines()).warnings)
end

local function apply_result(result)
  -- Apply edits in the order given -- never reorder or sort them. refresh_summaries.run
  -- composes header-recovery edits (in the original coordinates) ahead of summary edits
  -- (in the post-recovery coordinates) as two ordered phases; a recovery that inserts a
  -- synthesized blotter header shifts rows, so reordering these together would corrupt the
  -- result. (Guarded by a core_commands test that drives an insert-based recovery here.)
  for _, edit in ipairs(result.edits or {}) do
    vim.api.nvim_buf_set_lines(0, edit.start_index, edit.end_index, false, edit.lines)
  end

  if result.cursor then
    vim.api.nvim_win_set_cursor(0, result.cursor)
  end

  if result.startinsert then
    vim.cmd("startinsert!")
  end

  -- Keep buffer diagnostics current after any edit. This is the single choke
  -- point every edit path flows through. apply_refresh already publishes from its
  -- own analysis (and sets `refreshing` around its edit), so skip while it runs.
  if not refreshing then
    refresh_diagnostics()
  end

  -- Programmatic edits do not fire the change autocmds the ftplugin highlighter
  -- listens on, so refresh highlights from this single edit choke point too.
  if vim.bo.filetype == "blotter" then
    highlight_buffer(0)
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

-- Rebuild every blotter's existing summary to match its blots, and publish the
-- buffer diagnostics for any problems found. A no-op edit-wise when all summaries
-- are already current. `join` merges the edit into the previous undo block, used
-- by the autocmd-driven refreshes so one keystroke stays one undo step.
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

  warn("blotter: buffer changed during selection; aborting " .. op)
  return true
end

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
M.publish_diagnostics = publish_diagnostics
M.apply_result = apply_result
M.run_buffer_usecase = run_buffer_usecase
M.with_preserved_cursor = with_preserved_cursor
M.buffer_changed = buffer_changed
M.apply_refresh = apply_refresh

return M
