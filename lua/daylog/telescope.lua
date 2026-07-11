local picker_helpers = require("daylog.sources.picker")

local M = {}

-- Optional Telescope live-search picker for daylog sources (shell + Telescope only).
--
-- Required lazily by init.lua, only when Telescope is installed. Typing fuzzy-filters the current
-- pool client-side; when the source supports `search`, a debounced server query augments the pool
-- with project-wide matches, via the shared live_search controller below.

local DEBOUNCE_MS = 250

-- The picker dims trailing item metadata (after the rendered name) so the name pops. Links to
-- Comment by default; re-set on each open (default = true) so it survives a colourscheme change.
local function ensure_meta_hl()
  vim.api.nvim_set_hl(0, "DaylogPickerMeta", { link = "Comment", default = true })
end

-- A Telescope entry display: a plain string, or a function dimming the trailing metadata range when
-- present. The ordinal stays the full line so fuzzy match still searches the metadata.
local function display_fn(display, text)
  local s, e = picker_helpers.meta_range(display, text)
  if not s then
    return display
  end
  return function()
    return display, { { { s, e }, "DaylogPickerMeta" } }
  end
end

-- Shared debounced live-search controller for the source-backed pickers.
--
-- Drives a debounced server search off Telescope's per-change input hook. Owns two guards:
-- `last_query` (a refresh re-fires the hook with the same prompt -- skip it, no loop) and `seq`
-- (drop stale responses), plus a `closed` flag so a late response stops refreshing after wipe.
-- The caller supplies `finder_for` and `initial`, sets `controller.picker`, wires
-- `on_input_filter_cb`, and calls `mark_closed` from BufWipeout.
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
              local message = err:match("^daylog:") and err or ("daylog: " .. err)
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
  ensure_meta_hl()

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local initial = opts.initial_items or {}

  -- Build a finder over `items`, aligning the pool into columns when the source supports it.
  local function finder_for(items)
    items = items or {}

    -- Resolve each display through the shared source contract, recomputed per finder so a growing
    -- pool re-aligns; the ordinal stays the full display so fuzzy matching sees every column.
    local display = picker_helpers.display_for(source, items)

    return finders.new_table({
      results = items,
      entry_maker = function(item)
        local line = display(item)
        return {
          value = item,
          display = display_fn(line, source.to_entry_text(item)),
          ordinal = line,
        }
      end,
    })
  end

  local controller = live_search(source, {
    min_query = opts.min_query,
    initial = initial,
    finder_for = finder_for,
    on_refresh = function(items, total)
      -- The source hydrates a bounded slice; if more matched, say so rather than silently truncating.
      if total and total > #items then
        vim.notify(
          string.format("daylog: showing first %d of %d matches; refine your search", #items, total),
          vim.log.levels.INFO
        )
      end
    end,
  })

  controller.picker = pickers.new(opts.theme or {}, {
    prompt_title = opts.prompt or "Daylog",
    finder = finder_for(initial),
    -- Client-side fuzzy filtering of the current pool (respects fzf-native).
    sorter = conf.generic_sorter({}),
    on_input_filter_cb = source.search and controller.on_input_filter_cb or nil,
    attach_mappings = function(prompt_bufnr, _)
      local picked = false

      -- Closing the prompt marks the picker done so a late search response stops refreshing;
      -- cancelling leaves a bare timestamp, matching :Daylog insert.
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
        -- On an empty results list get_selected_entry is nil; leave `picked` false so closing falls
        -- through to on_cancel (a bare timestamp) instead of silently dropping the insert.
        local entry = action_state.get_selected_entry()
        picked = entry ~= nil and entry.value ~= nil
        actions.close(prompt_bufnr)
        if picked and opts.on_pick then
          opts.on_pick(entry.value)
        end
      end)

      return true
    end,
  })

  controller.picker:find()
end

