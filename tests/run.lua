local tests_run = 0
local failures = {}

vim.o.hidden = true

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

dofile(root .. "/tests/parse.lua")(t)
dofile(root .. "/tests/document.lua")(t)
dofile(root .. "/tests/blocks.lua")(t)
dofile(root .. "/tests/order.lua")(t)
dofile(root .. "/tests/filetype.lua")(t)
dofile(root .. "/tests/commands.lua")(t)

if #failures > 0 then
  error(string.format("%d/%d tests failed\n\n%s", #failures, tests_run, table.concat(failures, "\n\n")))
end

print(string.format("ok: %d tests", tests_run))
