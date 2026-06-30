local filetype = require("daylog.filetype")
local append_copy = require("daylog.usecases.append_copy")
local balance_summary = require("daylog.usecases.balance_summary")
local config = require("daylog.config")
local buffer = require("daylog.buffer")
local commands = require("daylog.commands")
local current_time = require("daylog.current_time")
local daybook = require("daylog.daybook")
local log_current = require("daylog.usecases.log_current")
local daybook_io = require("daylog.daybook_io")
local order_logs = require("daylog.usecases.order_logs")
local refresh_summaries = require("daylog.usecases.refresh_summaries")
local map = require("daylog.map")
local rename = require("daylog.rename")
local repeat_current = require("daylog.usecases.repeat_current")
local pick = require("daylog.pick")
local sources_http = require("daylog.sources.http")
local sources_registry = require("daylog.sources.registry")
local sources_sync = require("daylog.sources.sync")
local split_summary = require("daylog.usecases.split_summary")
local support = require("daylog.usecases.support")
local report_buffers = require("daylog.report")

local M = {}

-- Buffer-orchestration substrate, rebound as locals so call sites read unchanged.
local warn = buffer.warn
local buffer_lines = buffer.buffer_lines
local cursor_row = buffer.cursor_row
local publish_diagnostics = buffer.publish_diagnostics
local apply_result = buffer.apply_result
local run_buffer_usecase = buffer.run_buffer_usecase
local buffer_changed = buffer.buffer_changed
local apply_refresh = buffer.apply_refresh

M.highlight_buffer = buffer.highlight_buffer
M.refresh_indicators = buffer.refresh_indicators
M.render_stray = buffer.render_stray
M.rename_summary = rename.summary
M.map_summary = map.summary
M.map_clear = map.clear

-- Day-file IO, rebound as locals.
local existing_daybook_dates = daybook_io.existing_daybook_dates
local expanded_daybook_settings = daybook_io.expanded_daybook_settings
local can_abandon_current_buffer = daybook_io.can_abandon_current_buffer
local open_daybook_file = daybook_io.open_daybook_file
local edit_daybook_file = daybook_io.edit_daybook_file
local current_buffer_daybook_date = daybook_io.current_buffer_daybook_date
local live_offset = daybook_io.live_offset
local insert_new_log = daybook_io.insert_new_log

-- Report buffers, rebound as locals.
local open_report = report_buffers.open_report
local refresh_report_windows = report_buffers.refresh_report_windows

-- Current-time stamping + carryover, rebound as locals.
local guard_current_time = current_time.guard_current_time
local apply_insert_time = current_time.apply_insert_time
local apply_insert_entry = current_time.apply_insert_entry

-- Today's log must be left in a valid state: leaving a broken today (out-of-order
-- entries, an invalid entry, ...) would silently stop tracking the active day, so the
-- day-navigation commands refuse until it is fixed. Only today is guarded -- browsing a
-- past day's old problems is fine -- and only the plugin's own navigation (a raw :edit
-- cannot be vetoed). The problems are published as buffer diagnostics so they show up.
local function refuse_when_today_has_errors(settings)
  local file_date = current_buffer_daybook_date(settings)
  if not file_date or not daybook.same_date(file_date, os.time()) then
    return false
  end

  local warnings = refresh_summaries.run(buffer_lines()).warnings
  if #warnings == 0 then
    return false
  end

  publish_diagnostics(warnings)
  warn("daylog: today's log has errors; fix them before leaving the day")
  return true
end

