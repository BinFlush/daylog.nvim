local buffer = require("daylog.buffer")
local sources_registry = require("daylog.sources.registry")

local M = {}

-- Command surface (shell).
--
-- Gathers everything about the user-facing commands -- argument parsing, source-name
-- completion, and the :Daylog* / :Daylog* registrations -- in one place. register(api)
-- wires the thin handlers to the public verbs on `api` (the init module's M), which
-- is passed in to avoid a require cycle.

local warn = buffer.warn

local function ensure_user_command(name, callback, options)
  if vim.fn.exists(":" .. name) == 2 then
    return
  end

  vim.api.nvim_create_user_command(name, callback, options or {})
end

local function parse_positive_integer(value)
  if type(value) ~= "string" or value:match("^%d+$") == nil then
    return nil, "daylog: days count must be a positive integer"
  end

  local number = tonumber(value)
  if number == nil or number <= 0 then
    return nil, "daylog: days count must be a positive integer"
  end

  return number
end

-- An optional positive day-step count; an empty argument defaults to 1.
local function parse_step_count(value)
  if value == nil or value == "" then
    return 1
  end

  return parse_positive_integer(value)
end

local function parse_day_offset(value)
  if value == nil or value == "" then
    return 0
  end

  if type(value) ~= "string" or value:match("^[+-]?%d+$") == nil then
    return nil, "daylog: day offset must be an integer"
  end

  local number = tonumber(value)
  if number == nil then
    return nil, "daylog: day offset must be an integer"
  end

  return number
end

-- Command-line completion over configured source names (first argument only).
local function source_complete(arglead)
  local matches = {}
  for _, name in ipairs(sources_registry.names()) do
    if name:sub(1, #arglead) == arglead then
      table.insert(matches, name)
    end
  end
  return matches
end

-- Register a command whose single optional argument is parsed, warned-on, then
-- dispatched. `parse(args.args) -> value | nil, err`; on a successful (non-nil) parse
-- `dispatch(value)` runs, else the error is warned. The day-navigation commands share
-- this shape -- the `== nil` check (not `not value`) keeps a 0 day-offset from being
-- swallowed.
local function register_parsed_command(name, parse, dispatch)
  ensure_user_command(name, function(args)
    local value, err = parse(args.args)
    if value == nil then
      warn(err)
      return
    end

    dispatch(value)
  end, {
    nargs = "?",
  })
end

-- Register every :Daylog* / :Daylog* command, wiring its thin handler to the public
-- verb on `api` (the init module's M).
function M.register(api)
  ensure_user_command("DaylogInsert", function(args)
    local name = args.fargs[1]
    if not name then
      api.insert_now()
      return
    end

    api.insert_from_source(name)
  end, {
    nargs = "?",
    complete = function(arglead)
      return source_complete(arglead)
    end,
  })

  register_parsed_command("DaylogToday", parse_day_offset, api.open_today)
  register_parsed_command("DaylogInit", parse_day_offset, api.init_day)
  register_parsed_command("DaylogNextDay", parse_step_count, api.open_relative_day)
  register_parsed_command("DaylogPrevDay", parse_step_count, function(count)
    api.open_relative_day(-count)
  end)

  ensure_user_command("DaylogWeek", function(args)
    api.open_week(args.bang)
  end, {
    bang = true,
  })

  ensure_user_command("DaylogDays", function(args)
    local count, err = parse_positive_integer(args.args)
    if not count then
      warn(err)
      return
    end

    api.open_days(count, args.bang)
  end, {
    bang = true,
    nargs = 1,
  })

  ensure_user_command("DaylogRepeat", function()
    api.repeat_current()
  end)

  -- A lone argument that names a configured source opens the picker against that
  -- source (to replace an activity with a work item); any other argument is the new
  -- value to rename to directly; no argument opens the picker.
  ensure_user_command("DaylogRename", function(args)
    local arg = args.args
    if arg ~= "" and sources_registry.get(arg) then
      api.rename_summary(nil, arg)
    elseif arg ~= "" then
      api.rename_summary(arg)
    else
      api.rename_summary()
    end
  end, {
    nargs = "*",
    complete = source_complete,
  })

  ensure_user_command("DaylogOrder", function()
    api.order_logs()
  end)

  ensure_user_command("DaylogCopy", function()
    api.append_copy()
  end)

  ensure_user_command("DaylogLog", function()
    api.log_current()
  end)

  ensure_user_command("DaylogBalance", function(args)
    api.balance(args.args)
  end, {
    nargs = "?",
  })

  ensure_user_command("DaylogSplit", function(args)
    api.split(args.fargs)
  end, {
    nargs = "*",
  })

  ensure_user_command("DaylogRefresh", function()
    api.refresh()
  end)

  ensure_user_command("DaylogSync", function(args)
    api.sync_source(args.fargs[1])
  end, {
    nargs = "?",
    complete = function(arglead)
      return source_complete(arglead)
    end,
  })
end

return M
