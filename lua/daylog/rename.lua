local buffer = require("daylog.buffer")
local config = require("daylog.config")
local pick = require("daylog.pick")
local daybook_io = require("daylog.daybook_io")
local render = require("daylog.render")
local report_buffers = require("daylog.report")
local rename_summary = require("daylog.usecases.rename_summary")
local report_cursor = require("daylog.usecases.report_cursor")
local sources_registry = require("daylog.sources.registry")
local sources_sync = require("daylog.sources.sync")

local M = {}

-- Rename operation (shell).
--
-- Renames what a summary row stands for, in two forms that share the same prompt
-- vocabulary: in the active log (the cursor's row -> rewrite source + rebuild),
-- and from a multi-day report (fan the rename out across the period's day files).
-- The pure rename math lives in usecases/rename_summary; this is the picker /
-- confirmation / multi-file-write shell around it.

local warn = buffer.warn
local buffer_lines = buffer.buffer_lines
local cursor_row = buffer.cursor_row
local apply_result = buffer.apply_result
local buffer_changed = buffer.buffer_changed
local highlight_buffer = buffer.highlight_buffer
local daybook_lines = daybook_io.daybook_lines
local loaded_buffer_for_path = daybook_io.loaded_buffer_for_path
local build_report_for_spec = report_buffers.build_report_for_spec
local refresh_report_windows = report_buffers.refresh_report_windows

local RENAME_PROMPT_LABEL = { item = "activity", tag = "tag", location = "location" }

-- Renaming from a multi-day report is wired below, after the report infrastructure
-- it depends on (build_report_for_spec, refresh_report_windows). Forward-declared so
-- M.summary can dispatch to it.
local rename_from_report

-- Rename what the summary row under the cursor stands for: an activity (main
-- row), a #tag (tag total), or an @location (location total). The rename
-- propagates into the attached log and rebuilds the summary. Renaming to a
-- value that already exists merges the two -- so the picker offers the other
-- same-kind values as merge targets while still letting you type a fresh name. An
-- empty or unchanged value is a no-op.
-- `source_name`, when given, replaces an activity with a work item from that
-- source: the picker also lists (and live-searches) the source's items, and a
-- chosen item renames the activity to its `to_entry_text` (sanitized), exactly like
-- :DaylogInsert. A source only applies to an activity row, and with one source
-- configured it is offered automatically.
function M.summary(new_value, source_name)
  -- On a multi-day report buffer the cursor selects an aggregate (whole-period) or
  -- per-day row; the rename fans out across the relevant day files instead of the
  -- current buffer.
  local is_report, report_spec = pcall(vim.api.nvim_buf_get_var, 0, "log_report")
  if is_report and type(report_spec) == "table" then
    rename_from_report(report_spec, new_value, source_name)
    return
  end

  local row = cursor_row()
  local target, err = rename_summary.resolve(buffer_lines(), row)
  if not target then
    warn(err)
    return
  end

  -- The picker is async, so the buffer/cursor could move under it. Pin the buffer
  -- and the resolved row, and apply against the pinned row, refusing if the buffer
  -- changed -- exactly like the source picker.
  local target_buf = vim.api.nvim_get_current_buf()
  local function apply_rename(value)
    if value == nil or value == "" or value == target.current then
      return
    end
    if buffer_changed(target_buf, "rename") then
      return
    end

    local result, run_err = rename_summary.run(buffer_lines(), row, value)
    if not result then
      warn(run_err)
      return
    end
    apply_result(result)
  end

  if new_value ~= nil then
    apply_rename(new_value)
    return
  end

  local label = RENAME_PROMPT_LABEL[target.kind]

  local function prompt_for_name()
    apply_rename(vim.fn.input({
      prompt = string.format("daylog: rename %s: ", label),
      default = target.current,
    }))
  end

  -- A named source replaces an activity with one of its work items, scoped to that source and
  -- live-searchable (`search = true`) -- exactly like :DaylogInsert <source>. It only applies to
  -- an activity row; on a tag/location it is reported, then the normal merge picker opens.
  if source_name then
    local source = sources_registry.get(source_name)
    if not source then
      warn("daylog: unknown source '" .. source_name .. "'")
      return
    end
    if target.kind == "item" then
      pick.source(source, source_name, {
        prompt = string.format("Daylog: rename activity -> %s", source_name),
        prompt_fallback = "Daylog: pick " .. source_name .. " item",
        on_pick = function(item)
          apply_rename(source.to_entry_text(item))
        end,
        on_cancel = nil,
      })
      return
    end
    warn("daylog: a source can only replace an activity, not a " .. target.kind)
  end

  -- Pick the new value, then rename into it (renaming to a value that already exists merges the
  -- two). type-a-fresh-name and the empty-pool fallback both go through the plain input prompt;
  -- the current value is excluded so "X -> X" is never offered.
  local choose_opts = {
    on_choose = apply_rename,
    on_create = apply_rename,
    on_type_new = prompt_for_name,
    on_empty = prompt_for_name,
    exclude = target.current,
    prompt = string.format("Daylog: rename/merge %s  (<CR> pick, <C-e> new name)", label),
    prompt_fallback = string.format("Daylog: rename/merge %s", label),
    type_new_label = "✎ Type a new name…",
  }

  -- An activity renames into the same unified pool as :DaylogInsert! -- recent logged activities
  -- across days plus every source's items, ranked and deduped. A tag/location has no pool, so it
  -- offers the other same-kind totals (the in-summary merge targets).
  if target.kind == "item" then
    pick.unified(sources_sync.read_specs(), choose_opts)
    return
  end

  local rows = {}
  for _, candidate in ipairs(target.candidates) do
    rows[#rows + 1] = { display = candidate, text = candidate }
  end
  pick.choose(rows, choose_opts)
end

-- Apply an edit script (0-based, sorted highest-start-first by the usecase) to a
-- plain line list, returning the new list. Used to compute a day file's rewritten
-- content off-buffer for the multi-day rename.
local function lines_with_edits(lines, edits)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line
  end

  for _, edit in ipairs(edits) do
    local next_out = {}
    for i = 1, edit.start_index do
      next_out[#next_out + 1] = out[i]
    end
    for _, line in ipairs(edit.lines) do
      next_out[#next_out + 1] = line
    end
    for i = edit.end_index + 1, #out do
      next_out[#next_out + 1] = out[i]
    end
    out = next_out
  end

  return out
end

-- The day files a resolved report row acts on: one path for a per-day row, every
-- day of the period for an aggregate row.
local function report_target_paths(report, resolved)
  if resolved.scope == "day" then
    return { resolved.path }
  end

  local paths = {}
  for _, day in ipairs(report.days) do
    paths[#paths + 1] = day.path
  end
  return paths
end

-- The other same-kind values in the aggregate summary, as merge targets for the
-- report rename picker (mirrors rename_summary's in-file merge candidates).
local function report_merge_candidates(report, target)
  local aggregate = report.summary
  local seen, candidates = {}, {}

  local function add(value)
    if value ~= nil and value ~= target.current and not seen[value] then
      seen[value] = true
      candidates[#candidates + 1] = value
    end
  end

  if target.kind == "tag" then
    for _, item in ipairs(aggregate.tag_totals or {}) do
      add(item.tag)
    end
  elseif target.kind == "location" then
    for _, item in ipairs(aggregate.location_totals or {}) do
      add(item.location)
    end
  else
    for _, item in ipairs(aggregate.summary_items or {}) do
      if item.tag == target.tag then
        add(item.text)
      end
    end
  end

  return candidates
end

-- Write a day file's new content: into its open buffer when one exists (so the user
-- saves it, and the report -- which reads buffers first -- reflects it at once),
-- otherwise straight to disk. The summary was already rebuilt into `new_lines`.
local function write_daybook_change(path, new_lines)
  local buf = loaded_buffer_for_path(path)
  if buf then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    if vim.bo[buf].filetype == "daylog" then
      highlight_buffer(buf)
    end
    return
  end

  vim.fn.writefile(new_lines, path)
end

local function confirm_report_rename(target, value, changes)
  local names = {}
  for _, change in ipairs(changes) do
    names[#names + 1] = "  " .. vim.fn.fnamemodify(change.path, ":t")
  end

  local prompt = string.format(
    "daylog: rename %s '%s' to '%s' in %d file(s)?\n%s",
    RENAME_PROMPT_LABEL[target.kind],
    target.current,
    value,
    #changes,
    table.concat(names, "\n")
  )

  return vim.fn.confirm(prompt, "&Yes\n&No", 1) == 1
end

-- Prompt for the new value across the report: a vim.ui.select over the merge
-- candidates (plus a type-a-new-name option), or a plain input when there are none.
local function prompt_report_rename(target, candidates, apply)
  local label = RENAME_PROMPT_LABEL[target.kind]

  local function prompt_for_name()
    apply(vim.fn.input({
      prompt = string.format("daylog: rename %s: ", label),
      default = target.current,
    }))
  end

  if #candidates == 0 then
    prompt_for_name()
    return
  end

  local TYPE_NEW = {}
  local choices = {}
  for _, value in ipairs(candidates) do
    choices[#choices + 1] = value
  end
  choices[#choices + 1] = TYPE_NEW

  vim.ui.select(choices, {
    prompt = string.format("Daylog: rename/merge %s across the report", label),
    format_item = function(choice)
      if choice == TYPE_NEW then
        return "✎ Type a new name…"
      end
      return choice
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice == TYPE_NEW then
      prompt_for_name()
      return
    end
    apply(choice)
  end)
end

-- Rename an item from a multi-day report, fanning the rename out (by value) across
-- the day files the resolved row covers, writing each affected file after a
-- confirmation, then rebuilding the open reports. A source rename is not offered
-- here -- a report acts on many days at once.
rename_from_report = function(spec, new_value, source_name)
  if source_name then
    warn("daylog: a source rename is not available from a report")
    return
  end

  local report, err = build_report_for_spec(spec)
  if not report then
    warn(err)
    return
  end

  local duration_format = config.get().defaults.duration_format
  local layout =
    render.days_report_layout(report, duration_format, { aggregate_only = spec.aggregate_only })

  local resolved, resolve_err = report_cursor.resolve(layout, cursor_row())
  if not resolved then
    warn(resolve_err)
    return
  end

  local target = resolved.target
  local paths = report_target_paths(report, resolved)
  local target_buf = vim.api.nvim_get_current_buf()

  local function apply(value)
    if value == nil or value == "" or value == target.current then
      return
    end
    if buffer_changed(target_buf, "rename") then
      return
    end

    -- Compute every file's rewrite up front; a day that lacks the item is skipped,
    -- and a (defensive) failure aborts before anything is written.
    local changes = {}
    for _, path in ipairs(paths) do
      local lines = daybook_lines(path)
      if lines then
        local result, run_err = rename_summary.run_by_value(lines, target, value)
        if result then
          changes[#changes + 1] = { path = path, lines = lines_with_edits(lines, result.edits) }
        elseif run_err then
          warn(run_err)
          return
        end
      end
    end

    if #changes == 0 then
      warn("daylog: no day in this report has that " .. RENAME_PROMPT_LABEL[target.kind])
      return
    end

    if not confirm_report_rename(target, value, changes) then
      return
    end

    for _, change in ipairs(changes) do
      write_daybook_change(change.path, change.lines)
    end

    refresh_report_windows()
  end

  if new_value ~= nil then
    apply(new_value)
    return
  end

  prompt_report_rename(target, report_merge_candidates(report, target), apply)
end

return M
