local analyze = require("worklog.analyze")
local body = require("worklog.body")
local context = require("worklog.context")
local entry = require("worklog.entry")

local M = {}

local NO_WORKLOG_ERROR = "worklog: no worklog block found; first line must be a "
  .. "worklog header such as --- worklog --- or "
  .. "--- worklog #ClientA @office quantize=30 ---"

-- Shared use-case helpers.
--
-- The use-case layer works from fully analyzed worklog context and returns edit
-- scripts plus cursor actions. These helpers centralize context lookup,
-- validation, and error formatting so individual command modules can stay small
-- and focused on one operation each.

local function invalid_entry_error(diagnostic)
  return string.format(
    "worklog: invalid worklog entry at line %d: %s",
    diagnostic.row,
    diagnostic.message
  )
end

local function unordered_error(diagnostic)
  return string.format(
    "worklog: unordered timestamps near lines %d and %d; fix manually or run :WorklogOrder",
    diagnostic.row,
    diagnostic.row2
  )
end

function M.validate_context(ctx)
  local diagnostic = analyze.find_block_diagnostic(ctx.analysis, ctx.block)

  if diagnostic and diagnostic.code == "invalid_entry" then
    return nil, invalid_entry_error(diagnostic)
  end

  if diagnostic and diagnostic.code == "unordered_timestamps" then
    return nil, unordered_error(diagnostic)
  end

  return ctx
end

function M.get_validated_active(lines)
  local ctx, err = context.get_active_worklog_context(lines)
  if not ctx then
    return nil, err
  end

  return M.validate_context(ctx)
end

function M.get_validated_at_row(lines, row)
  local ctx, err = context.get_worklog_context_at_row(lines, row)
  if not ctx then
    return nil, err
  end

  return M.validate_context(ctx)
end

function M.get_insert_index(block, minutes)
  return body.insert_index(block, minutes)
end

function M.get_insert_state(block, minutes)
  return body.state_before(block, minutes)
end

function M.parse_clock_minutes(time)
  local parsed, err = entry.parse(time)

  if not parsed then
    return nil, "worklog: invalid current time: " .. (err or tostring(time))
  end

  return parsed.minutes
end

function M.append_edit(lines, appended_lines)
  return {
    edits = {
      {
        start_index = #lines,
        end_index = #lines,
        lines = appended_lines,
      },
    },
  }
end

function M.structural_or_missing_worklog_error(analysis)
  local structural_error = analyze.structural_error(analysis)
  if structural_error then
    return structural_error
  end

  if #analysis.worklog_blocks == 0 then
    return NO_WORKLOG_ERROR
  end

  return nil
end

function M.invalid_entry_error(diagnostic)
  return invalid_entry_error(diagnostic)
end

function M.unordered_error(diagnostic)
  return unordered_error(diagnostic)
end

return M