-- Bring a work item from a configured source into the current log at the
-- current time. Offline-first: reads the source's local cache and opens
-- vim.ui.select (Telescope/fzf/snacks take over if installed). On pick the
-- configured "{id} {title}" template is inserted; cancelling falls back to a bare
-- timestamp, exactly like :Daylog insert with no argument.
function M.insert_from_source(name)
  if guard_current_time("insert") then
    return
  end

  local source = sources_registry.get(name)
  if not source then
    warn("daylog: unknown source '" .. name .. "'")
    return
  end

  -- Refuse a cursor outside a log now, before opening the async picker
  -- (cache read, optional network, a UI round trip), exactly as :Daylog insert
  -- with no argument refuses up front. insert_entry re-validates at apply time
  -- too, since the buffer can change under the picker -- this is the fail-fast.
  local cursor_ctx, cursor_err = support.get_validated_at_row(buffer_lines(), cursor_row())
  if not cursor_ctx then
    warn(cursor_err)
    return
  end

  -- The picker is async, so capture the moment and the target buffer up front: a
  -- late selection then stamps the time the command was issued and never edits a
  -- buffer we have since moved away from.
  local time = os.date("%H:%M")
  local auto_offset = live_offset()
  local target_buf = vim.api.nvim_get_current_buf()

  -- Apply a chosen item into the originating buffer, guarding against the buffer
  -- changing under the async picker.
  local function insert_choice(item)
    if buffer_changed(target_buf, "insert") then
      return
    end

    apply_insert_entry(time, source.to_entry_text(item), auto_offset)
  end

  -- The scoped source picker: type-as-you-search across the whole tracker when the source
  -- supports it (cached items show at an empty prompt), else the offline cache. Cancelling
  -- leaves a bare timestamp, like a plain :Daylog insert.
  pick.source(source, name, {
    prompt = "Daylog: " .. name,
    prompt_fallback = "Daylog: pick " .. name .. " item",
    on_pick = insert_choice,
    on_cancel = function()
      apply_insert_time(time, auto_offset)
    end,
  })
end

-- The unified "what to log" picker (`:Daylog! insert`): pool every configured source's cached
-- items plus your recent logged activities into one ranked, deduped, offline fuzzy list. Picking
-- a row inserts it at the current time; cancelling leaves a bare timestamp, like :Daylog insert.
function M.insert_unified()
  if guard_current_time("insert") then
    return
  end

  -- Refuse a cursor outside a log up front, before the async picker, exactly like the other
  -- insert paths. insert_entry re-validates at apply time too.
  local cursor_ctx, cursor_err = support.get_validated_at_row(buffer_lines(), cursor_row())
  if not cursor_ctx then
    warn(cursor_err)
    return
  end

  local time = os.date("%H:%M")
  local auto_offset = live_offset()
  local target_buf = vim.api.nvim_get_current_buf()

  -- Insert the chosen/typed activity, or a bare timestamp for an empty value -- guarded against
  -- the buffer moving under the async picker.
  local function insert(text)
    if buffer_changed(target_buf, "insert") then
      return
    end
    if text == nil or text == "" then
      apply_insert_time(time, auto_offset)
    else
      apply_insert_entry(time, text, auto_offset)
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
      apply_insert_time(time, auto_offset)
    end,
  })
end

-- Refresh the on-disk cache for one source, or every configured source.
function M.sync(name)
  if name and name ~= "" then
    if not sources_registry.get(name) then
      warn("daylog: unknown source '" .. name .. "'")
      return
    end

    sources_sync.sync(name, { silent = false })
    return
  end

  local names = sources_registry.names()
  if #names == 0 then
    warn("daylog: no sources configured")
    return
  end

  for _, source_name in ipairs(names) do
    sources_sync.sync(source_name, { silent = false })
  end
end

-- Insert the current time at the cursor and enter insert mode.
function M.insert_now()
  if guard_current_time("insert") then
    return
  end

  apply_insert_time(os.date("%H:%M"), live_offset())
end

function M.copy()
  run_buffer_usecase(append_copy.run)
end

-- Scaffold a fresh, empty log into the current buffer (the active log when appended). The
-- scaffold and its config defaults live in daybook_io, shared with the empty-day auto-init.
function M.new_log()
  insert_new_log()
end

function M.repeat_()
  if guard_current_time("repeat") then
    return
  end

  run_buffer_usecase(repeat_current.run, cursor_row(), os.date("%H:%M"), live_offset())
end

function M.order()
  local result, err = order_logs.run(buffer_lines())
  if not result then
    warn(err)
    return
  end

  apply_result(result)

  if result.warnings and #result.warnings > 0 then
    warn(
      "daylog: ordering set the tag/location/utc offset of order-dependent entries; review: "
        .. table.concat(result.warnings, ", ")
    )
  end
end

function M.log()
  run_buffer_usecase(log_current.run, cursor_row())
end

