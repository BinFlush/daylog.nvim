local analyze = require("worklog.analyze")
local body = require("worklog.body")
local context = require("worklog.context")
local diagnostics = require("worklog.diagnostics")
local entry = require("worklog.entry")

local M = {}

-- Shared use-case helpers.
--
-- The use-case layer works from fully analyzed worklog context and returns edit
-- scripts plus cursor actions. These helpers centralize context lookup,
-- validation, and edit-building so individual command modules can stay small
-- and focused on one operation each.

function M.validate_context(ctx)
  local diagnostic = analyze.find_block_diagnostic(ctx.analysis, ctx.block)

  if diagnostic then
    return nil, diagnostics.message(diagnostic)
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

return M
