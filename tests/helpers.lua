local journal = require("worklog.journal")
local worklog = require("worklog")

local M = {}

function M.with_mocked_date(value, fn)
  local old_date = os.date

  rawset(os, "date", function()
    return value
  end)

  local ok, err = xpcall(fn, debug.traceback)
  rawset(os, "date", old_date)

  if not ok then
    error(err, 0)
  end
end

function M.with_mocked_time(value, fn)
  local old_time = os.time

  rawset(os, "time", function(argument)
    if argument ~= nil then
      return old_time(argument)
    end

    return value
  end)

  local ok, err = xpcall(fn, debug.traceback)
  rawset(os, "time", old_time)

  if not ok then
    error(err, 0)
  end
end

function M.with_mocked_confirm(choice, fn)
  local old_confirm = vim.fn.confirm

  vim.fn.confirm = function()
    return choice
  end

  local ok, err = xpcall(fn, debug.traceback)
  vim.fn.confirm = old_confirm

  if not ok then
    error(err, 0)
  end
end

function M.with_worklog_setup(options, fn)
  worklog.setup(options)

  local ok, err = xpcall(fn, debug.traceback)
  worklog.setup()

  if not ok then
    error(err, 0)
  end
end

function M.with_mocked_input(value, fn)
  local old_input = vim.fn.input

  vim.fn.input = function()
    return value
  end

  local ok, err = xpcall(fn, debug.traceback)
  vim.fn.input = old_input

  if not ok then
    error(err, 0)
  end
end

function M.with_captured_notify(fn)
  local old_notify = vim.notify
  local messages = {}

  vim.notify = function(message, level)
    table.insert(messages, {
      message = message,
      level = level,
    })
  end

  local ok, err = xpcall(function()
    fn(messages)
  end, debug.traceback)

  vim.notify = old_notify

  if not ok then
    error(err, 0)
  end
end

function M.write_journal_file(root, directory, now, lines)
  local path = journal.path_for_date({
    root = root,
    directory = directory,
  }, now)

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
  return path
end

function M.with_temp_home_root(fn)
  local relative_root = "~/" .. vim.fn.fnamemodify(vim.fn.tempname(), ":t")
  local expanded_root = vim.fn.expand(relative_root)

  vim.fn.delete(expanded_root, "rf")

  local ok, err = xpcall(function()
    fn(relative_root, expanded_root)
  end, debug.traceback)

  vim.fn.delete(expanded_root, "rf")

  if not ok then
    error(err, 0)
  end
end

function M.setup_worklog()
  worklog.setup()
end

return M
