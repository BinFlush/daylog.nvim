local M = {}

local current = {
  defaults = {},
}

local function is_metadata_value(value)
  return type(value) == "string" and value:match("^[%w_%-]+$") ~= nil
end

local function is_duration_format(value)
  return value == "decimal" or value == "hhmm"
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
      error("worklog: defaults.duration_format must be decimal or hhmm")
    end

    result.duration_format = defaults.duration_format
  end

  return result
end

local function normalize_config(options)
  if options == nil then
    return {
      defaults = {},
    }
  end

  if type(options) ~= "table" then
    error("worklog: setup options must be a table")
  end

  return {
    defaults = normalize_defaults(options.defaults),
  }
end

function M.setup(options)
  current = normalize_config(options)
end

function M.get()
  return current
end

return M
