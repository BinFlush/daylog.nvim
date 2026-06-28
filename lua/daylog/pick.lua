local config = require("daylog.config")
local daybook = require("daylog.daybook")
local daybook_io = require("daylog.daybook_io")
local entry = require("daylog.entry")
local rank = require("daylog.sources.rank")
local sources_picker = require("daylog.sources.picker")
local sources_sync = require("daylog.sources.sync")

local M = {}

-- Picker frontend (shell).
--
-- Chooses between the optional Telescope backend (daylog.telescope, required lazily
-- only when Telescope is installed) and the always-available vim.ui.select fallback,
-- so fzf-lua / snacks / mini.pick work too. The fallback renders its rows through the
-- PURE daylog.sources.picker display contract, so the columns line up in both modes.
-- Owns no buffer edits -- the caller's callbacks do the work; this only decides which
-- backend opens and routes the chosen value. Distinct from the PURE
-- daylog.sources.picker (align / merge / display_for / should_query) it consumes.

-- Resolve a per-source config option (min_query, ttl) in one place. Returns nil for an
-- unconfigured / custom source -- the caller then applies its own default
-- (should_query clamps a nil min_query to 1; M.source falls back to a default ttl).
local function source_opt(name, key)
  if not name then
    return nil
  end
  local source_config = (config.get().sources or {})[name]
  return source_config and source_config[key] or nil
end

local DEFAULT_FRECENCY_DAYS = 30

