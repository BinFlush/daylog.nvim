local tests_run = 0
local failures = {}

vim.o.hidden = true

local original_notify = vim.notify
local original_err_writeln = vim.api.nvim_err_writeln

local function should_suppress_message(message)
  return type(message) == "string" and message:match("^worklog:")
end

local function restore_output()
  vim.notify = original_notify
  vim.api.nvim_err_writeln = original_err_writeln
end

vim.notify = function(message, level, opts)
  if should_suppress_message(message) then
    return
  end

  return original_notify(message, level, opts)
end

vim.api.nvim_err_writeln = function(message)
  if should_suppress_message(message) then
    return
  end

  return original_err_writeln(message)
end

local function format_value(value)
  return vim.inspect(value)
end

local t = {}

function t.eq(actual, expected)
  if not vim.deep_equal(actual, expected) then
    error(string.format("expected %s, got %s", format_value(expected), format_value(actual)), 2)
  end
end

function t.ok(value, message)
  if not value then
    error(message or "expected truthy value", 2)
  end
end

function t.reset(lines)
  vim.cmd("enew!")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines or {})

  local row = 1
  if lines and #lines == 0 then
    row = 1
  end

  vim.api.nvim_win_set_cursor(0, { row, 0 })
end

function t.set_lines(lines)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

function t.get_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

function t.set_cursor(row, col)
  vim.api.nvim_win_set_cursor(0, { row, col or 0 })
end

function t.test(name, fn)
  tests_run = tests_run + 1
  local ok, err = xpcall(fn, debug.traceback)

  if not ok then
    table.insert(failures, string.format("%s\n%s", name, err))
  end
end

local root = vim.fn.getcwd()

dofile(root .. "/tests/entry.lua")(t)
dofile(root .. "/tests/document.lua")(t)
dofile(root .. "/tests/analyze.lua")(t)
dofile(root .. "/tests/summary.lua")(t)
dofile(root .. "/tests/summary_block.lua")(t)
dofile(root .. "/tests/render.lua")(t)
dofile(root .. "/tests/config.lua")(t)
dofile(root .. "/tests/journal.lua")(t)
dofile(root .. "/tests/week.lua")(t)
dofile(root .. "/tests/usecases.lua")(t)
dofile(root .. "/tests/refresh_summaries.lua")(t)
dofile(root .. "/tests/context.lua")(t)
dofile(root .. "/tests/body.lua")(t)
dofile(root .. "/tests/filetype.lua")(t)
dofile(root .. "/tests/highlight.lua")(t)
dofile(root .. "/tests/core_commands.lua")(t)
dofile(root .. "/tests/journal_commands.lua")(t)
dofile(root .. "/tests/health.lua")(t)
dofile(root .. "/tests/compat.lua")(t)
dofile(root .. "/tests/invariants.lua")(t)

restore_output()

if #failures > 0 then
  error(
    string.format(
      "%d/%d tests failed\n\n%s\n",
      #failures,
      tests_run,
      table.concat(failures, "\n\n")
    )
  )
end

print(string.format("ok: %d tests\n", tests_run))
