local picker_helpers = require("worklog.sources.picker")

local M = {}

-- Optional Telescope live-search picker for worklog sources.
--
-- Shell + Telescope only; this module is never required by the core at load.
-- init.lua requires it lazily, and only when Telescope is installed (and, for
-- live_pick, the source implements `search`). The chosen item is handed to the
-- caller's callbacks; the actual buffer edit still happens in init.lua through the
-- pure insert_entry / rename usecases.
--
-- Typing fuzzy-filters the current pool client-side (generic_sorter). When the
-- source supports `search`, a debounced server query augments the pool with
-- project-wide matches so you can reach items beyond the cached set -- driven by the
-- shared live_search controller below, used by both pickers.

local DEBOUNCE_MS = 250

-- Shared debounced live-search controller for the source-backed pickers.
--
-- Telescope's input hook fires on every prompt change; this drives a debounced
-- server search off it (client-side filtering stays the sorter's job). It owns the
-- two guards that keep that safe -- `last_query` (a refresh re-fires the hook with
-- the same prompt, so skip it; no loop) and `seq` (drop stale responses) -- plus a
-- `closed` flag so a late response stops refreshing once the prompt is wiped.
--
-- The caller supplies `finder_for` (build a finder from an item pool) and `initial`
-- (the cached/default pool merged with each server result), sets `controller.picker`
-- once the picker is built, wires `on_input_filter_cb`, and calls `mark_closed` from
-- the prompt's BufWipeout. `on_refresh(items, total)` is an optional post-refresh
-- hook (live_pick's truncation notice).
local function live_search(source, opts)
  local controller = { picker = nil }
  local seq = 0
  local last_query = nil
  local closed = false

  function controller.mark_closed()
    closed = true
  end

  function controller.on_input_filter_cb(prompt)
    if picker_helpers.should_query(prompt, last_query, opts.min_query) then
      last_query = prompt
      seq = seq + 1
      local mine = seq

      vim.defer_fn(function()
        if mine ~= seq then
          return
        end

        source.search(prompt, function(items, err, total)
          vim.schedule(function()
            if mine ~= seq or not controller.picker or closed then
              return
            end
            if err then
              local message = err:match("^worklog:") and err or ("worklog: " .. err)
              vim.notify(message, vim.log.levels.WARN)
              return
            end
            if items then
              controller.picker:refresh(
                opts.finder_for(picker_helpers.merge(opts.initial, items)),
                { reset_prompt = false }
              )
              if opts.on_refresh then
                opts.on_refresh(items, total)
              end
            end
          end)
        end)
      end, DEBOUNCE_MS)
    end

    return { prompt = prompt }
  end

  return controller
end

-- opts: { on_pick = fn(item), on_cancel = fn()|nil, initial_items = table|nil,
--         prompt = string|nil, theme = table|nil, min_query = number|nil }
function M.live_pick(source, opts)
  opts = opts or {}

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local initial = opts.initial_items or {}

  -- Build a finder over `items`, aligning the whole pool into columns when the
  -- source supports it (so the type/state and other trailing columns line up
  -- despite differing title lengths). The alignment is recomputed per finder, so a
  -- live-search refresh that grows the pool re-aligns to the new widths. The
  -- ordinal stays the full display so fuzzy matching still sees every column.
  local function finder_for(items)
    items = items or {}

    -- Resolve each item's display through the shared source display contract
    -- (aligned columns when the source supports it). Recomputed per finder so a
    -- live-search refresh that grows the pool re-aligns to the new widths; the
    -- ordinal stays the full display so fuzzy matching still sees every column.
    local display = picker_helpers.display_for(source, items)

    return finders.new_table({
      results = items,
      entry_maker = function(item)
        local line = display(item)
        return { value = item, display = line, ordinal = line }
      end,
    })
  end

  local controller = live_search(source, {
    min_query = opts.min_query,
    initial = initial,
    finder_for = finder_for,
    on_refresh = function(items, total)
      -- The source hydrates a bounded slice; if more matched, say so rather than
      -- silently showing a truncated set.
      if total and total > #items then
        vim.notify(
          string.format(
            "worklog: showing first %d of %d matches; refine your search",
            #items,
            total
          ),
          vim.log.levels.INFO
        )
      end
    end,
  })

  controller.picker = pickers.new(opts.theme or {}, {
    prompt_title = opts.prompt or "Worklog",
    finder = finder_for(initial),
    -- Client-side fuzzy filtering of the current pool (respects fzf-native).
    sorter = conf.generic_sorter({}),
    on_input_filter_cb = source.search and controller.on_input_filter_cb or nil,
    attach_mappings = function(prompt_bufnr, _)
      local picked = false

      -- Closing the prompt (pick or cancel) marks the picker done so a late search
      -- response stops refreshing/notifying. Cancelling also leaves a bare timestamp,
      -- matching :WorklogInsert.
      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = prompt_bufnr,
        once = true,
        callback = function()
          controller.mark_closed()
          if opts.on_cancel and not picked then
            vim.schedule(opts.on_cancel)
          end
        end,
      })

      actions.select_default:replace(function()
        picked = true
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry and entry.value and opts.on_pick then
          opts.on_pick(entry.value)
        end
      end)

      return true
    end,
  })

  controller.picker:find()
