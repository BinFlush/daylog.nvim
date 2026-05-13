local blocks = require("worklog.blocks")
local context = require("worklog.context")
local filetype = require("worklog.filetype")
local order = require("worklog.order")
local parse = require("worklog.parse")
local intervals = require("worklog.intervals")
local summary = require("worklog.summary")
local render = require("worklog.render")

local M = {}

local function warn(message)
  vim.notify(message, vim.log.levels.WARN)
end

local function warn_invalid_entry(error)
  warn(string.format("worklog: invalid worklog entry at line %d: %s", error.row, error.message))
end

local function parse_block_body(lines, block, default_label)
  return order.parse_items(blocks.get_body_lines(lines, block), block.body_start_row, function(line)
    return parse.parse_time_line(line, default_label)
  end)
end

local function validate_worklog_context(ctx)
  local parsed_body = parse_block_body(ctx.lines, ctx.block, ctx.default_label)

  if parsed_body.error then
    warn_invalid_entry(parsed_body.error)
    return nil
  end

  local first_row, second_row = order.find_unordered_rows(parsed_body.items)
  if first_row then
    warn(string.format(
      "worklog: unordered timestamps near lines %d and %d; fix manually or run :WorklogOrder",
      first_row,
      second_row
    ))
    return nil
  end

  return parsed_body
end

-- Commands either operate on the active worklog (copy/summarize) or on the
-- worklog containing the cursor (insert/repeat). Keep those lookups here so
-- the command bodies read as straightforward orchestration.
local function get_active_worklog_context()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local ctx, err = context.get_active_worklog_context(lines)

  if not ctx then
    warn(err)
    return nil
  end

  return ctx
end

local function get_worklog_context_at_cursor()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local ctx, err = context.get_worklog_context_at_row(lines, row)

  if not ctx then
    warn(err)
    return nil
  end

  return ctx
end

local function get_validated_active_worklog()
  local ctx = get_active_worklog_context()
  if not ctx then
    return nil
  end

  local parsed_body = validate_worklog_context(ctx)
  if not parsed_body then
    return nil
  end

  return ctx, parsed_body
end

local function get_validated_cursor_worklog()
  local ctx = get_worklog_context_at_cursor()
  if not ctx then
    return nil
  end

  local parsed_body = validate_worklog_context(ctx)
  if not parsed_body then
    return nil
  end

  return ctx, parsed_body
end

local function get_ordered_insert_index(ctx, parsed_body, minutes)
  return order.get_insert_row(parsed_body.items, minutes, blocks.get_insert_index(ctx.block))
end

local function insert_into_worklog(ctx, parsed_body, line, minutes)
  local insert_at = get_ordered_insert_index(ctx, parsed_body, minutes)
  if not insert_at then
    return nil
  end

  vim.api.nvim_buf_set_lines(0, insert_at, insert_at, false, { line })

  return insert_at
end

local function entries_from_parsed_body(parsed_body)
  local entries = {}

  for _, item in ipairs(parsed_body.items) do
    table.insert(entries, {
      minutes = item.minutes,
      text = item.text,
      label = item.label,
      excluded = item.excluded,
    })
  end

  return entries
end

local function intervals_from_parsed_body(parsed_body)
  return intervals.build(entries_from_parsed_body(parsed_body))
end

local function append_lines(lines)
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_buf_set_lines(0, last, last, false, lines)
end

local function append_summary_kind(kind, summarize_fn)
  local ctx, parsed_body = get_validated_active_worklog()
  if not ctx then
    return
  end

  local result = summarize_fn(intervals_from_parsed_body(parsed_body), ctx.default_label)
  append_lines(render.summary_lines(result, kind))
end

-- Insert the current time at the cursor and enter insert mode.
-- This is intentionally dumb and supports manual editing/refinement.
function M.insert_now()
  local ctx, parsed_body = get_validated_cursor_worklog()
  if not ctx then
    return
  end

  local time = os.date("%H:%M")
  local entry = parse.parse_time_line(time)
  local row = insert_into_worklog(ctx, parsed_body, time .. " ", entry.minutes)

  if not row then
    return
  end

  vim.api.nvim_win_set_cursor(0, { row + 1, #time + 1 })
  vim.cmd("startinsert!")
end

-- Append a summary and totals block based on the active worklog.
function M.append_summary()
  append_summary_kind("exact", summary.summarize)
end

function M.append_quantized_summary()
  append_summary_kind("quantized", summary.quantized_summarize)
end

function M.append_copy()
  local ctx, parsed = get_validated_active_worklog()
  if not ctx then
    return
  end

  local rendered = render.worklog_lines(order.normalized_lines(parsed, ctx.default_label, parse.format_time_line))
  append_lines(rendered)
end

function M.repeat_current()
  local ctx, parsed_body = get_validated_cursor_worklog()
  if not ctx then
    return
  end

  local entry = parse.parse_time_line(vim.api.nvim_get_current_line(), ctx.default_label)
  if not entry or entry == false then
    warn("worklog: current line is not a valid worklog entry")
    return
  end

  local minutes = parse.parse_time_line(os.date("%H:%M")).minutes
  local line = parse.format_time_line({
    minutes = minutes,
    text = entry.text,
    label = entry.label,
    excluded = entry.excluded,
  }, ctx.default_label)
  local insert_at = insert_into_worklog(ctx, parsed_body, line, minutes)
  if not insert_at then
    return
  end
end

function M.order_worklogs()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local parsed = blocks.parse(lines)

  if parsed.error then
    warn(parsed.error)
    return
  end

  if #parsed == 0 then
    warn("worklog: no worklog block found; first line must be --- worklog --- or --- worklog default=#label ---")
    return
  end

  for i = #parsed, 1, -1 do
    local block = parsed[i]

    if blocks.is_worklog(block) then
      local parsed_body = parse_block_body(lines, block, parsed.default_label)

      if parsed_body.error then
        warn_invalid_entry(parsed_body.error)
        return
      end

      local sorted_items = order.sorted_items(parsed_body)

      local sorted_lines = order.normalized_lines({
        preamble_lines = parsed_body.preamble_lines,
        items = sorted_items,
      }, parsed.default_label, parse.format_time_line)
      vim.api.nvim_buf_set_lines(0, block.body_start_row - 1, block.end_row - 1, false, sorted_lines)
    end
  end
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
