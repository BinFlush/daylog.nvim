local filetype = require("blotter.filetype")
local append_copy = require("blotter.usecases.append_copy")
local balance_summary = require("blotter.usecases.balance_summary")
local carryover = require("blotter.usecases.carryover")
local config = require("blotter.config")
local buffer = require("blotter.buffer")
local commands = require("blotter.commands")
local insert_blot = require("blotter.usecases.insert_blot")
local insert_now = require("blotter.usecases.insert_now")
local journal = require("blotter.journal")
local log_current = require("blotter.usecases.log_current")
local journal_io = require("blotter.journal_io")
local order_blotters = require("blotter.usecases.order_blotters")
local refresh_summaries = require("blotter.usecases.refresh_summaries")
local rename = require("blotter.rename")
local repeat_current = require("blotter.usecases.repeat_current")
local sources_http = require("blotter.sources.http")
local sources_picker = require("blotter.sources.picker")
local sources_registry = require("blotter.sources.registry")
local sources_sync = require("blotter.sources.sync")
local support = require("blotter.usecases.support")
local text = require("blotter.text")
local report_buffers = require("blotter.report")

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
M.rename_summary = rename.summary

-- Day-file IO, rebound as locals.
local journal_lines = journal_io.journal_lines
local journal_path_has_content = journal_io.journal_path_has_content
local existing_journal_dates = journal_io.existing_journal_dates
local expanded_journal_settings = journal_io.expanded_journal_settings
local can_abandon_current_buffer = journal_io.can_abandon_current_buffer
local open_journal_file = journal_io.open_journal_file
local edit_journal_file = journal_io.edit_journal_file
local current_buffer_journal_date = journal_io.current_buffer_journal_date

-- Report buffers, rebound as locals.
local open_report = report_buffers.open_report
local refresh_report_windows = report_buffers.refresh_report_windows

local function apply_insert_time(time)
  local lines = buffer_lines()
  local row = cursor_row()
  local result, err = insert_now.run(lines, row, time)
  if not result then
    warn(err)
    return false
  end

  apply_result(result)
  return true
end

-- Insert a fully-resolved "HH:MM <text>" blot at the cursor's blotter and enter
-- insert mode. Mirrors apply_insert_time but carries an activity string (the text
-- is built and sanitized by the source layer before it gets here).
local function apply_insert_blot(time, entry_text)
  local result, err = insert_blot.run(buffer_lines(), cursor_row(), time, entry_text)
  if not result then
    warn(err)
    return false
  end

  apply_result(result)
  return true
end

-- Today's blotter must be left in a valid state: leaving a broken today (out-of-order
-- blots, an invalid blot, ...) would silently stop tracking the active day, so the
-- day-navigation commands refuse until it is fixed. Only today is guarded -- browsing a
-- past day's old problems is fine -- and only the plugin's own navigation (a raw :edit
-- cannot be vetoed). The problems are published as buffer diagnostics so they show up.
local function refuse_when_today_has_errors(settings)
  local file_date = current_buffer_journal_date(settings)
  if not file_date or not journal.same_date(file_date, os.time()) then
    return false
  end

  local warnings = refresh_summaries.run(buffer_lines()).warnings
  if #warnings == 0 then
    return false
  end

  publish_diagnostics(warnings)
  warn("blotter: today's blotter has errors; fix them before leaving the day")
  return true
end

