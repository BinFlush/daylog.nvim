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
-- Chooses between the optional Telescope backend (lazy-required when installed) and the
-- vim.ui.select fallback. Owns no buffer edits -- the caller's callbacks do the work. Distinct
-- from the PURE daylog.sources.picker (align / merge / display_for / should_query) it consumes.

-- Resolve a per-source config option (min_query, ttl). Returns nil for an unconfigured/custom
-- source, so the caller applies its own default.
local function source_opt(name, key)
  if not name then
    return nil
  end
  local source_config = (config.get().sources or {})[name]
  return source_config and source_config[key] or nil
end

local DEFAULT_FRECENCY_DAYS = 30

-- Read the last `days` daylogs (buffer-aware, so today's unsaved entries count) as
-- `{ date, lines }` lists. nil when no daybook is configured.
local function trailing_day_lists(days)
  local settings = daybook_io.expanded_daybook_settings()
  if not settings then
    return nil
  end

  local lists = {}
  for _, date in ipairs(daybook.trailing_dates(os.time(), days)) do
    local lines = daybook_io.daybook_lines(daybook.path_for_date(settings, date))
    if lines then
      lists[#lists + 1] = { date = date, lines = lines }
    end
  end
  return lists
end

-- The daylog-usage map the frecency ranker keys on. Empty when no daybook is configured.
local function daylog_usage(days)
  local lists = trailing_day_lists(days)
  if not lists then
    return {}
  end
  return rank.build_usage(lists, os.time())
end

-- The corpus of previously-used logging names at `level`, frecency-ranked into `{ name, score }`
-- rows (excluding the synthetic "(unnamed)", which the picker layer adds). The CURRENT buffer's
-- active log is always a source -- keyed by its daybook date, else today -- so names in the log you
-- are editing are offered even with no daybook, before a save, or for an out-of-tree `.day` file; the
-- trailing daybook history adds cross-day names, minus the current buffer's own day (already covered).
function M.name_corpus(level)
  local picker = config.get().picker or {}
  local settings = daybook_io.expanded_daybook_settings()
  local buffer_date = settings and daybook_io.current_buffer_daybook_date(settings)

  local lists = {
    { date = buffer_date or os.time(), lines = vim.api.nvim_buf_get_lines(0, 0, -1, false) },
  }
  for _, day in ipairs(trailing_day_lists(picker.frecency_days or DEFAULT_FRECENCY_DAYS) or {}) do
    if not (buffer_date and daybook.same_date(day.date, buffer_date)) then
      lists[#lists + 1] = day
    end
  end

  return sources_picker.name_corpus_rows(rank.build_name_usage(lists, os.time())[level] or {})
end

-- Reorder a source's items by the built-in daylog-frecency ranker, or a user-supplied
-- picker.rank. No source (candidate-only rename) or an empty list is a no-op.
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

-- Pick a source work-item (insert). Telescope live-search when supported, else the offline cache
-- via vim.ui.select. Cancelling calls on_cancel.
--
-- opts: { source_name, initial_items, prompt, prompt_fallback,
--         on_pick = fn(item), on_cancel = fn()|nil }
function M.item(source, opts)
  local items = ranked(source, opts.initial_items or {})

  -- Prefer Telescope whenever installed (nicer even cache-only); live_pick wires server search
  -- only when the source provides one, so an offline source still gets the Telescope picker.
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

-- Open the scoped picker for one named source: load/refresh its cache, then hand items to M.item.
-- Items only; the unified pool (M.unified) holds recent activities and type-a-name.
--
-- opts: { prompt, prompt_fallback, on_pick = fn(item), on_cancel = fn()|nil }
function M.source(source, name, opts)
  local ttl = source_opt(name, "ttl") or config.SOURCE_DEFAULT_TTL
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

-- The general mixed-row picker (:Daylog! insert, :Daylog rename, :Daylog map). Each row carries
-- `.display` and `.text`. Choosing a row yields its `.text`; <C-e> (Telescope) yields the typed
-- value via on_create; the type-new row (fallback) calls on_type_new. An empty set calls on_empty
-- else on_cancel; cancelling calls on_cancel.
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

-- Build the unified pool from source caches plus recent daylog activities, rank it (daylog
-- frecency), and open the picker. `specs` = { { name, source, items }, ... }; every row carries
-- the text it would be logged as, so on_choose receives that directly. `opts` passes to M.choose.
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

-- The logging-names picker for `:Daylog log` when it MARKS a row. Offers the `level`'s
-- previously-used names (frecency-ranked) with a synthetic "(unnamed)" first. Telescope gives a
-- Tab-multi-select picker (<C-e> creates from the typed prompt); otherwise a comma-separated
-- `vim.fn.input` mirrors the on-disk `[a,b]` grammar. Selected names are deduped+sorted before
-- on_select.
--
-- opts: { on_select = fn(names_list), on_cancel = fn()|nil }.
function M.pick_names(level, opts)
  local corpus = M.name_corpus(level)

  if pcall(require, "telescope") then
    local rows = { { display = "(unnamed)", name = "" } }
    for _, item in ipairs(corpus) do
      rows[#rows + 1] = { display = item.name, name = item.name }
    end
    require("daylog.telescope").multi_select(rows, {
      prompt = "Daylog: log names  (<CR> pick, <Tab> mark, <C-e> new)",
      on_select = opts.on_select,
      on_cancel = opts.on_cancel,
    })
    return
  end

  local input = vim.fn.input({
    prompt = "daylog: log names (comma-separated, empty for unnamed): ",
  })
  local names, err = sources_picker.parse_names_input(input)
  if not names then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  -- Empty input is the unnamed name (""), not a no-op: :Daylog log always adds something.
  if #names == 0 then
    names = { "" }
  end
  opts.on_select(names)
end

-- A picker over an explicit list of `names` (no frecency corpus, no `(unnamed)`), for choosing which
-- of a logged row's names to unlog. An empty pick cancels.
-- opts: { on_select = fn(names_list), on_cancel = fn()|nil }.
function M.pick_names_from(names, opts)
  if pcall(require, "telescope") then
    local rows = {}
    for _, name in ipairs(names) do
      rows[#rows + 1] = { display = name ~= "" and name or "(unnamed)", name = name }
    end
    require("daylog.telescope").multi_select(rows, {
      prompt = "Daylog: unlog names  (<CR> pick, <Tab> mark)",
      on_select = opts.on_select,
      on_cancel = opts.on_cancel,
    })
    return
  end

  local input = vim.fn.input({
    prompt = "daylog: names to unlog (comma-separated, empty to cancel): ",
  })
  local chosen, err = sources_picker.parse_names_input(input)
  if not chosen then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  if #chosen == 0 then
    if opts.on_cancel then
      opts.on_cancel()
    end
    return
  end
  opts.on_select(chosen)
end

return M
