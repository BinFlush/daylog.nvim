-- Current-time insert verbs: bare stamp, one source's picker, or the unified picker (shell).

local buffer = require("daylog.buffer")
local current_time = require("daylog.current_time")
local daybook_io = require("daylog.daybook_io")
local pick = require("daylog.pick")
local sources_registry = require("daylog.sources.registry")
local sources_sync = require("daylog.sources.sync")
local support = require("daylog.usecases.support")

local M = {}

-- Bring a work item from a configured source into the current log at the
-- current time. Offline-first: reads the source's local cache and opens
-- vim.ui.select (Telescope/fzf/snacks take over if installed). On pick the
-- configured "{id} {title}" template is inserted; cancelling falls back to a bare
-- timestamp, exactly like :Daylog insert with no argument.
function M.insert_from_source(name)
  if current_time.guard_current_time("insert") then
    return
  end

  local source = sources_registry.get(name)
  if not source then
    buffer.warn("daylog: unknown source '" .. name .. "'")
    return
  end

  -- Refuse a cursor outside a log now, before opening the async picker
  -- (cache read, optional network, a UI round trip), exactly as :Daylog insert
  -- with no argument refuses up front. insert_entry re-validates at apply time
  -- too, since the buffer can change under the picker -- this is the fail-fast.
  local cursor_ctx, cursor_err =
    support.get_validated_at_row(buffer.buffer_lines(), buffer.cursor_row())
  if not cursor_ctx then
    buffer.warn(cursor_err)
    return
  end

  -- The picker is async, so capture the moment and the target buffer up front: a
  -- late selection then stamps the time the command was issued and never edits a
  -- buffer we have since moved away from.
  local time = os.date("%H:%M")
  local auto_offset = daybook_io.live_offset()
  local target_buf = vim.api.nvim_get_current_buf()

  -- Apply a chosen item into the originating buffer, guarding against the buffer
  -- changing under the async picker.
  local function insert_choice(item)
    if buffer.buffer_changed(target_buf, "insert") then
      return
    end

    current_time.apply_insert_entry(time, source.to_entry_text(item), auto_offset)
  end

  -- The scoped source picker: type-as-you-search across the whole tracker when the source
  -- supports it (cached items show at an empty prompt), else the offline cache. Cancelling
  -- leaves a bare timestamp, like a plain :Daylog insert.
  pick.source(source, name, {
    prompt = "Daylog: " .. name,
    prompt_fallback = "Daylog: pick " .. name .. " item",
    on_pick = insert_choice,
    on_cancel = function()
      current_time.apply_insert_time(time, auto_offset)
    end,
  })
end

-- The unified "what to log" picker (`:Daylog! insert`): pool every configured source's cached
-- items plus your recent logged activities into one ranked, deduped, offline fuzzy list. Picking
-- a row inserts it at the current time; cancelling leaves a bare timestamp, like :Daylog insert.
function M.insert_unified()
  if current_time.guard_current_time("insert") then
    return
  end

  -- Refuse a cursor outside a log up front, before the async picker, exactly like the other
  -- insert paths. insert_entry re-validates at apply time too.
  local cursor_ctx, cursor_err =
    support.get_validated_at_row(buffer.buffer_lines(), buffer.cursor_row())
  if not cursor_ctx then
    buffer.warn(cursor_err)
    return
  end

  local time = os.date("%H:%M")
  local auto_offset = daybook_io.live_offset()
  local target_buf = vim.api.nvim_get_current_buf()

  -- Insert the chosen/typed activity, or a bare timestamp for an empty value -- guarded against
  -- the buffer moving under the async picker.
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

  -- read_specs reads each source's cache synchronously (offline, instant) and refreshes stale
  -- ones in the background; an empty pool (no sources, empty daybook) leaves a bare timestamp.
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

-- Stamp the current time as a new entry. opts.pick opens the unified recent+sources picker;
-- opts.source picks from that one tracker; otherwise a bare current-time entry.
function M.insert(opts)
  opts = opts or {}
  if opts.pick then
    return M.insert_unified()
  end
  if opts.source and opts.source ~= "" then
    return M.insert_from_source(opts.source)
  end
  return M.insert_now()
end

return M
