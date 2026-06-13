local syntax = require("worklog.syntax")

local M = {}

local current = {
  defaults = {},
  auto_summary = "change",
}

local AUTO_SUMMARY_MODES = {
  off = true,
  change = true,
  idle = true,
  save = true,
}

local function is_metadata_value(value)
  return type(value) == "string" and value:match("^[%w_%-]+$") ~= nil
end

local function is_duration_format(value)
  return syntax.DURATION_FORMATS[value] == true
end

local function normalize_defaults(defaults)
  if defaults == nil then
    return {}
  end

  if type(defaults) ~= "table" then
    error("worklog: setup defaults must be a table")
  end

  local result = {}

  if defaults.tag ~= nil then
    if not is_metadata_value(defaults.tag) then
      error("worklog: defaults.tag must use only letters, digits, underscores, or hyphens")
    end

    result.tag = defaults.tag
  end

  if defaults.location ~= nil then
    if not is_metadata_value(defaults.location) then
      error("worklog: defaults.location must use only letters, digits, underscores, or hyphens")
    end

    result.location = defaults.location
  end

  if defaults.quantize_minutes ~= nil then
    if
      type(defaults.quantize_minutes) ~= "number"
      or defaults.quantize_minutes <= 0
      or defaults.quantize_minutes ~= math.floor(defaults.quantize_minutes)
    then
      error("worklog: defaults.quantize_minutes must be a positive integer")
    end

    result.quantize_minutes = defaults.quantize_minutes
  end

  if defaults.duration_format ~= nil then
    if not is_duration_format(defaults.duration_format) then
      error("worklog: defaults.duration_format must be dec or hm")
    end

    result.duration_format = defaults.duration_format
  end

  return result
end

local function normalize_journal(journal)
  if journal == nil then
    return nil
  end

  if type(journal) ~= "table" then
    error("worklog: setup journal must be a table")
  end

  if type(journal.root) ~= "string" or journal.root == "" then
    error("worklog: journal.root must be a non-empty string")
  end

  if journal.directory ~= nil and type(journal.directory) ~= "string" then
    error("worklog: journal.directory must be a string")
  end

  return {
    root = journal.root,
    directory = journal.directory or "",
  }
end

-- Automatic summary refresh trigger: `change` (debounced as you type, the
-- default), `idle` (on pause / leaving insert), `save`, or `off` (manual only).
-- `false` aliases `off`; an unset value defaults to `change` so every worklog's
-- summary stays live.
local function normalize_auto_summary(value)
  if value == nil then
    return "change"
  end

  if value == false or value == "off" then
    return "off"
  end

  if type(value) ~= "string" or not AUTO_SUMMARY_MODES[value] then
    error("worklog: auto_summary must be one of off, change, idle, save")
  end

  return value
end

local SOURCE_DEFAULT_TTL = 1800
local SOURCE_DEFAULT_TEMPLATE = "{id} {title}"

local function normalize_azure_devops(name, entry)
  local function required_string(field)
    local value = entry[field]
    if type(value) ~= "string" or value == "" then
      error("worklog: source '" .. name .. "'." .. field .. " must be a non-empty string")
    end
    return value
  end

  local result = {
    organization = required_string("organization"),
    project = required_string("project"),
  }

  -- The PAT is a function so it is resolved lazily at fetch time and never stored
  -- as plaintext in setup{} or a config dump. It is never called during setup.
  if type(entry.token) ~= "function" then
    error("worklog: source '" .. name .. "'.token must be a function")
  end
  result.token = entry.token

  if entry.query ~= nil and entry.query_id ~= nil then
    error("worklog: source '" .. name .. "' must not set both query and query_id")
  end

  if entry.query ~= nil then
    if type(entry.query) ~= "string" or entry.query == "" then
      error("worklog: source '" .. name .. "'.query must be a non-empty string")
    end
    result.query = entry.query
  end

  if entry.query_id ~= nil then
    if type(entry.query_id) ~= "string" or entry.query_id == "" then
      error("worklog: source '" .. name .. "'.query_id must be a non-empty string")
    end
    result.query_id = entry.query_id
  end

  if entry.api_version ~= nil then
    if type(entry.api_version) ~= "string" or entry.api_version == "" then
      error("worklog: source '" .. name .. "'.api_version must be a non-empty string")
    end
    result.api_version = entry.api_version
  else
    result.api_version = "7.0"
  end

  if entry.format_item ~= nil then
    if type(entry.format_item) ~= "function" then
      error("worklog: source '" .. name .. "'.format_item must be a function")
    end
    result.format_item = entry.format_item
  end

  return result
end

local SOURCE_TYPES = {
  azure_devops = normalize_azure_devops,
}

local function normalize_source(name, entry)
  if type(entry) ~= "table" then
    error("worklog: source '" .. name .. "' must be a table")
  end

  local normalize_type = type(entry.type) == "string" and SOURCE_TYPES[entry.type]
  if not normalize_type then
    error("worklog: source '" .. name .. "' has unknown type")
  end

  local result = normalize_type(name, entry)
  result.type = entry.type

  if entry.ttl ~= nil then
    if type(entry.ttl) ~= "number" or entry.ttl <= 0 or entry.ttl ~= math.floor(entry.ttl) then
      error("worklog: source '" .. name .. "'.ttl must be a positive integer")
    end
    result.ttl = entry.ttl
  else
    result.ttl = SOURCE_DEFAULT_TTL
  end

  if entry.template ~= nil then
    if type(entry.template) ~= "string" or entry.template == "" then
      error("worklog: source '" .. name .. "'.template must be a non-empty string")
    end
    result.template = entry.template
  else
    result.template = SOURCE_DEFAULT_TEMPLATE
  end

  return result
end

-- Optional external work-item sources, keyed by a name used as a command
-- argument and cache filename. Each entry declares a built-in `type` plus its
-- per-type fields; omitted entirely when no sources are configured.
local function normalize_sources(sources)
  if sources == nil then
    return nil
  end

  if type(sources) ~= "table" then
    error("worklog: setup sources must be a table")
  end

  local result = {}

  for name, entry in pairs(sources) do
    if type(name) ~= "string" or name:match("^[%w_%-]+$") == nil then
      error("worklog: source names must use only letters, digits, underscores, or hyphens")
    end

    result[name] = normalize_source(name, entry)
  end

  return result
end

local function normalize_config(options)
  if options == nil then
    return {
      defaults = {},
      auto_summary = "change",
    }
  end

  if type(options) ~= "table" then
    error("worklog: setup options must be a table")
  end

  local result = {
    defaults = normalize_defaults(options.defaults),
    auto_summary = normalize_auto_summary(options.auto_summary),
  }

  local journal = normalize_journal(options.journal)
  if journal ~= nil then
    result.journal = journal
  end

  local sources = normalize_sources(options.sources)
  if sources ~= nil then
    result.sources = sources
  end

  return result
end

function M.setup(options)
  current = normalize_config(options)
end

function M.get()
  return current
end

return M