-- Manually balance summary rounding by `delta` q-steps (a signed integer; 0 clears
-- the cursor target's nudge). The cursor may sit on a summary row -- whose best
-- contributing entry is nudged for it -- or directly on an entry.
function M.balance(arg)
  local delta = 1

  if arg ~= nil and arg ~= "" then
    delta = tonumber(arg)
    if delta == nil or delta ~= math.floor(delta) then
      warn("daylog: balance expects an integer step count, e.g. +1, -2, or 0 to clear")
      return
    end
  end

  run_buffer_usecase(balance_summary.run, cursor_row(), delta)
end

-- Split the activity under the cursor into weighted sub-activities. `fargs` is the
-- raw command argument list: each is a positive weight, and their count is the number
-- of parts (none means an even two-way split). The total time is preserved.
function M.split(fargs)
  local weights = {}

  for _, arg in ipairs(fargs or {}) do
    local w = tonumber(arg)
    if w == nil or w <= 0 then
      warn("daylog: split weights must be positive numbers, e.g. :Daylog split 2 1 1")
      return
    end
    weights[#weights + 1] = w
  end

  if #weights == 1 then
    warn("daylog: split needs at least two weights, or none for an even split")
    return
  end

  run_buffer_usecase(split_summary.run, cursor_row(), weights)
end

-- Rebuild every existing summary in the current buffer to match its entries.
function M.refresh()
  apply_refresh(false)
end

-- Jump to the `|step|`-th existing log before (step < 0) or after (step > 0)
-- the current buffer's day, skipping days that have no log. The anchor falls
-- back to today when the buffer is not a canonical daybook file. Pure navigation:
-- it never inserts the current time, even when it lands on today, and it never
-- creates a file (use :Daylog day to start an arbitrary day). When no log
-- exists in that direction it warns and stays put.
function M.open_relative_day(step)
  local settings = expanded_daybook_settings()
  if settings == nil then
    warn("daylog: daybook.root is not configured")
    return
  end

  if not can_abandon_current_buffer() then
    warn("daylog: current buffer has unsaved changes")
    return
  end

  if refuse_when_today_has_errors(settings) then
    return
  end

  local anchor = current_buffer_daybook_date(settings) or os.time()
  local direction = step < 0 and -1 or 1
  local target =
    daybook.nearest_date(existing_daybook_dates(settings), anchor, direction, math.abs(step))
  if not target then
    warn(direction < 0 and "daylog: no earlier log" or "daylog: no later log")
    return
  end

  edit_daybook_file(settings, target)
end

-- Public verb API (require("daylog").<verb>) -- the canonical interface the :Daylog command
-- and any user keymaps dispatch to. The day verbs build on the shared daybook_io shell helpers
-- (open_daybook_file to create/open, edit_daybook_file to navigate) plus the unified date
-- grammar, which lets day() both backfill a past day and pre-create a future one.

-- Open today's daybook file -- creating it scaffolded when new -- and stamp the current time
-- on a fresh day. The daily "start logging" ritual; bare :Daylog targets this.
function M.today()
  local settings = expanded_daybook_settings()
  if settings == nil then
    warn("daylog: daybook.root is not configured")
    return
  end

  if not can_abandon_current_buffer() then
    warn("daylog: current buffer has unsaved changes")
    return
  end

  local now = os.time()
  local ok, was_initialized = open_daybook_file(settings, daybook.offset_date(now, 0))
  if not ok or not was_initialized then
    return
  end

  apply_insert_time(os.date("%H:%M", now))
  apply_refresh(false)
end

-- Open the daybook day named by `when` -- a resolve_date token (today / yesterday / tomorrow /
-- a weekday / +N / -N / YYYY-MM-DD; default today) -- creating it scaffolded when new. Unlike
-- today() it never stamps the time, so it is how to backfill a past day or pre-create a future
-- one.
function M.day(when)
  local settings = expanded_daybook_settings()
  if settings == nil then
    warn("daylog: daybook.root is not configured")
    return
  end

  if not can_abandon_current_buffer() then
    warn("daylog: current buffer has unsaved changes")
    return
  end

  if refuse_when_today_has_errors(settings) then
    return
  end

  local date = daybook.resolve_date((when == nil or when == "") and "today" or when, os.time())
  if not date then
    warn("daylog: unknown day '" .. tostring(when) .. "' -- try today, monday, -1, +2, 2026-05-10")
    return
  end

  local ok, was_initialized = open_daybook_file(settings, date)
  if not ok or not was_initialized then
    return
  end

  apply_refresh(false)
end

-- Browse to the n-th existing log after (next_day) / before (prev_day) the current day,
-- skipping days with no log; never creates or stamps. n defaults to 1.
function M.next_day(count)
  M.open_relative_day(count or 1)
end

function M.prev_day(count)
  M.open_relative_day(-(count or 1))
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

-- Map the cursor entry / summary row to a label. opts.clear removes the mapping; otherwise
-- opts.value sets the label directly and opts.source opens that tracker's picker. opts.range
-- ({ line1, line2 }) maps a visual range of entries.
function M.map(opts)
  opts = opts or {}
  if opts.clear then
    return M.map_clear(opts.range)
  end
  return M.map_summary(opts.value, opts.source, opts.range)
end

-- Rename what a summary row reports under. opts.value renames directly; opts.source opens that
-- tracker's picker; neither opens the unified recent+sources picker.
function M.rename(opts)
  opts = opts or {}
  return M.rename_summary(opts.value, opts.source, opts.range)
end

-- One end of a `:Daylog report` range: a named token (`today`, `monday`, ...) or a `YYYY-MM-DD`
-- literal resolved against `now`; or, when the bound is omitted, the daybook extreme that
-- `fallback` returns (earliest for the start, latest for the end). Returns ts, or nil + err.
local function resolve_range_bound(token, now, fallback)
  if token then
    local ts = daybook.resolve_date(token, now)
    if not ts then
      return nil, "daylog: invalid date: " .. token
    end
    return ts
  end

  local settings = expanded_daybook_settings()
  if settings == nil then
    return nil, "daylog: daybook.root is not configured"
  end
  local ts = fallback(settings)
  if not ts then
    return nil, "daylog: no daybook logs found"
  end
  return ts
end

-- Resolve a `:Daylog report` range request into a concrete, pinned list of dates. Each bound is a
-- named token or a `YYYY-MM-DD` literal; an omitted start resolves to the earliest logged day on
-- file and an omitted end to the latest (so an open end reaches as far as the data goes,
-- future-dated files included). An explicit reversed range is rejected, and a span with no logs
-- falls through to the "no daybook logs found" warning when the report is built.
local function resolve_range_dates(request)
  local now = os.time()

  local from_ts, from_err = resolve_range_bound(request.from, now, daybook_io.earliest_daybook_date)
  if not from_ts then
    return nil, from_err
  end

  local to_ts, to_err = resolve_range_bound(request.to, now, daybook_io.latest_daybook_date)
  if not to_ts then
    return nil, to_err
  end

  if request.from and request.to and from_ts > to_ts then
    return nil, "daylog: range start is after end"
  end

  return daybook.range_dates(from_ts, to_ts)
end

-- Parse a report range string: a bare count ("7") -> { count = N }, or a "FROM..TO" token
-- range -> { from, to } (either side may be empty for an open end). Returns nil otherwise. A
-- bare number reads as a count here, never a day offset -- resolve_date owns the signed-offset
-- day tokens, so the two readings never overlap.
local function parse_report_range(value)
  if type(value) ~= "string" then
    return nil
  end

  if value:match("^%d+$") then
    local count = tonumber(value)
    return count >= 1 and { count = count } or nil
  end

  local from, to = value:match("^(.-)%.%.(.-)$")
  if not from then
    return nil
  end

  return { from = from ~= "" and from or nil, to = to ~= "" and to or nil }
end

-- Open a multi-day report over `range`: a count ("7"), a "FROM..TO" token range
-- ("monday..today", "..today"), or a pre-parsed request table (`{ count = N }` / `{ from, to }`).
-- `aggregate_only` shows only the period total. The resolved date list is pinned in the spec so
-- the report keeps its span.
function M.report(range, aggregate_only)
  local request = type(range) == "table" and range or parse_report_range(range or "")
  if not request then
    warn("daylog: report expects a day count or a FROM..TO range (e.g. 7, monday..today, ..today)")
    return
  end

  local dates, err
  if request.count then
    dates = daybook.trailing_dates(os.time(), request.count)
  else
    dates, err = resolve_range_dates(request)
  end

  if not dates then
    warn(err)
    return
  end

  -- The buffer name keeps the requested range (a stable identity), while the report's
  -- header label resolves to the span of days actually found.
  local request_label = #dates > 0 and daybook.date_range_label(dates[1], dates[#dates]) or nil

  open_report({
    dates = dates,
    request_label = request_label,
    aggregate_only = aggregate_only or false,
  })
end

-- Wire the autocmds that drive automatic summary refresh for the configured
-- mode. `off` installs nothing (manual :Daylog refresh still works) but still
-- clears any autocmds a previous setup() left behind.
local function setup_auto_summary(mode)
  local group = vim.api.nvim_create_augroup("DaylogAutoSummary", { clear = true })
  if mode == "off" then
    return
  end

  local function on_daylog_buffer(opts, action)
    if vim.bo[opts.buf].filetype == "daylog" then
      action()
    end
  end

  local function refresh(opts)
    on_daylog_buffer(opts, function()
      apply_refresh(true)
      refresh_report_windows()
    end)
  end

  if mode == "save" then
    vim.api.nvim_create_autocmd("BufWritePre", { group = group, callback = refresh })
  elseif mode == "idle" then
    vim.api.nvim_create_autocmd(
      { "CursorHold", "CursorHoldI", "InsertLeave" },
      { group = group, callback = refresh }
    )
  elseif mode == "change" then
    -- Debounce per buffer so the last change in a burst refreshes, and a burst in one daylog
    -- never cancels another daylog's pending refresh. The deferred refresh re-checks at fire
    -- time (not just at schedule) that this is still the buffer's last change and that the
    -- buffer is still current -- apply_refresh acts on the current buffer -- so switching away
    -- within the 200ms window never refreshes the wrong buffer.
    local generations = {}
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      callback = function(opts)
        on_daylog_buffer(opts, function()
          local buf = opts.buf
          generations[buf] = (generations[buf] or 0) + 1
          local scheduled = generations[buf]
          vim.defer_fn(function()
            if scheduled ~= generations[buf] or vim.api.nvim_get_current_buf() ~= buf then
              return
            end
            on_daylog_buffer({ buf = buf }, function()
              apply_refresh(true)
              refresh_report_windows()
            end)
          end, 200)
        end)
      end,
    })
  end
