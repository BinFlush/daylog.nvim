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
local sources_http = require("daylog.sources.http")
local sources_picker = require("daylog.sources.picker")
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
-- timestamp, exactly like :DaylogInsert with no argument.
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
  -- (cache read, optional network, a UI round trip), exactly as :DaylogInsert
  -- with no argument refuses up front. insert_entry re-validates at apply time
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

    apply_insert_entry(time, source.to_entry_text(item))
  end

  local has_telescope = pcall(require, "telescope")

  sources_sync.ensure_fresh(name, ttl, function(items)
    -- With Telescope and a searchable source, type-as-you-search across the whole
    -- tracker (cached items show at an empty prompt). Otherwise the offline cache
    -- via vim.ui.select. Both insert through insert_choice; cancelling leaves a
    -- bare timestamp, like a plain :DaylogInsert.
    if has_telescope and source.search then
      require("daylog.telescope").live_pick(source, {
        initial_items = items,
        prompt = "Daylog: " .. name,
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
      prompt = "Daylog: pick " .. name .. " item",
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

function M.order_logs()
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

function M.log_current()
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
      warn("daylog: DaylogBalance expects an integer step count, e.g. +1, -2, or 0 to clear")
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
      warn("daylog: split weights must be positive numbers, e.g. :DaylogSplit 2 1 1")
      return
    end
    weights[#weights + 1] = w
  end

  if #weights == 1 then
    warn("daylog: DaylogSplit needs at least two weights, or none for an even split")
    return
  end

  run_buffer_usecase(split_summary.run, cursor_row(), weights)
end

-- Rebuild every existing summary in the current buffer to match its entries.
function M.refresh()
  apply_refresh(false)
end

function M.open_today(day_offset)
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
  local offset = day_offset or 0
  local target_date = daybook.offset_date(now, offset)

  -- Only opening today creates and stamps a file. Other offsets are navigation:
  -- open the day if it exists, otherwise an empty unmodified buffer (no file
  -- created).
  if offset ~= 0 then
    if refuse_when_today_has_errors(settings) then
      return
    end

    edit_daybook_file(settings, target_date)
    return
  end

  local ok, was_initialized = open_daybook_file(settings, target_date)
  if not ok then
    return
  end

  if not was_initialized then
    return
  end

  -- A freshly created today file gets the current time and a summary, so it tracks
  -- the day from the start (live when auto_summary is enabled). The summary refresh
  -- creates it the same way it would self-heal any other summary-less log.
  apply_insert_time(os.date("%H:%M", now))
  apply_refresh(false)
end

-- Jump to the `|step|`-th existing log before (step < 0) or after (step > 0)
-- the current buffer's day, skipping days that have no log. The anchor falls
-- back to today when the buffer is not a canonical daybook file. Pure navigation:
-- it never inserts the current time, even when it lands on today, and it never
-- creates a file (use :DaylogInit to start an arbitrary day). When no log
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

-- Create (or open) the daybook file `offset` days from today, scaffolding the
-- directory, file, and default header when it is empty. Unlike :DaylogToday it
-- never stamps the current time, so it is the way to start an arbitrary past or
-- future day -- the day-navigation commands deliberately only land on days that
-- already have a log.
function M.init_day(offset)
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

  local ok, was_initialized =
    open_daybook_file(settings, daybook.offset_date(os.time(), offset or 0))
  if not ok or not was_initialized then
    return
  end

  -- Seed the empty summary so a freshly scaffolded day is a complete, valid
  -- log from the start -- like a new today, just without the current-time
  -- entry. refresh_summaries creates the missing summary the same way it self-heals
  -- any summary-less log.
  apply_refresh(false)
end

function M.open_week(aggregate_only)
  open_report({ kind = "week", anchor = os.time(), aggregate_only = aggregate_only or false })
end

-- Resolve a `:DaylogDays` range request into a concrete, pinned list of dates. An
-- omitted start resolves to the earliest logged day on file, an omitted end to today;
-- an explicit reversed range is rejected, and a span with no logs falls through to the
-- "no daybook logs found" warning when the report is built.
local function resolve_range_dates(request)
  local from_ts
  if request.from then
    from_ts = daybook.parse_date(request.from)
    if not from_ts then
      return nil, "daylog: invalid date: " .. request.from
    end
  else
    local settings = expanded_daybook_settings()
    if settings == nil then
      return nil, "daylog: daybook.root is not configured"
    end
    from_ts = daybook_io.earliest_daybook_date(settings)
    if not from_ts then
      return nil, "daylog: no daybook logs found"
    end
  end

  local to_ts
  if request.to then
    to_ts = daybook.parse_date(request.to)
    if not to_ts then
      return nil, "daylog: invalid date: " .. request.to
    end
  else
    to_ts = daybook.offset_date(os.time(), 0)
  end

  if request.from and request.to and from_ts > to_ts then
    return nil, "daylog: range start is after end"
  end

  return daybook.range_dates(from_ts, to_ts)
end

-- `request` is a normalized days request from the command: `{ count = N }` for the
-- trailing form, or `{ from = <str|nil>, to = <str|nil> }` for an explicit/open-ended
-- range. The resolved date list is pinned in the spec so the report keeps its span.
function M.open_days(request, aggregate_only)
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
    kind = "days",
    dates = dates,
    request_label = request_label,
    aggregate_only = aggregate_only or false,
  })
end

-- Wire the autocmds that drive automatic summary refresh for the configured
-- mode. `off` installs nothing (manual :DaylogRefresh still works) but still
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
    local generation = 0
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      callback = function(opts)
        on_daylog_buffer(opts, function()
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

function M.setup(options)
  config.setup(options)
  filetype.register()
  instantiate_sources()
  commands.register(M)

  setup_auto_summary(config.get().auto_summary)
end

return M
