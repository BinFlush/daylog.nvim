local filetype = require("worklog.filetype")
local append_copy = require("worklog.usecases.append_copy")
local append_quantized_summary = require("worklog.usecases.append_quantized_summary")
local append_summary = require("worklog.usecases.append_summary")
local insert_now = require("worklog.usecases.insert_now")
local order_worklogs = require("worklog.usecases.order_worklogs")
local repeat_current = require("worklog.usecases.repeat_current")

local M = {}

-- Keep the Neovim shell deliberately thin: each command gathers editor input,
-- runs a pure use-case module, then applies the returned edit script.
local function warn(message)
  vim.notify(message, vim.log.levels.WARN)
end

local function apply_result(result)
  for _, edit in ipairs(result.edits or {}) do
    vim.api.nvim_buf_set_lines(0, edit.start_index, edit.end_index, false, edit.lines)
  end

  if result.cursor then
    vim.api.nvim_win_set_cursor(0, result.cursor)
  end

  if result.startinsert then
    vim.cmd("startinsert!")
  end
end

-- Insert the current time at the cursor and enter insert mode.
-- This is intentionally dumb and supports manual editing/refinement.
function M.insert_now()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local result, err = insert_now.run(lines, row, os.date("%H:%M"))
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

-- Append a summary and totals block based on the active worklog.
function M.append_summary()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local result, err = append_summary.run(lines)
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.append_quantized_summary()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local result, err = append_quantized_summary.run(lines)
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.append_copy()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local result, err = append_copy.run(lines)
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.repeat_current()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local current_line = vim.api.nvim_get_current_line()
  local result, err = repeat_current.run(lines, row, current_line, os.date("%H:%M"))
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.order_worklogs()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local result, err = order_worklogs.run(lines)
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.setup()
  filetype.register()

  vim.api.nvim_create_user_command("WorklogInsert", function()
    M.insert_now()
  end, {})

  vim.api.nvim_create_user_command("WorklogRepeat", function()
    M.repeat_current()
  end, {})

  vim.api.nvim_create_user_command("WorklogOrder", function()
    M.order_worklogs()
  end, {})

  vim.api.nvim_create_user_command("WorklogCopy", function()
    M.append_copy()
  end, {})

  vim.api.nvim_create_user_command("WorklogSummarize", function()
    M.append_summary()
  end, {})

  vim.api.nvim_create_user_command("WorklogQuantSum", function()
    M.append_quantized_summary()
  end, {})
end

return M