-- Roll a task that ran across midnight into today: close the previous day at
-- 24:00, open/create today, continue the activity from 00:00, then apply the
-- originating command at the current time. Returns true when it took over the
-- request (carried over, declined, or intentionally refused), false when this is
-- not a carryover situation -- leaving guard_current_time to fall back to the
-- cross-day repeat (:BlotRepeat) or to hard-block (:BlotInsert).
local function run_carryover(settings, command, now)
  local lines = buffer_lines()

  local carried = carryover.last_running_entry(lines)
  if not carried then
    return false
  end

  -- Capture the cursor blot before the buffer switches away.
  local repeated
  if command == "repeat" then
    local err
    repeated, err = carryover.entry_at_row(lines, cursor_row())
    if not repeated then
      warn(err)
      return true
    end
  end

  -- A today that already holds content has no room for a fresh 00:00 carry-over.
  -- For :BlotRepeat, decline (return false) so guard_current_time falls through
  -- to the normal cross-day repeat, inserting the cursor activity into the existing
  -- today -- exactly as repeating from any other day does. There is nothing to
  -- carry for :BlotInsert, so it still points the user at :BlotterToday.
  local today_path = journal.path_for_date(settings, now)
  if journal_path_has_content(today_path) then
    if command == "repeat" then
      return false
    end

    warn("blotter: today's blotter already exists; open it with :BlotterToday")
    return true
  end

  local prompt = string.format("Past midnight: carry '%s' over to today's blotter?", carried.text)
  if vim.fn.confirm(prompt, "&Yes\n&No", 1) ~= 1 then
    return true
  end

  local close, close_err = carryover.close_edit(lines)
  if not close then
    warn(close_err)
    return true
  end
  apply_result(close)

  -- Refresh the previous day's summary so the carried-over 24:00 close is
  -- reflected on disk regardless of the auto_summary mode (apply_result only
  -- republishes diagnostics; it does not recompute summaries).
  apply_refresh(false)

  if not pcall(vim.cmd, "silent write") then
    warn("blotter: failed to save the previous day before carrying over")
    return true
  end

  if not open_journal_file(settings, now) then
    return true
  end

  local seed, seed_err = carryover.seed_edit(buffer_lines(), carried, 0)
  if not seed then
    warn(seed_err)
    return true
  end
  apply_result(seed)

  if command == "repeat" then
    local clock = os.date("*t", now)
    local seed_repeat, seed_repeat_err =
      carryover.seed_edit(buffer_lines(), repeated, clock.hour * 60 + clock.min)
    if not seed_repeat then
      warn(seed_repeat_err)
      return true
    end
    apply_result(seed_repeat)
  else
    apply_insert_time(os.date("%H:%M", now))
  end

  return true
end

-- Bring the activity under the cursor into today's blotter at the current time,
-- used when :BlotRepeat runs on another day's file. The browsed day is left
-- untouched; today is opened (created if needed) and the window switches to it.
local function run_cross_day_repeat(settings, now)
  -- Capture the activity before open_journal_file switches the buffer away.
  local activity, err = carryover.entry_at_row(buffer_lines(), cursor_row())
  if not activity then
    warn(err)
    return
  end

  -- Opening today switches the window away from the browsed day; refuse cleanly when
  -- that buffer cannot be abandoned (unsaved with 'hidden' off), the same way the day
  -- navigation does, instead of surfacing a raw E37 from the :edit below. The browsed
  -- day is left untouched, so -- unlike carryover -- it is not saved on the user's behalf.
  if not can_abandon_current_buffer() then
    warn("blotter: current buffer has unsaved changes")
    return
  end

  local clock = os.date("*t", now)
  local minutes = clock.hour * 60 + clock.min

  -- If today already holds a blotter, confirm the activity can be inserted there before
  -- switching to it, so a broken today is reported while staying on the browsed day
  -- rather than yanking the window across and only then failing. A missing/empty (or
  -- whitespace-only) today is initialized fresh by open_journal_file and always seeds.
  local today_lines = journal_lines(journal.path_for_date(settings, now))
  if today_lines and not text.is_empty(today_lines) then
    local ok, validate_err = carryover.seed_edit(today_lines, activity, minutes)
    if not ok then
      warn(validate_err)
      return
    end
  end

  if not open_journal_file(settings, now) then
    return
  end

  local seed, seed_err = carryover.seed_edit(buffer_lines(), activity, minutes)
  if not seed then
    warn(seed_err)
    return
  end

  apply_result(seed)
  apply_refresh(false)
end

-- Refuse to stamp the current time into a day that is not today. When the
-- buffer is not a canonical journal file the guard stays silent so the plugin
-- keeps working on arbitrary files. Returns true when the request was handled
-- (blocked, carried over, or repeated into today) and the caller should stop.
local function guard_current_time(command)
  local settings = expanded_journal_settings()
  if settings == nil then
    return false
  end

  local file_date = current_buffer_journal_date(settings)
  if file_date == nil then
    return false
  end

  local now = os.time()
  if journal.same_date(file_date, now) then
    return false
  end

  if
    journal.same_date(file_date, journal.offset_date(now, -1))
    and run_carryover(settings, command, now)
  then
    return true
  end

  -- :BlotRepeat on any other day brings the cursor activity into today instead
  -- of refusing; :BlotInsert still refuses (there is no activity to carry).
  if command == "repeat" then
    run_cross_day_repeat(settings, now)
    return true
  end

  warn(
    string.format(
      "blotter: this file is dated %s, not today (%s); refusing to insert the current time",
      journal.date_label(file_date),
      journal.date_label(now)
    )
  )
  return true
end

