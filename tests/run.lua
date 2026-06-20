local tests_run = 0
local failures = {}

vim.o.hidden = true

-- Enable filetype detection and ftplugins so opening a `.blot` file sets
-- filetype=blotter, exactly as in a real session. The journal/report commands
-- rely on this (their auto-summary autocmds key off the blotter filetype) and the
-- ftplugin-driven highlighter attaches the same way; `-u NONE` otherwise leaves
-- detection off, which previously only worked by accident of test ordering.
vim.cmd("filetype plugin on")

local original_notify = vim.notify
local original_err_writeln = vim.api.nvim_err_writeln

local function should_suppress_message(message)
  return type(message) == "string" and message:match("^blotter:")
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
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
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

-- Expected-failure test (TDD "red"): passes iff `fn` raises. If `fn` unexpectedly
-- succeeds, the suite fails -- a reminder to flip t.xfail back to t.test once the
-- bug it pins down is fixed.
function t.xfail(name, fn)
  tests_run = tests_run + 1
  local ok = xpcall(fn, debug.traceback)

  if ok then
    table.insert(
      failures,
      string.format("%s\n  xfail unexpectedly PASSED -- flip t.xfail to t.test", name)
    )
  end
end

local root = vim.fn.getcwd()

dofile(root .. "/tests/blot.lua")(t)
dofile(root .. "/tests/document.lua")(t)
dofile(root .. "/tests/analyze.lua")(t)
dofile(root .. "/tests/summary.lua")(t)
dofile(root .. "/tests/quantize.lua")(t)
dofile(root .. "/tests/summary_block.lua")(t)
dofile(root .. "/tests/render.lua")(t)
dofile(root .. "/tests/config.lua")(t)
dofile(root .. "/tests/journal.lua")(t)
dofile(root .. "/tests/week.lua")(t)
dofile(root .. "/tests/usecases.lua")(t)
dofile(root .. "/tests/rename_summary.lua")(t)
dofile(root .. "/tests/report_cursor.lua")(t)
dofile(root .. "/tests/report_rename.lua")(t)
dofile(root .. "/tests/balance_summary.lua")(t)
dofile(root .. "/tests/refresh_summaries.lua")(t)
dofile(root .. "/tests/context.lua")(t)
dofile(root .. "/tests/body.lua")(t)
dofile(root .. "/tests/filetype.lua")(t)
dofile(root .. "/tests/highlight.lua")(t)
dofile(root .. "/tests/core_commands.lua")(t)
dofile(root .. "/tests/journal_commands.lua")(t)
dofile(root .. "/tests/health.lua")(t)
dofile(root .. "/tests/insert_blot.lua")(t)
dofile(root .. "/tests/sources_sanitize.lua")(t)
dofile(root .. "/tests/sources_cache.lua")(t)
dofile(root .. "/tests/sources_picker.lua")(t)
dofile(root .. "/tests/sources_http.lua")(t)
dofile(root .. "/tests/sources_azure_devops.lua")(t)
dofile(root .. "/tests/sources_registry.lua")(t)
dofile(root .. "/tests/sources_config.lua")(t)
dofile(root .. "/tests/sources_commands.lua")(t)
dofile(root .. "/tests/compat.lua")(t)
dofile(root .. "/tests/invariants.lua")(t)
dofile(root .. "/tests/summary_fuzz.lua")(t)
dofile(root .. "/tests/balance_invariants.lua")(t)
dofile(root .. "/tests/regen_invariants.lua")(t)

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