-- Scan the last `days` daylogs for what you have logged (buffer-aware, so today's unsaved
-- entries count too) and build the daylog-usage map the frecency ranker keys on. Empty when no
-- daybook is configured.
local function daylog_usage(days)
  local settings = daybook_io.expanded_daybook_settings()
  if not settings then
    return {}
  end

  local lists = {}
  for _, date in ipairs(daybook.trailing_dates(os.time(), days)) do
    local lines = daybook_io.daybook_lines(daybook.path_for_date(settings, date))
    if lines then
      lists[#lists + 1] = { date = date, lines = lines }
    end
  end
  return rank.build_usage(lists, os.time())
end

-- Reorder a source's items so the ones you have recently logged lead -- the built-in
-- daylog-frecency ranker, or a user-supplied picker.rank. Source items only; with no
-- source (a candidate-only rename) or an empty list it is a no-op.
local function ranked(source, items)
  if not source or #items == 0 then
    return items
  end

  local picker = config.get().picker or {}
  local order = picker.rank or rank.order
  return order(items, {
    usage = daylog_usage(picker.frecency_days or DEFAULT_FRECENCY_DAYS),
    key_of = function(item)
      return entry.sanitize_text(source.to_entry_text(item))
    end,
    now = os.time(),
  })
end

-- Pick a source work-item to act on (insert). Telescope live-search when the source
-- supports it; otherwise the offline cache via vim.ui.select. Cancelling (a nil
-- choice / a wiped prompt) calls on_cancel.
--
-- opts: { source_name, initial_items, prompt, prompt_fallback,
--         on_pick = fn(item), on_cancel = fn()|nil }
function M.item(source, opts)
  local items = ranked(source, opts.initial_items or {})

  -- Telescope gives a nicer picker even cache-only, so prefer it whenever installed;
  -- live_pick wires the as-you-type server search only when the source provides one
  -- (it's off by default), so an offline source still gets the Telescope picker.
  if pcall(require, "telescope") then
    require("daylog.telescope").live_pick(source, {
      initial_items = items,
      prompt = opts.prompt,
      min_query = source_opt(opts.source_name, "min_query"),
      on_pick = opts.on_pick,
      on_cancel = opts.on_cancel,
    })
    return
  end

  vim.ui.select(items, {
    prompt = opts.prompt_fallback,
    format_item = sources_picker.display_for(source, items),
  }, function(choice)
    if not choice then
      if opts.on_cancel then
        opts.on_cancel()
      end
      return
    end
    opts.on_pick(choice)
  end)
end

-- Open the scoped picker for one named source (`:Daylog insert/:Daylog rename/:Daylog map <source>`):
-- load/refresh its cache, then hand its items to M.item -- which live-searches the tracker as you
-- type when the source supports it, else filters the offline cache. The chosen item goes to
-- opts.on_pick(item); cancelling calls opts.on_cancel. Items only; the unified pool (M.unified) is
-- where recent activities and type-a-name live.
--
-- opts: { prompt, prompt_fallback, on_pick = fn(item), on_cancel = fn()|nil }
function M.source(source, name, opts)
  local ttl = source_opt(name, "ttl") or 1800
  sources_sync.ensure_fresh(name, ttl, function(items)
    M.item(source, {
      source_name = name,
      initial_items = items,
      prompt = opts.prompt,
      prompt_fallback = opts.prompt_fallback,
      on_pick = opts.on_pick,
      on_cancel = opts.on_cancel,
    })
  end)
end

-- The general mixed-row picker (shared by :Daylog! insert, :Daylog rename, :Daylog map). Each row
-- carries `.display` and `.text` (what gets chosen). Telescope when installed, else vim.ui.select
-- with a type-new sentinel. Choosing a row yields its `.text`; <C-e> (Telescope) yields the typed
-- value via on_create; the type-new row (fallback) calls on_type_new. An empty row set calls
-- on_empty (the caller's prompt), else on_cancel; cancelling (nil / wiped prompt) calls on_cancel.
--
-- opts: { on_choose = fn(text), on_create = fn(typed), on_type_new = fn(), on_empty = fn()|nil,
--         on_cancel = fn()|nil, exclude = string|nil, prompt, prompt_fallback, type_new_label }
function M.choose(rows, opts)
  -- Drop the current value (rename's `exclude`) so a no-op "X -> X" is never offered.
  if opts.exclude ~= nil then
    local kept = {}
    for _, row in ipairs(rows) do
      if row.text ~= opts.exclude then
        kept[#kept + 1] = row
      end
    end
    rows = kept
  end

  if #rows == 0 then
    if opts.on_empty then
      opts.on_empty()
    elseif opts.on_cancel then
      opts.on_cancel()
    end
    return
  end

  if pcall(require, "telescope") then
    require("daylog.telescope").choose(rows, {
      prompt = opts.prompt,
      on_choose = opts.on_choose,
      on_create = opts.on_create,
      on_cancel = opts.on_cancel,
    })
    return
  end

  local TYPE_NEW = {}
  local choices = {}
  for _, row in ipairs(rows) do
    choices[#choices + 1] = row
  end
  choices[#choices + 1] = TYPE_NEW

  vim.ui.select(choices, {
    prompt = opts.prompt_fallback,
    format_item = function(choice)
      if choice == TYPE_NEW then
        return opts.type_new_label
      end
      return choice.display
    end,
  }, function(choice)
    if not choice then
      if opts.on_cancel then
        opts.on_cancel()
      end
      return
    end
    if choice == TYPE_NEW then
      opts.on_type_new()
      return
    end
    opts.on_choose(choice.text)
  end)
end

-- Build the unified pool from already-read source caches plus the recent daylog activities, rank
-- it (the same daylog frecency), and open the picker over it. `specs` = { { name, source,
-- items }, ... }. Every row carries the text it would be logged as (an item's to_entry_text, an
-- activity's text), so on_choose receives that directly. `opts` is passed through to M.choose.
function M.unified(specs, opts)
  local picker = config.get().picker or {}
  local usage = daylog_usage(picker.frecency_days or DEFAULT_FRECENCY_DAYS)

  local sources = {}
  for _, spec in ipairs(specs) do
    sources[#sources + 1] = {
      name = spec.name,
      items = spec.items,
      key_of = function(item)
        return entry.sanitize_text(spec.source.to_entry_text(item))
      end,
      display_for = sources_picker.display_for(spec.source, spec.items),
      text_of = function(item)
        return spec.source.to_entry_text(item)
      end,
    }
  end

  local rows = rank.build_insert_pool(sources, { usage = usage })
  M.choose(rows, opts)
end

return M