-- Bring a work item from a configured source into the current blotter at the
-- current time. Offline-first: reads the source's local cache and opens
-- vim.ui.select (Telescope/fzf/snacks take over if installed). On pick the
-- configured "{id} {title}" template is inserted; cancelling falls back to a bare
-- timestamp, exactly like :BlotInsert with no argument.
function M.insert_from_source(name)
  if guard_current_time("insert") then
    return
  end

  local source = sources_registry.get(name)
  if not source then
    warn("blotter: unknown source '" .. name .. "'")
    return
  end

  -- Refuse a cursor outside a blotter now, before opening the async picker
  -- (cache read, optional network, a UI round trip), exactly as :BlotInsert
  -- with no argument refuses up front. insert_blot re-validates at apply time
  -- too, since the buffer can change under the picker -- this is the fail-fast.
  local cursor_ctx, cursor_err = support.get_validated_at_row(buffer_lines(), cursor_row())
  if not cursor_ctx then
    warn(cursor_err)
    return
  end

  local sources = config.get().sources or {}
  local ttl = sources[name] and sources[name].ttl or 1800

  -- The picker is async, so capture the moment and the target buffer up front: a
  -- late selection then stamps the time the command was issued and never edits a
  -- buffer we have since moved away from.
  local time = os.date("%H:%M")
  local target_buf = vim.api.nvim_get_current_buf()

  -- Apply a chosen item into the originating buffer, guarding against the buffer
  -- changing under the async picker.
  local function insert_choice(item)
    if buffer_changed(target_buf, "insert") then
      return
    end

    apply_insert_blot(time, source.to_blot_text(item))
  end

  local has_telescope = pcall(require, "telescope")

  sources_sync.ensure_fresh(name, ttl, function(items)
    -- With Telescope and a searchable source, type-as-you-search across the whole
    -- tracker (cached items show at an empty prompt). Otherwise the offline cache
    -- via vim.ui.select. Both insert through insert_choice; cancelling leaves a
    -- bare timestamp, like a plain :BlotInsert.
    if has_telescope and source.search then
      require("blotter.telescope").live_pick(source, {
        initial_items = items,
        prompt = "Blotter: " .. name,
        min_query = sources[name] and sources[name].min_query,
        on_pick = insert_choice,
        on_cancel = function()
          apply_insert_time(time)
        end,
      })
      return
    end

    -- Resolve each item's display through the shared source display contract
    -- (aligned columns when the source supports it, else per-item formatting).
    local display = sources_picker.display_for(source, items)

    vim.ui.select(items, {
      prompt = "Blotter: pick " .. name .. " item",
      format_item = display,
    }, function(choice)
      if not choice then
        apply_insert_time(time)
        return
      end

      insert_choice(choice)
    end)
  end)
end

-- Refresh the on-disk cache for one source, or every configured source.
function M.sync_source(name)
  if name and name ~= "" then
    if not sources_registry.get(name) then
      warn("blotter: unknown source '" .. name .. "'")
      return
    end

    sources_sync.sync(name, { silent = false })
    return
  end

  local names = sources_registry.names()
  if #names == 0 then
    warn("blotter: no sources configured")
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

  apply_insert_time(os.date("%H:%M"))
end

function M.append_copy()
  run_buffer_usecase(append_copy.run)
end

function M.repeat_current()
  if guard_current_time("repeat") then
    return
  end

  run_buffer_usecase(repeat_current.run, cursor_row(), os.date("%H:%M"))
end

function M.order_blotters()
  local result, err = order_blotters.run(buffer_lines())
  if not result then
    warn(err)
    return
  end

  apply_result(result)

  if result.warnings and #result.warnings > 0 then
    warn(
      "blotter: ordering set the tag/location/utc offset of order-dependent blots; review: "
        .. table.concat(result.warnings, ", ")
    )
  end
end

function M.log_current()
  run_buffer_usecase(log_current.run, cursor_row())
end

