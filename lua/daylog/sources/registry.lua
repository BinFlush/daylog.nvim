local M = {}

-- Source registry and the source contract.
--
-- A source is a plain table { fetch, format_item, format_items?, to_entry_text,
-- search? } that never touches the Neovim API or the buffer. Built-in source types are
-- instantiated from declarative config (see log.config) by the shell, which
-- injects an async transport, a JSON codec, and a token resolver; the resulting
-- source objects (which hold functions) are registered here for lookup by name.
-- Custom (third-party) sources are registered directly via M.register.
--
-- Conventions (documented, not enforced -- see docs/integrations.md for the why):
--   * fetch returns YOUR RELEVANT WORK -- the broadest reasonable "involves me"
--     (assigned/created/mentioned/watching, as the API allows) that is active and
--     recently updated, container-optional (org-wide where supported, so a project/team
--     restructure cannot silently drop work), ordered newest-first and capped.
--   * Scope overrides are the source's OWN config (a WIQL/JQL string, a saved-query id,
--     a search string, a GraphQL filter) -- there is intentionally no generic cross-source
--     "query" or "saved_query" knob, because query languages and saved queries are not
--     universal (Linear/GraphQL has no string DSL; GitHub/Linear expose no saved-query id).
--   * search is optional: the offline cache + client-side fuzzy is the primary picker.

-- The core only consumes id (cache/rank), active, and updated (rank); type/state/url are
-- for display, and a source may carry its own extra domain fields (e.g. azure_devops adds
-- `project`) for its format_item/template.
---@class DaylogItem
---@field id string|number Stable work-item id (required). Cache-dedup key and worklog-ranking key.
---@field title string Work-item title (required).
---@field type? string e.g. "Bug"/"Task" (optional; shown in the picker).
---@field state? string Raw status name (optional; shown in the picker).
---@field active? boolean Normalized "open/working" -- NOT done/closed/cancelled (optional). Derive
---  it from the tracker's status *category* so ranking/filtering ignores custom workflow names.
---@field updated? string ISO-8601 last-updated timestamp (optional). Generic recency signal; lexically orderable.
---@field url? string Link to the item in the tracker (optional).

---@class DaylogSource
---@field fetch fun(cb: fun(items: DaylogItem[]|nil, err: string|nil)) Async: the default item set.
---@field format_item fun(item: DaylogItem): string Display line for the picker.
---@field format_items? fun(items: DaylogItem[]): string[] Optional: aligned display lines for the whole list.
---@field to_entry_text fun(item: DaylogItem): string Inserted activity text (sanitized automatically at insert).
---@field search? fun(query: string, cb: fun(items: DaylogItem[]|nil, err: string|nil)) Optional live search.

local registered = {}

-- Built-in source types: declarative `type` -> the module exposing `new`.
-- Required lazily in instantiate to avoid a load-time cycle.
local BUILTIN_TYPES = {
  azure_devops = "daylog.sources.azure_devops",
}

local CONTRACT = { "fetch", "format_item", "to_entry_text" }

-- Validate a source object against the contract; returns an error message or nil.
local function validate(name, source)
  if type(source) ~= "table" then
    return "daylog: source '" .. name .. "' must be a table"
  end

  for _, fn in ipairs(CONTRACT) do
    if type(source[fn]) ~= "function" then
      return "daylog: source '" .. name .. "' is missing " .. fn
    end
  end

  if source.search ~= nil and type(source.search) ~= "function" then
    return "daylog: source '" .. name .. "'.search must be a function"
  end

  if source.format_items ~= nil and type(source.format_items) ~= "function" then
    return "daylog: source '" .. name .. "'.format_items must be a function"
  end

  return nil
end

-- Instantiate a built-in source from a normalized config entry, injecting deps
-- (transport, json, token_resolver) and validating the contract. Returns the
-- source object or nil plus an error message.
function M.instantiate(name, source_config, deps)
  local module_name = BUILTIN_TYPES[source_config.type]
  if not module_name then
    return nil,
      "daylog: source '" .. name .. "' has unknown type '" .. tostring(source_config.type) .. "'"
  end

  local ok, source = pcall(function()
    return require(module_name).new(name, source_config, deps)
  end)
  if not ok then
    return nil, "daylog: source '" .. name .. "' failed to initialize: " .. tostring(source)
  end

  local err = validate(name, source)
  if err then
    return nil, err
  end

  return source
end

-- Register a ready source object under a name. Used by the shell for built-ins and
-- by users registering a custom source directly. Validates the contract so a
-- malformed source fails loudly here rather than at use time.
---@param name string
---@param source DaylogSource
function M.register(name, source)
  local err = validate(name, source)
  if err then
    error(err)
  end

  registered[name] = source
end

function M.get(name)
  return registered[name]
end

function M.names()
  local names = {}
  for name in pairs(registered) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

function M.clear()
  registered = {}
end

return M
