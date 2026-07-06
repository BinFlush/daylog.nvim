local M = {}

-- Source registry and the source contract (PURE).
-- A source is a plain table { fetch, format_item, format_items?, to_entry_text, search? } that never
-- touches the Neovim API. The shell instantiates built-ins from config (injecting transport, json,
-- token_resolver) and registers them; custom sources register directly via M.register. Source
-- conventions (fetch semantics, per-source scope overrides) are documented in docs/integrations.md.

-- The core consumes only id (cache/rank), active, and updated (rank); type/state/url are display, and a
-- source may carry extra domain fields (e.g. azure_devops adds `project`).
---@class DaylogItem
---@field id string|number Stable work-item id (required). Cache-dedup key and daylog-ranking key.
---@field title string Work-item title (required).
---@field type? string e.g. "Bug"/"Task" (optional; shown in the picker).
---@field state? string Raw status name (optional; shown in the picker).
---@field active? boolean Normalized "open/working", from the tracker's status *category* so ranking
---  ignores custom workflow names (optional).
---@field updated? string ISO-8601 last-updated timestamp (optional). Generic recency signal; lexically orderable.
---@field url? string Link to the item in the tracker (optional).

---@class DaylogSource
---@field fetch fun(cb: fun(items: DaylogItem[]|nil, err: string|nil)) Async: the default item set.
---@field format_item fun(item: DaylogItem): string Display line for the picker.
---@field format_items? fun(items: DaylogItem[]): string[] Optional: aligned display lines for the whole list.
---@field to_entry_text fun(item: DaylogItem): string Inserted activity text (sanitized automatically at insert).
---@field search? fun(query: string, cb: fun(items: DaylogItem[]|nil, err: string|nil)) Optional live search.

local registered = {}

-- Built-in source types: `type` -> module exposing `new`; required lazily to avoid a load-time cycle.
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

-- Instantiate a built-in source from config, injecting deps and validating the contract; returns the
-- source or nil plus an error message.
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

-- Register a ready source under a name, validating the contract so a malformed source fails loudly here.
---@param name string
---@param source DaylogSource
function M.register(name, source)
  local err = validate(name, source)
  if err then
    -- Level 0: the message is already user-facing; a position prefix would only obscure it.
    error(err, 0)
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