-- The general mixed-row picker (shared by :Daylog! insert, :Daylog rename, :Daylog map): pre-ranked
-- rows each carrying a `.text`. Offline. <CR> chooses the row's text, <C-e> (or <CR> with nothing
-- selected) yields the typed text, closing without a pick calls on_cancel.
--
-- opts: { on_choose = fn(text), on_create = fn(typed), on_cancel = fn()|nil, prompt = string|nil,
--         theme = table|nil }
function M.choose(rows, opts)
  ensure_meta_hl()

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local picker = pickers.new(opts.theme or {}, {
    prompt_title = opts.prompt or "Daylog  (<CR> pick, <C-e> type)",
    finder = finders.new_table({
      results = rows,
      entry_maker = function(row)
        return { value = row, display = display_fn(row.display, row.text), ordinal = row.display }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      local picked = false

      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = prompt_bufnr,
        once = true,
        callback = function()
          if opts.on_cancel and not picked then
            vim.schedule(opts.on_cancel)
          end
        end,
      })

      actions.select_default:replace(function()
        picked = true
        local entry = action_state.get_selected_entry()
        local typed = action_state.get_current_line()
        actions.close(prompt_bufnr)
        if entry and entry.value then
          opts.on_choose(entry.value.text)
        else
          opts.on_create(typed)
        end
      end)

      map({ "i", "n" }, "<C-e>", function()
        picked = true
        local typed = action_state.get_current_line()
        actions.close(prompt_bufnr)
        opts.on_create(typed)
      end)

      return true
    end,
  })

  picker:find()
end

-- Multi-select names picker (shared by `:Daylog log`'s mark). `rows` = { { display, name } }; the
-- synthetic "(unnamed)" row carries `name = ""` (the unnamed name, never nil), so selecting it alone
-- yields the set `{""}` -- "logged to no one", distinct from selecting nothing. <Tab> toggles a row and
-- advances; <CR> confirms the toggled set, else the highlighted row, else -- when the filter matched no
-- row -- the typed prompt as new, comma-separated name(s); <C-e> creates from the typed prompt, unioned
-- with the toggled set. Typing only filters -- it never creates implicitly while a row is available. An
-- invalid typed name warns and keeps the picker open. Names arrive at on_select deduped+sorted; closing
-- calls on_cancel. (The `name ~= nil` guards below are defensive; internal callers always set a string.)
--
-- opts: { on_select = fn(names), on_cancel = fn()|nil, prompt = string|nil, theme = table|nil }
function M.multi_select(rows, opts)
  ensure_meta_hl()

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local picker = pickers.new(opts.theme or {}, {
    prompt_title = opts.prompt or "Daylog names  (<CR> pick, <Tab> mark, <C-e> new)",
    finder = finders.new_table({
      results = rows,
      entry_maker = function(row)
        return { value = row, display = row.display, ordinal = row.display }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      local picked = false

      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = prompt_bufnr,
        once = true,
        callback = function()
          if opts.on_cancel and not picked then
            vim.schedule(opts.on_cancel)
          end
        end,
      })

      map({ "i", "n" }, "<Tab>", function()
        actions.toggle_selection(prompt_bufnr)
        actions.move_selection_next(prompt_bufnr)
      end)

      -- The current toggled rows' names, deduped. "(unnamed)" carries the empty name "", so toggling
      -- only it yields {""} (the unnamed slice) -- a deliberate choice, distinct from "nothing
      -- toggled" (which falls back to the highlighted row).
      local function toggled_names()
        local names, seen = {}, {}
        local multi = action_state.get_current_picker(prompt_bufnr):get_multi_selection()
        for _, entry in ipairs(multi) do
          local name = entry.value.name
          if name ~= nil and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
          end
        end
        return names, #multi > 0
      end

      local function confirm(names)
        picked = true
        actions.close(prompt_bufnr)
        table.sort(names)
        opts.on_select(names)
      end

      -- Parse the typed prompt as new name(s); invalid input warns and keeps the picker open.
      local function typed_names()
        local names, err = picker_helpers.parse_names_input(action_state.get_current_line())
        if not names then
          vim.notify(err, vim.log.levels.WARN)
        end
        return names
      end

      actions.select_default:replace(function()
        local names, any_toggled = toggled_names()

        if not any_toggled then
          local highlighted = action_state.get_selected_entry()
          if highlighted and highlighted.value then
            if highlighted.value.name ~= nil then
              names = { highlighted.value.name }
            end
          else
            -- The filter matched no row: the typed prompt is a request to create.
            local created = typed_names()
            if not created then
              return
            end
            names = created
          end
        end

        confirm(names)
      end)

      map({ "i", "n" }, "<C-e>", function()
        local created = typed_names()
        if not created then
          return
        end

        local names, seen = {}, {}
        for _, list in ipairs({ toggled_names(), created }) do
          for _, name in ipairs(list) do
            if not seen[name] then
              seen[name] = true
              names[#names + 1] = name
            end
          end
        end
        confirm(names)
      end)

      return true
    end,
  })

  picker:find()
end

return M
