local M = {}

-- Source registry and the source contract.
--
-- A source is a plain table { fetch, format_item, format_items?, to_blot_text,
-- search? } that never touches the Neovim API or the buffer. Built-in source types are
-- instantiated from declarative config (see blotter.config) by the shell, which
-- injects an async transport, a JSON codec, and a token resolver; the resulting
-- source objects (which hold functions) are registered here for lookup by name.
-- Custom (third-party) sources are registered directly via M.register.

---@class BlotterItem
---@field id string|number Stable work-item id (required).
---@field title string Work-item title (required).
---@field type? string e.g. "Bug"/"Task" (optional; shown in the picker).
---@field state? string e.g. "Active"/"Closed" (optional; shown in the picker).
---@field url? string Link to the item in the tracker (optional).

---@class BlotterSource
---@field fetch fun(cb: fun(items: BlotterItem[]|nil, err: string|nil)) Async: the default item set.
---@field format_item fun(item: BlotterItem): string Display line for the picker.
---@field format_items? fun(items: BlotterItem[]): string[] Optional: aligned display lines for the whole list.
---@field to_blot_text fun(item: BlotterItem): string Inserted activity text (sanitized automatically at insert).
---@field search? fun(query: string, cb: fun(items: BlotterItem[]|nil, err: string|nil)) Optional live search.

local registered = {}

-- Built-in source types: declarative `type` -> the module exposing `new`.
-- Required lazily in instantiate to avoid a load-time cycle.
local BUILTIN_TYPES = {
  azure_devops = "blotter.sources.azure_devops",
}

local CONTRACT = { "fetch", "format_item", "to_blot_text" }

-- Validate a source object against the contract; returns an error message or nil.
local function validate(name, source)
  if type(source) ~= "table" then
    return "blotter: source '" .. name .. "' must be a table"
  end

  for _, fn in ipairs(CONTRACT) do
    if type(source[fn]) ~= "function" then
      return "blotter: source '" .. name .. "' is missing " .. fn
    end
  end

  if source.search ~= nil and type(source.search) ~= "function" then
    return "blotter: source '" .. name .. "'.search must be a function"
  end

  if source.format_items ~= nil and type(source.format_items) ~= "function" then
    return "blotter: source '" .. name .. "'.format_items must be a function"
  end

  return nil
end

-- Instantiate a built-in source from a normalized config blot, injecting deps
-- (transport, json, token_resolver) and validating the contract. Returns the
-- source object or nil plus an error message.
function M.instantiate(name, source_config, deps)
  local module_name = BUILTIN_TYPES[source_config.type]
  if not module_name then
    return nil,
      "blotter: source '" .. name .. "' has unknown type '" .. tostring(source_config.type) .. "'"
  end

  local ok, source = pcall(function()
    return require(module_name).new(name, source_config, deps)
  end)
  if not ok then
    return nil, "blotter: source '" .. name .. "' failed to initialize: " .. tostring(source)
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
---@param source BlotterSource
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