end

-- Build and register the source objects declared in config, injecting the shell
-- transport, JSON codec, and a lazy token resolver. Clears first so repeated
-- setup() calls (and tests) start from a clean registry.
local function instantiate_sources()
  sources_registry.clear()

  local sources = config.get().sources
  if not sources then
    return
  end

  for name, source_config in pairs(sources) do
    local source, err = sources_registry.instantiate(name, source_config, {
      transport = sources_http,
      json = vim.json,
      token_resolver = function(source_cfg)
        local ok, token = pcall(source_cfg.token)
        if not ok then
          return nil, "daylog: source token() errored: " .. tostring(token)
        end
        if type(token) ~= "string" or token == "" then
          return nil, "daylog: source token() did not return a non-empty string"
        end
        return token
      end,
    })

    if source then
      sources_registry.register(name, source)
    else
      warn(err)
    end
  end
end

-- The opt-in default key set (setup({ keymaps = true })): buffer-local in daylog files. ]d / [d
-- navigate days (deliberately overriding the diagnostic jumps inside daylog buffers, and
-- count-aware -- 3]d steps three logged days on); the editing verbs sit under the <leader>d
-- namespace (gitsigns-style: rides whatever <leader> you set, and only shadows a global
-- <leader>d* inside daylog buffers); g? shows the cheatsheet. Each entry carries a description so
-- which-key (and :Daylog keys) can label it.
local DEFAULT_KEYMAPS = {
  {
    lhs = "]d",
    desc = "next day",
    rhs = function()
      M.next_day(vim.v.count1)
    end,
  },
  {
    lhs = "[d",
    desc = "previous day",
    rhs = function()
      M.prev_day(vim.v.count1)
    end,
  },
  {
    lhs = "<leader>di",
    desc = "insert (stamp the current time)",
    rhs = function()
      M.insert()
    end,
  },
  {
    lhs = "<leader>dI",
    desc = "insert from picker (what to log)",
    rhs = function()
      M.insert({ pick = true })
    end,
  },
  {
    lhs = "<leader>dr",
    desc = "repeat the activity under the cursor",
    rhs = function()
      M.repeat_()
    end,
  },
  {
    lhs = "<leader>dn",
    desc = "new log block",
    rhs = function()
      M.new_log()
    end,
  },
  {
    lhs = "<leader>dc",
    desc = "copy the active log",
    rhs = function()
      M.copy()
    end,
  },
  {
    lhs = "<leader>do",
    desc = "order entries by time",
    rhs = function()
      M.order()
    end,
  },
  {
    lhs = "<leader>dl",
    desc = "toggle logged on the summary row",
    rhs = function()
      M.log()
    end,
  },
  {
    lhs = "<leader>dm",
    desc = "map to a report label",
    rhs = function()
      M.map({})
    end,
  },
  {
    lhs = "<leader>dm",
    desc = "map the selection (visual)",
    mode = "x",
    rhs = ":Daylog map<CR>",
  },
  {
    lhs = "<leader>dR",
    desc = "rename the entry / tag / location",
    rhs = function()
      M.rename({})
    end,
  },
  {
    lhs = "<leader>dR",
    desc = "rename the selection (visual)",
    mode = "x",
    rhs = ":Daylog rename<CR>",
  },
  {
    lhs = "<leader>df",
    desc = "refresh summaries",
    rhs = function()
      M.refresh()
    end,
  },
  {
    lhs = "<leader>db",
    desc = "toggle the time bar",
    rhs = function()
      M.bar()
    end,
  },
  {
    lhs = "g?",
    desc = "show daylog keys",
    rhs = function()
      M.keys()
    end,
  },
}