end

-- A picker for :WorklogRename's merge UX, optionally augmented with a source's
-- work-items so an activity can be replaced with a tracked item (see init.lua).
-- Type to filter the existing same-kind values (tags / locations / activities) and,
-- when `source` is given, its work-items too; <CR> renames into the highlighted one
-- -- a merge for a local candidate, or the item's entry text for a source item --
-- and <C-e> renames to the typed text (a fresh name). With a searchable source a
-- debounced server query augments the pool, exactly like live_pick (the shared
-- live_search controller). The actual rename is the same pure usecase regardless of
-- where the value came from.
--
-- opts: { candidates = string[], prompt = string|nil, on_pick = fn(value),
--         on_create = fn(text), theme = table|nil,
--         source = table|nil, initial_items = table|nil, min_query = number|nil,
--         on_pick_item = fn(item)|nil }
function M.rename_pick(opts)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local source = opts.source
  local candidates = opts.candidates or {}
  local initial = opts.initial_items or {}

  -- Local merge candidates first, then the source's work-items (aligned into
  -- columns when the source supports it). Each entry remembers its kind so the
  -- select action knows whether to merge a name or replace with an item's text.
  local function entries_for(items)
    local entries = {}
    for _, candidate in ipairs(candidates) do
      entries[#entries + 1] = { kind = "candidate", text = candidate, display = candidate }
    end
    if source and items and #items > 0 then
      local display = picker_helpers.display_for(source, items)
      for _, item in ipairs(items) do
        entries[#entries + 1] = { kind = "item", item = item, display = display(item) }
      end
    end
    return entries
  end

  local function finder_for(items)
    return finders.new_table({
      results = entries_for(items),
      entry_maker = function(entry)
        return { value = entry, display = entry.display, ordinal = entry.display }
      end,
    })
  end

  local controller = live_search(source, {
    min_query = opts.min_query,
    initial = initial,
    finder_for = finder_for,
  })

  controller.picker = pickers.new(opts.theme or {}, {
    prompt_title = opts.prompt or "Worklog: rename / merge  (<CR> pick, <C-e> new name)",
    finder = finder_for(initial),
    sorter = conf.generic_sorter({}),
    on_input_filter_cb = (source and source.search) and controller.on_input_filter_cb or nil,
    attach_mappings = function(prompt_bufnr, map)
      -- A late search response must stop refreshing once the prompt closes.
      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = prompt_bufnr,
        once = true,
        callback = controller.mark_closed,
      })

      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        local typed = action_state.get_current_line()
        actions.close(prompt_bufnr)
        if entry and entry.value then
          local value = entry.value
          if value.kind == "item" and opts.on_pick_item then
            opts.on_pick_item(value.item)
          else
            opts.on_pick(value.text)
          end
        else
          opts.on_create(typed)
        end
      end)

      map({ "i", "n" }, "<C-e>", function()
        local typed = action_state.get_current_line()
        actions.close(prompt_bufnr)
        opts.on_create(typed)
      end)

      return true
    end,
  })

  controller.picker:find()
end

return M
