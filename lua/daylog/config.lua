local syntax = require("daylog.syntax")

local M = {}

local current = {
  defaults = {},
  auto_summary = "change",
  active_indicator = true,
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

local function positive_integer(value)
  return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function normalize_defaults(defaults)
  if defaults == nil then
    return {}
  end

  if type(defaults) ~= "table" then
    error("daylog: setup defaults must be a table")
  end

  local result = {}

  if defaults.tag ~= nil then
    if not is_metadata_value(defaults.tag) then
      error("daylog: defaults.tag must use only letters, digits, underscores, or hyphens")
    end

    result.tag = defaults.tag
  end

  if defaults.location ~= nil then
    if not is_metadata_value(defaults.location) then
      error("daylog: defaults.location must use only letters, digits, underscores, or hyphens")
    end

    result.location = defaults.location
  end

  if defaults.quantize_minutes ~= nil then
    if not positive_integer(defaults.quantize_minutes) then
      error("daylog: defaults.quantize_minutes must be a positive integer")
    end

    result.quantize_minutes = defaults.quantize_minutes
  end

  if defaults.duration_format ~= nil then
    if not is_duration_format(defaults.duration_format) then
      error("daylog: defaults.duration_format must be dec or hm")
    end

    result.duration_format = defaults.duration_format
  end

  -- The base UTC offset auto-filled into a new log header (for travellers who
  -- always want a zone stamped). Either a signed offset string ("+2", "-4",
  -- "+5:30"), stored as signed minutes, or the literal "auto" -- a sentinel the
  -- shell resolves to the system offset at file-creation time. Absent -> no header
  -- offset, so non-travellers are unaffected.
  if defaults.utc ~= nil then
    if defaults.utc == "auto" then
      result.utc = "auto"
    elseif type(defaults.utc) == "string" then
      local minutes = syntax.parse_offset_value(defaults.utc)
      if minutes == nil then
        error('daylog: defaults.utc must be "auto" or a signed offset like "+2", "-4", "+5:30"')
      end
      result.utc = minutes
    else
      error('daylog: defaults.utc must be "auto" or a signed offset string')
    end
  end

  return result
end

local function normalize_daybook(daybook)
  if daybook == nil then
    return nil
  end

  if type(daybook) ~= "table" then
    error("daylog: setup daybook must be a table")
  end

  if type(daybook.root) ~= "string" or daybook.root == "" then
    error("daylog: daybook.root must be a non-empty string")
  end

  if daybook.directory ~= nil and type(daybook.directory) ~= "string" then
    error("daylog: daybook.directory must be a string")
  end

  return {
    root = daybook.root,
    directory = daybook.directory or "",
  }
end

-- Automatic summary refresh trigger: `change` (debounced as you type, the
-- default), `idle` (on pause / leaving insert), `save`, or `off` (manual only).
-- `false` aliases `off`; an unset value defaults to `change` so every log's
-- summary stays live.
local function normalize_auto_summary(value)
  if value == nil then
    return "change"
  end

  if value == false or value == "off" then
    return "off"
  end

  if type(value) ~= "string" or not AUTO_SUMMARY_MODES[value] then
    error("daylog: auto_summary must be one of off, change, idle, save")
  end

  return value
end

-- The soft-green sign-column bar marking the active log + summary. On by default;
-- an unset value stays on, so the marker appears whenever a file has 2+ logs.
local function normalize_active_indicator(value)
  if value == nil then
    return true
  end

  if type(value) ~= "boolean" then
    error("daylog: active_indicator must be a boolean")
  end

  return value
end

local SOURCE_DEFAULT_TTL = 1800
local SOURCE_DEFAULT_TEMPLATE = "{id} {title}"
local SOURCE_DEFAULT_MIN_QUERY = 3
-- A generous sanity cap: a single WIQL filters all listed projects, so an
-- unreasonably long list risks Azure DevOps' query-size limit. Use a saved
-- query/query_id for larger sets.
local SOURCE_MAX_PROJECTS = 100

local function normalize_azure_devops(name, entry)
  local function required_string(field)
    local value = entry[field]
    if type(value) ~= "string" or value == "" then
      error("daylog: source '" .. name .. "'." .. field .. " must be a non-empty string")
    end
    return value
  end

  local result = {
    organization = required_string("organization"),
  }

  -- A source targets a single `project` (project-scoped requests) or a `projects`
  -- list (organization-scoped, filtered to those team projects) -- exactly one.
  if entry.project ~= nil and entry.projects ~= nil then
    error("daylog: source '" .. name .. "' must not set both project and projects")
  elseif entry.projects ~= nil then
    if type(entry.projects) ~= "table" or #entry.projects == 0 then
      error("daylog: source '" .. name .. "'.projects must be a non-empty list of strings")
    end
    if #entry.projects > SOURCE_MAX_PROJECTS then
      error(
        "daylog: source '"
          .. name
          .. "' has too many projects (max "
          .. SOURCE_MAX_PROJECTS
          .. "); use a saved query or raw WIQL instead"
      )
    end
    local projects = {}
    for _, project in ipairs(entry.projects) do
      if type(project) ~= "string" or project == "" then
        error("daylog: source '" .. name .. "'.projects must be a non-empty list of strings")
      end
      projects[#projects + 1] = project
    end
    result.projects = projects
  elseif entry.project ~= nil then
    result.project = required_string("project")
  else
    error("daylog: source '" .. name .. "' must set 'project' or 'projects'")
  end

  -- The PAT is a function so it is resolved lazily at fetch time and never stored
  -- as plaintext in setup{} or a config dump. It is never called during setup.
  if type(entry.token) ~= "function" then
    error("daylog: source '" .. name .. "'.token must be a function")
  end
  result.token = entry.token

  if entry.query ~= nil and entry.query_id ~= nil then
    error("daylog: source '" .. name .. "' must not set both query and query_id")
  end

  if entry.query ~= nil then
    if type(entry.query) ~= "string" or entry.query == "" then
      error("daylog: source '" .. name .. "'.query must be a non-empty string")
    end
    result.query = entry.query
  end

  if entry.query_id ~= nil then
    if type(entry.query_id) ~= "string" or entry.query_id == "" then
      error("daylog: source '" .. name .. "'.query_id must be a non-empty string")
    end
    result.query_id = entry.query_id
  end

  -- A custom query/query_id carries its own scope (and a saved query is itself
  -- project-scoped), so it can't be combined with a cross-project `projects` list.
  if result.projects ~= nil and (result.query ~= nil or result.query_id ~= nil) then
    error("daylog: source '" .. name .. "' cannot combine projects with query or query_id")
  end

  if entry.api_version ~= nil then
    if type(entry.api_version) ~= "string" or entry.api_version == "" then
      error("daylog: source '" .. name .. "'.api_version must be a non-empty string")
    end
    result.api_version = entry.api_version
  else
    result.api_version = "7.0"
  end

  if entry.format_item ~= nil then
    if type(entry.format_item) ~= "function" then
      error("daylog: source '" .. name .. "'.format_item must be a function")
    end
    result.format_item = entry.format_item
  end

  -- Live as-you-type tracker search is off by default (the offline cache is the
  -- picker); opt in per source. Picking stays offline either way -- only an enabled
  -- search reaches the network on each keystroke.
  if entry.search ~= nil then
    if type(entry.search) ~= "boolean" then
      error("daylog: source '" .. name .. "'.search must be a boolean")
    end
    result.search = entry.search
  end

  return result
end

local SOURCE_TYPES = {
  azure_devops = normalize_azure_devops,
}

local function normalize_source(name, entry)
  if type(entry) ~= "table" then
    error("daylog: source '" .. name .. "' must be a table")
  end

  local normalize_type = type(entry.type) == "string" and SOURCE_TYPES[entry.type]
  if not normalize_type then
    error("daylog: source '" .. name .. "' has unknown type")
  end

  local result = normalize_type(name, entry)
  result.type = entry.type

  if entry.ttl ~= nil then
    if not positive_integer(entry.ttl) then
      error("daylog: source '" .. name .. "'.ttl must be a positive integer")
    end
    result.ttl = entry.ttl
  else
    result.ttl = SOURCE_DEFAULT_TTL
  end

  if entry.template ~= nil then
    if type(entry.template) ~= "string" or entry.template == "" then
      error("daylog: source '" .. name .. "'.template must be a non-empty string")
    end
    result.template = entry.template
  else
    result.template = SOURCE_DEFAULT_TEMPLATE
  end

  -- Minimum prompt length before a live search hits the network; shorter prompts
  -- only filter the cached pool. Set to 1 for search-on-first-keystroke.
  if entry.min_query ~= nil then
    if not positive_integer(entry.min_query) then
      error("daylog: source '" .. name .. "'.min_query must be a positive integer")
    end
    result.min_query = entry.min_query
  else
    result.min_query = SOURCE_DEFAULT_MIN_QUERY
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
    error("daylog: setup sources must be a table")
  end

  local result = {}

  for name, entry in pairs(sources) do
    if type(name) ~= "string" or name:match("^[%w_%-]+$") == nil then
      error("daylog: source names must use only letters, digits, underscores, or hyphens")
    end

    result[name] = normalize_source(name, entry)
  end

  return result
end

-- Cross-source picker behavior (not per-source): how a source's cached items are ranked
-- in the picker. `rank` overrides the built-in worklog-frecency ranker (same signature,
-- fn(items, ctx) -> items); `frecency_days` is the daybook look-back window the ranker
-- scans (default applied at use time).
local function normalize_picker(picker)
  if picker == nil then
    return nil
  end

  if type(picker) ~= "table" then
    error("daylog: setup picker must be a table")
  end

  local result = {}

  if picker.rank ~= nil then
    if type(picker.rank) ~= "function" then
      error("daylog: picker.rank must be a function")
    end
    result.rank = picker.rank
  end

  if picker.frecency_days ~= nil then
    if not positive_integer(picker.frecency_days) then
      error("daylog: picker.frecency_days must be a positive integer")
    end
    result.frecency_days = picker.frecency_days
  end

  return result
end

local function normalize_config(options)
  if options == nil then
    return {
      defaults = {},
      auto_summary = "change",
      active_indicator = true,
    }
  end

  if type(options) ~= "table" then
    error("daylog: setup options must be a table")
  end

  local result = {
    defaults = normalize_defaults(options.defaults),
    auto_summary = normalize_auto_summary(options.auto_summary),
    active_indicator = normalize_active_indicator(options.active_indicator),
  }

  local daybook = normalize_daybook(options.daybook)
  if daybook ~= nil then
    result.daybook = daybook
  end

  local sources = normalize_sources(options.sources)
  if sources ~= nil then
    result.sources = sources
  end

  local picker = normalize_picker(options.picker)
  if picker ~= nil then
    result.picker = picker
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
