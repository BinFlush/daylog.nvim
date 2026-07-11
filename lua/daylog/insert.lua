-- Current-time insert verbs: bare stamp, one source's picker, or the unified picker (shell).

local buffer = require("daylog.buffer")
local current_time = require("daylog.current_time")
local daybook_io = require("daylog.daybook_io")
local pick = require("daylog.pick")
local sources_registry = require("daylog.sources.registry")
local sources_sync = require("daylog.sources.sync")
local support = require("daylog.usecases.support")

local M = {}

-- Shared preamble for the picker inserts: fail fast if the cursor is outside a log, then snapshot the
-- moment and target buffer up front, so an async picker's late selection stamps the issue time and never
-- edits a buffer we moved away from. Returns time, auto_offset, target_buf; nil after warning.
local function prepare_insert()
  local cursor_ctx, cursor_err =
    support.get_validated_at_row(buffer.buffer_lines(), buffer.cursor_row())
  if not cursor_ctx then
    buffer.warn(cursor_err)
    return nil
  end
  return os.date("%H:%M"), daybook_io.live_offset(), vim.api.nvim_get_current_buf()
end

-- Bring a source work item into the current log at the current time; offline-first
-- (reads the cache, opens the picker), cancelling leaves a bare timestamp.
function M.insert_from_source(name)
  if current_time.guard_current_time("insert") then
    return
  end

  local source = sources_registry.get(name)
  if not source then
    buffer.warn("daylog: unknown source '" .. name .. "'")
    return
  end

  local time, auto_offset, target_buf = prepare_insert()
  if not time then
    return
  end

  -- Apply a chosen item into the originating buffer, guarding against a buffer change under the picker.
  local function insert_choice(item)
    if buffer.buffer_changed(target_buf, "insert") then
      return
    end

    current_time.apply_insert_entry(time, source.to_entry_text(item), auto_offset)
  end

  -- The scoped source picker: live search across the tracker when supported, else the
  -- offline cache; cancelling leaves a bare timestamp.
  pick.source(source, name, {
    prompt = "Daylog: " .. name,
    prompt_fallback = "Daylog: pick " .. name .. " item",
    on_pick = insert_choice,
    on_cancel = function()
      current_time.apply_insert_time(time, auto_offset)
    end,
  })
end

-- The unified "what to log" picker (`:Daylog! insert`): pool every source's cached items plus
-- recent activities into one ranked, deduped, offline list; cancelling leaves a bare timestamp.
function M.insert_unified()
  if current_time.guard_current_time("insert") then
    return
  end

  local time, auto_offset, target_buf = prepare_insert()
  if not time then
    return
  end

  -- Insert the chosen/typed activity, or a bare timestamp when empty, guarded against a buffer change under the picker.
  local function insert(text)
    if buffer.buffer_changed(target_buf, "insert") then
      return
    end
    if text == nil or text == "" then
      current_time.apply_insert_time(time, auto_offset)
    else
      current_time.apply_insert_entry(time, text, auto_offset)
    end
  end

  -- read_specs reads each source's cache synchronously and refreshes stale ones in the
  -- background; an empty pool leaves a bare timestamp.
  pick.unified(sources_sync.read_specs(), {
    prompt = "Daylog: insert",
    prompt_fallback = "Daylog: insert",
    type_new_label = "✎ Type a new activity…",
    on_choose = insert,
    on_create = insert,
    on_type_new = function()
      insert(vim.fn.input({ prompt = "daylog: log: " }))
    end,
    on_cancel = function()
      current_time.apply_insert_time(time, auto_offset)
    end,
  })
end

-- Insert the current time at the cursor and enter insert mode.
function M.insert_now()
  if current_time.guard_current_time("insert") then
    return
  end

  current_time.apply_insert_time(os.date("%H:%M"), daybook_io.live_offset())
end

-- Stamp the current time as a new entry. A named opts.source picks from that one tracker (it takes
-- precedence over opts.pick, so `:Daylog! insert <source>` opens that source rather than dropping it);
-- opts.pick alone opens the unified recent+sources picker; otherwise a bare current-time entry.
function M.insert(opts)
  opts = opts or {}
  if opts.source and opts.source ~= "" then
    return M.insert_from_source(opts.source)
  end
  if opts.pick then
    return M.insert_unified()
  end
  return M.insert_now()
end

return M
