local M = {}

-- Optional Telescope live-search picker for worklog sources.
--
-- Shell + Telescope only; this module is never required by the core at load.
-- init.lua requires it lazily, and only when Telescope is installed and the
-- source implements `search`. The chosen item is handed to opts.on_pick (a
-- cancelled picker calls opts.on_cancel); the actual buffer edit still happens in
-- init.lua through the pure insert_entry usecase.
--
-- Typing fuzzy-filters the current pool client-side (generic_sorter). When the
-- source supports `search`, a debounced server query augments the pool with
-- project-wide matches so you can reach items beyond the cached set.

local DEBOUNCE_MS = 250

-- opts: { on_pick = fn(item), on_cancel = fn()|nil, initial_items = table|nil,
--         prompt = string|nil, theme = table|nil }
function M.live_pick(source, opts)
  opts = opts or {}

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local picker_helpers = require("worklog.sources.picker")

  local initial = opts.initial_items or {}

  local function entry_maker(item)
    local display = source.format_item(item)
    return { value = item, display = display, ordinal = display }
  end

  local function finder_for(items)
    return finders.new_table({ results = items or {}, entry_maker = entry_maker })
  end

  local picker
  local seq = 0
  local last_query = nil

  -- Telescope's input hook fires on every prompt change. Use it to drive a
  -- debounced server search; client-side filtering is the sorter's job. Guard with
  -- last_query (a refresh re-fires this with the same prompt -> skip; no loop) and
  -- seq (drop stale responses).
  local function on_input_filter_cb(prompt)
    if source.search and picker_helpers.should_query(prompt, last_query, opts.min_query) then
      last_query = prompt
      seq = seq + 1
      local mine = seq

      vim.defer_fn(function()
        if mine ~= seq then
          return
        end

        source.search(prompt, function(items, err, total)
          vim.schedule(function()
            if mine ~= seq or not picker then
              return
            end
            if err then
              local message = err:match("^worklog:") and err or ("worklog: " .. err)
              vim.notify(message, vim.log.levels.WARN)
              return
            end
            if items then
              picker:refresh(
                finder_for(picker_helpers.merge(initial, items)),
                { reset_prompt = false }
              )
              -- The source hydrates a bounded slice; if more matched, say so rather
              -- than silently showing a truncated set.
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
            end
          end)
        end)
      end, DEBOUNCE_MS)
    end

    return { prompt = prompt }
  end

  picker = pickers.new(opts.theme or {}, {
    prompt_title = opts.prompt or "Worklog",
    finder = finder_for(initial),
    -- Client-side fuzzy filtering of the current pool (respects fzf-native).
    sorter = conf.generic_sorter({}),
    on_input_filter_cb = on_input_filter_cb,
    attach_mappings = function(prompt_bufnr, _)
      local picked = false

      -- Bare-timestamp fallback on cancel, matching :WorklogInsert.
      if opts.on_cancel then
        vim.api.nvim_create_autocmd("BufWipeout", {
          buffer = prompt_bufnr,
          once = true,
          callback = function()
            vim.schedule(function()
              if not picked then
                opts.on_cancel()
              end
            end)
          end,
        })
      end

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

  picker:find()
end

return M
