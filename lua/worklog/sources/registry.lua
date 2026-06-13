local syntax = require("worklog.syntax")

local M = {}

-- Source registry and the source contract.
--
-- A source is a plain table { fetch, format_item, to_entry_text } that never
-- touches the Neovim API or the buffer. Built-in source types are instantiated
-- from declarative config (see worklog.config) by the shell, which injects an
-- async transport, a JSON codec, and a token resolver; the resulting source
-- objects (which hold functions) are registered here for lookup by name.

local registered = {}

-- Built-in source types: declarative `type` -> the module exposing `new`.
-- Required lazily in instantiate so a provider can require this module (for
-- sanitize_text) without a load-time cycle.
local BUILTIN_TYPES = {
  azure_devops = "worklog.sources.azure_devops",
}

local CONTRACT = { "fetch", "format_item", "to_entry_text" }

local function is_dangerous_token(token)
  if token == syntax.TAG_CLEAR_TOKEN or token == syntax.LOCATION_CLEAR_TOKEN then
    return true
  end

  if token:match("^#[%w_%-]+$") or token:match("^@[%w_%-]+$") then
    return true
  end

  return token == syntax.LOGGED_TOKEN
end

-- Make `text` safe to drop into "HH:MM <text>" so it can never grow trailing
-- metadata. The entry parser peels metadata by scanning whitespace tokens from
-- the end while they are control tokens (#tag, @loc, #-, @-, !L); we wrap each
-- token in the trailing run of such tokens in parentheses so the scan stops at a
-- plain word. Mid-text tokens (e.g. "fix #flaky tests") are left untouched -- a
-- following plain word already stops the scan, and they read better unwrapped.
function M.sanitize_text(text)
  text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    return text
  end

  local tokens = {}
  for token in text:gmatch("%S+") do
    table.insert(tokens, token)
  end

  for i = #tokens, 1, -1 do
    if is_dangerous_token(tokens[i]) then
      tokens[i] = "(" .. tokens[i] .. ")"
    else
      break
    end
  end

  return table.concat(tokens, " ")
end

-- Instantiate a built-in source from a normalized config entry, injecting deps
-- (transport, json, token_resolver) and validating the contract. Returns the
-- source object or nil plus an error message.
function M.instantiate(name, source_config, deps)
  local module_name = BUILTIN_TYPES[source_config.type]
  if not module_name then
    return nil,
      "worklog: source '" .. name .. "' has unknown type '" .. tostring(source_config.type) .. "'"
  end

  local ok, source = pcall(function()
    return require(module_name).new(name, source_config, deps)
  end)
  if not ok then
    return nil, "worklog: source '" .. name .. "' failed to initialize: " .. tostring(source)
  end

  if type(source) ~= "table" then
    return nil, "worklog: source '" .. name .. "' did not return a source object"
  end

  for _, fn in ipairs(CONTRACT) do
    if type(source[fn]) ~= "function" then
      return nil, "worklog: source '" .. name .. "' is missing " .. fn
    end
  end

  return source
end

-- Register a ready source object under a name. Used by the shell for built-ins
-- and by users registering a custom source object directly.
function M.register(name, source)
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