-- Manually balance summary rounding by `delta` q-steps (a signed integer; 0 clears
-- the cursor target's nudge). The cursor may sit on a summary row -- whose best
-- contributing blot is nudged for it -- or directly on a blot.
function M.balance(arg)
  local delta = 1

  if arg ~= nil and arg ~= "" then
    delta = tonumber(arg)
    if delta == nil or delta ~= math.floor(delta) then
      warn("blotter: BlotBalance expects an integer step count, e.g. +1, -2, or 0 to clear")
      return
    end
  end

  run_buffer_usecase(balance_summary.run, cursor_row(), delta)
end

-- Rebuild every existing summary in the current buffer to match its blots.
function M.refresh()
  apply_refresh(false)
end

function M.open_today(day_offset)
  local settings = expanded_journal_settings()
  if settings == nil then
    warn("blotter: journal.root is not configured")
    return
  end

  if not can_abandon_current_buffer() then
    warn("blotter: current buffer has unsaved changes")
    return
  end

  local now = os.time()
  local offset = day_offset or 0
  local target_date = journal.offset_date(now, offset)

  -- Only opening today creates and stamps a file. Other offsets are navigation:
  -- open the day if it exists, otherwise an empty unmodified buffer (no file
  -- created).
  if offset ~= 0 then
    if refuse_when_today_has_errors(settings) then
      return
    end

    edit_journal_file(settings, target_date)
    return
  end

  local ok, was_initialized = open_journal_file(settings, target_date)
  if not ok then
    return
  end

  if not was_initialized then
    return
  end

  -- A freshly created today file gets the current time and a summary, so it tracks
  -- the day from the start (live when auto_summary is enabled). The summary refresh
  -- creates it the same way it would self-heal any other summary-less blotter.
  apply_insert_time(os.date("%H:%M", now))
  apply_refresh(false)
end

-- Jump to the `|step|`-th existing blotter before (step < 0) or after (step > 0)
-- the current buffer's day, skipping days that have no blotter. The anchor falls
-- back to today when the buffer is not a canonical journal file. Pure navigation:
-- it never inserts the current time, even when it lands on today, and it never
-- creates a file (use :BlotterInit to start an arbitrary day). When no blotter
-- exists in that direction it warns and stays put.
function M.open_relative_day(step)
  local settings = expanded_journal_settings()
  if settings == nil then
    warn("blotter: journal.root is not configured")
    return
  end

  if not can_abandon_current_buffer() then
    warn("blotter: current buffer has unsaved changes")
    return
  end

  if refuse_when_today_has_errors(settings) then
    return
  end

  local anchor = current_buffer_journal_date(settings) or os.time()
  local direction = step < 0 and -1 or 1
  local target =
    journal.nearest_date(existing_journal_dates(settings), anchor, direction, math.abs(step))
  if not target then
    warn(direction < 0 and "blotter: no earlier blotter" or "blotter: no later blotter")
    return
  end

  edit_journal_file(settings, target)
end

-- Create (or open) the journal file `offset` days from today, scaffolding the
-- directory, file, and default header when it is empty. Unlike :BlotterToday it
-- never stamps the current time, so it is the way to start an arbitrary past or
-- future day -- the day-navigation commands deliberately only land on days that
-- already have a blotter.
function M.init_day(offset)
  local settings = expanded_journal_settings()
  if settings == nil then
    warn("blotter: journal.root is not configured")
    return
  end

  if not can_abandon_current_buffer() then
    warn("blotter: current buffer has unsaved changes")
    return
  end

  if refuse_when_today_has_errors(settings) then
    return
  end

  local ok, was_initialized =
    open_journal_file(settings, journal.offset_date(os.time(), offset or 0))
  if not ok or not was_initialized then
    return
  end

  -- Seed the empty summary so a freshly scaffolded day is a complete, valid
  -- blotter from the start -- like a new today, just without the current-time
  -- blot. refresh_summaries creates the missing summary the same way it self-heals
  -- any summary-less blotter.
  apply_refresh(false)
end

function M.open_week(aggregate_only)
  open_report({ kind = "week", anchor = os.time(), aggregate_only = aggregate_only or false })
end

function M.open_days(count, aggregate_only)
  open_report({
    kind = "days",
    anchor = os.time(),
    count = count,
    aggregate_only = aggregate_only or false,
  })
end

-- Wire the autocmds that drive automatic summary refresh for the configured
-- mode. `off` installs nothing (manual :BlotterRefresh still works) but still
-- clears any autocmds a previous setup() left behind.
local function setup_auto_summary(mode)
  local group = vim.api.nvim_create_augroup("BlotterAutoSummary", { clear = true })
  if mode == "off" then
    return
  end

  local function on_blotter_buffer(opts, action)
    if vim.bo[opts.buf].filetype == "blotter" then
      action()
    end
  end

  local function refresh(opts)
    on_blotter_buffer(opts, function()
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
    local generation = 0
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      callback = function(opts)
        on_blotter_buffer(opts, function()
          generation = generation + 1
          local scheduled = generation
          -- Debounce: only the last change in a burst refreshes.
          vim.defer_fn(function()
            if scheduled == generation then
              apply_refresh(true)
              refresh_report_windows()
            end
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
          return nil, "blotter: source token() errored: " .. tostring(token)
        end
        if type(token) ~= "string" or token == "" then
          return nil, "blotter: source token() did not return a non-empty string"
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

function M.setup(options)
  config.setup(options)
  filetype.register()
  instantiate_sources()
  commands.register(M)

  setup_auto_summary(config.get().auto_summary)
end

return M
