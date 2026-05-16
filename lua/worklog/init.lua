local filetype = require("worklog.filetype")
local append_copy = require("worklog.usecases.append_copy")
local append_quantized_summary = require("worklog.usecases.append_quantized_summary")
local append_summary = require("worklog.usecases.append_summary")
local insert_now = require("worklog.usecases.insert_now")
local order_worklogs = require("worklog.usecases.order_worklogs")
local repeat_current = require("worklog.usecases.repeat_current")

local M = {}

local function warn(message)
  vim.notify(message, vim.log.levels.WARN)
end

---@return string[]
local function buffer_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

---@return integer
local function cursor_row()
  return vim.api.nvim_win_get_cursor(0)[1]
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
function M.insert_now()
  local lines = buffer_lines()
  local row = cursor_row()
  local result, err = insert_now.run(lines, row, os.date("%H:%M"))
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

-- Append a summary and totals block based on the active worklog.
function M.append_summary()
  local lines = buffer_lines()
  local result, err = append_summary.run(lines)
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.append_quantized_summary()
  local lines = buffer_lines()
  local result, err = append_quantized_summary.run(lines)
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.append_copy()
  local lines = buffer_lines()
  local result, err = append_copy.run(lines)
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.repeat_current()
  local lines = buffer_lines()
  local row = cursor_row()
  local result, err = repeat_current.run(lines, row, os.date("%H:%M"))
  if not result then
    warn(err)
    return
  end

  apply_result(result)
end

function M.order_worklogs()
  local lines = buffer_lines()
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
