local config = require("daylog.config")
local daybook = require("daylog.daybook")
local daybook_io = require("daylog.daybook_io")
local entry = require("daylog.entry")
local rank = require("daylog.sources.rank")
local sources_picker = require("daylog.sources.picker")

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

-- Resolve a per-source config option (min_query) in one place. Returns nil for an
-- unconfigured / custom source -- the backend then applies its own default
-- (should_query clamps a nil min_query to 1).
local function source_opt(name, key)
  if not name then
    return nil
  end
  local source_config = (config.get().sources or {})[name]
  return source_config and source_config[key] or nil
end

local DEFAULT_FRECENCY_DAYS = 30
local DEFAULT_HALF_LIFE_DAYS = 7
local DEFAULT_BASE = 30

-- Scan the last `days` daylogs for what you have logged time against (buffer-aware, so
-- today's unsaved entries count too) and build the time-decayed worklog-usage map the ranker
-- keys on. Empty when no daybook is configured.
local function worklog_usage(days, half_life)
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
  return rank.build_usage(lists, os.time(), half_life)
end

-- Reorder a source's items so the ones you have recently logged lead -- the built-in
-- worklog-frecency ranker, or a user-supplied picker.rank. Source items only; with no
-- source (a candidate-only rename) or an empty list it is a no-op.
local function ranked(source, items)
  if not source or #items == 0 then
    return items
  end

  local picker = config.get().picker or {}
  local order = picker.rank or rank.order
  return order(items, {
    usage = worklog_usage(
      picker.frecency_days or DEFAULT_FRECENCY_DAYS,
      picker.half_life_days or DEFAULT_HALF_LIFE_DAYS
    ),
    key_of = function(item)
      return entry.sanitize_text(source.to_entry_text(item))
    end,
    base = picker.base or DEFAULT_BASE,
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

-- Pick a value for rename / map: a local merge candidate, a source work-item, or a
-- freshly typed name (<C-e> in Telescope, the "type new" row in the fallback).
-- Telescope when installed, else vim.ui.select over candidates + items + a type-new
-- sentinel (items aligned via the source display contract). With nothing but the
-- type-new row, the input prompt opens directly.
--
-- opts: { candidates = string[], source = table|nil, source_name, initial_items,
--         prompt, prompt_fallback, type_new_label,
--         on_pick = fn(text), on_create = fn(text), on_pick_item = fn(item)|nil,
--         on_type_new = fn() }
function M.rename(opts)
  local candidates = opts.candidates or {}
  local source = opts.source
  local items = ranked(source, opts.initial_items or {})

  if pcall(require, "telescope") then
    require("daylog.telescope").rename_pick({
      candidates = candidates,
      prompt = opts.prompt,
      on_pick = opts.on_pick,
      on_create = opts.on_create,
      source = source,
      initial_items = items,
      min_query = source_opt(opts.source_name, "min_query"),
      on_pick_item = opts.on_pick_item,
    })
    return
  end

  local TYPE_NEW = {}
  local choices = {}
  for _, value in ipairs(candidates) do
    choices[#choices + 1] = value
  end
  if source then
    for _, item in ipairs(items) do
      choices[#choices + 1] = item
    end
  end
  choices[#choices + 1] = TYPE_NEW

  -- Nothing to choose but "type a new name": go straight to the input prompt.
  if #choices == 1 then
    opts.on_type_new()
    return
  end

  local display = source and sources_picker.display_for(source, items) or nil

  vim.ui.select(choices, {
    prompt = opts.prompt_fallback,
    format_item = function(choice)
      if choice == TYPE_NEW then
        return opts.type_new_label
      end
      if type(choice) == "table" then
        return display(choice)
      end
      return choice
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice == TYPE_NEW then
      opts.on_type_new()
      return
    end
    if type(choice) == "table" then
      opts.on_pick_item(choice)
      return
    end
    opts.on_pick(choice)
  end)
end

return M
