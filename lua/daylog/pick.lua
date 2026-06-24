local config = require("daylog.config")
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

-- Pick a source work-item to act on (insert). Telescope live-search when the source
-- supports it; otherwise the offline cache via vim.ui.select. Cancelling (a nil
-- choice / a wiped prompt) calls on_cancel.
--
-- opts: { source_name, initial_items, prompt, prompt_fallback,
--         on_pick = fn(item), on_cancel = fn()|nil }
function M.item(source, opts)
  local items = opts.initial_items or {}

  -- live_pick wires its server search only when the source can search; a
  -- non-searchable source has no reason to prefer it over plain vim.ui.select, so
  -- gate on both (the historical condition, kept verbatim).
  if pcall(require, "telescope") and source.search then
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
  local items = opts.initial_items or {}

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