-- The keymap cheatsheet entries ({ lhs, desc }) for the active config: the default set, a custom
-- table (generic label), or empty when keymaps are off. Read by :Daylog keys / g?.
local function keymap_help_entries()
  local keymaps = config.get().keymaps
  if keymaps == true then
    local entries = {}
    for _, m in ipairs(DEFAULT_KEYMAPS) do
      entries[#entries + 1] = { lhs = m.lhs, desc = m.desc }
    end
    return entries
  end

  if type(keymaps) == "table" then
    local entries = {}
    for lhs in pairs(keymaps) do
      entries[#entries + 1] = { lhs = lhs, desc = "your mapping" }
    end
    table.sort(entries, function(a, b)
      return a.lhs < b.lhs
    end)
    return entries
  end

  return {}
end

-- Show the keymap cheatsheet popup (:Daylog keys, and g? in the default set).
function M.keys()
  require("daylog.keys").show(keymap_help_entries())
end

-- Toggle the colour-coded time bar; the `time_bar` config sets the initial state. The toggle is
-- global -- it stays on (or off) as you navigate between daylog files -- not per buffer.
function M.bar()
  if vim.bo.filetype ~= "daylog" then
    warn("daylog: the time bar is shown in daylog files")
    return
  end
  buffer.toggle_time_bar()
end

-- Apply the configured keymaps buffer-locally to a daylog buffer (true -> the default set, a
-- table -> the user's own lhs -> rhs). Each map carries a description so which-key can label it.
local function apply_keymaps(buf)
  local keymaps = config.get().keymaps
  if not keymaps then
    return
  end

  if keymaps == true then
    for _, m in ipairs(DEFAULT_KEYMAPS) do
      vim.keymap.set(
        m.mode or "n",
        m.lhs,
        m.rhs,
        { buffer = buf, silent = true, desc = "Daylog: " .. m.desc }
      )
    end
    return
  end

  for lhs, rhs in pairs(keymaps) do
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = "Daylog (user map)" })
  end
end

-- (Re)install the FileType hook applying the opt-in keymaps to each daylog buffer. The augroup
-- clears on re-setup so a config change never stacks hooks; already-open daylog buffers get the
-- maps immediately.
local function setup_keymaps()
  local group = vim.api.nvim_create_augroup("DaylogKeymaps", { clear = true })
  if not config.get().keymaps then
    return
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "daylog",
    callback = function(opts)
      apply_keymaps(opts.buf)
    end,
  })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "daylog" then
      apply_keymaps(buf)
    end
  end
end

function M.setup(options)
  config.setup(options)
  filetype.register()
  instantiate_sources()
  commands.register()

  setup_auto_summary(config.get().auto_summary)
  setup_keymaps()
end

return M
