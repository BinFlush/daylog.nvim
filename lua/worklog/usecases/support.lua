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

-- Build the edit that inserts `inserted_line` (whose effective tag/location are
-- `ins_tag`/`ins_loc`) at `minutes` in `block`. When the inserted entry changes
-- the sticky tag/location the following entry was silently inheriting, the
-- follower is rewritten with a compensating token (#tag/@location or #-/@-) so
-- its effective metadata is preserved. Pinning the immediate follower suffices,
-- since later entries inherit from it.
function M.insert_entry_edit(block, minutes, inserted_line, ins_tag, ins_loc)
  local insert_index = body.insert_index(block, minutes)
  local pred = body.state_before(block, minutes)

  local follower
  for _, item in ipairs(block.entry_items) do
    if item.minutes > minutes then
      follower = item
      break
    end
  end

  local lines = { inserted_line }
  local end_index = insert_index

  if follower then
    local needs_tag = not follower.explicit_tag
      and not follower.explicit_tag_clear
      and ins_tag ~= pred.tag
    local needs_location = not follower.explicit_location
      and not follower.explicit_location_clear
      and ins_loc ~= pred.location

    if needs_tag or needs_location then
      lines = {
        inserted_line,
        entry.format({
          minutes = follower.minutes,
          text = follower.text,
          tag = follower.tag,
          location = follower.location,
          logged = follower.logged,
        }, ins_tag, ins_loc),
      }
      end_index = insert_index + 1
    end
  end

  return {
    edits = {
      {
        start_index = insert_index,
        end_index = end_index,
        lines = lines,
      },
    },
  }
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
