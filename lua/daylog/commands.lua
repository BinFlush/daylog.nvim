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

-- Parse the :Daylog report argument into a normalized request: a trailing day count, or a
-- FROM..TO range (each side a YYYY-MM-DD string; an omitted side becomes nil, resolved
-- later to the earliest logged day or today). The date strings are validated downstream.
local function parse_days_request(value)
  if type(value) == "string" and value:match("^%d+$") then
    local count, err = parse_positive_integer(value)
    if not count then
      return nil, err
    end
    return { count = count }
  end

  local from, to = (value or ""):match("^(.-)%.%.(.-)$")
  if from then
    return {
      from = from ~= "" and from or nil,
      to = to ~= "" and to or nil,
    }
  end

  return nil,
    "daylog: expected a day count or a FROM..TO range (e.g. 2026-05-10..2026-05-20, monday.., ..today)"
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

-- Classify a command argument the source-aware way :Daylog rename and :Daylog map share:
-- "source" when it names a configured source (open that source's picker), "value" for any
-- other non-empty argument (act on it directly), or "none" for no argument (default picker).
local function classify_source_arg(arg)
  if arg == "" then
    return "none"
  end
  if sources_registry.get(arg) then
    return "source"
  end
  return "value"
end

-- :Daylog <verb> -- the single command. Entry-point verbs work anywhere; editing verbs act on
-- the current daylog buffer (and surface in completion only there).
local ENTRY_VERBS = { "today", "day", "next", "prev", "report", "sync" }
local EDIT_VERBS = {
  "insert",
  "repeat",
  "new",
  "copy",
  "order",
  "log",
  "balance",
  "split",
  "map",
  "rename",
  "refresh",
}

-- Date tokens completion offers for `day`/`report` arguments (signed +N/-N offsets and
-- YYYY-MM-DD literals are typed, not completed).
local DAY_TOKENS = {
  "today",
  "yesterday",
  "tomorrow",
  "monday",
  "tuesday",
  "wednesday",
  "thursday",
  "friday",
  "saturday",
  "sunday",
}

local function prefix_matches(candidates, arglead)
  local matches = {}
  for _, candidate in ipairs(candidates) do
    if candidate:sub(1, #arglead) == arglead then
      table.insert(matches, candidate)
    end
  end
  table.sort(matches)
  return matches
end

-- Context-aware completion: the verb at the first argument (editing verbs only inside a daylog
-- buffer), then per-verb argument completion -- date tokens for day/report, source names for
-- insert/sync/rename/map.
local function daylog_complete(arglead, cmdline, cursorpos)
  local before = cmdline:sub(1, cursorpos):gsub(".-Daylog!?%s*", "", 1)
  local verb = before:match("^(%S+)%s")

  if not verb then
    local verbs = vim.list_extend({}, ENTRY_VERBS)
    if vim.bo.filetype == "daylog" then
      vim.list_extend(verbs, EDIT_VERBS)
    end
    return prefix_matches(verbs, arglead)
  end

  if verb == "day" or verb == "report" then
    return prefix_matches(DAY_TOKENS, arglead)
  elseif verb == "insert" or verb == "sync" or verb == "rename" or verb == "map" then
    return source_complete(arglead)
  end

  return {}
end

-- Split :Daylog's raw arguments into a verb context: fargs (the verb word dropped), rest (the
-- raw remainder, for values that may contain spaces -- map/rename/report), the bang, and a
-- visual range when one was given.
local function verb_context(args)
  local fargs = {}
  for index = 2, #args.fargs do
    fargs[#fargs + 1] = args.fargs[index]
  end

  return {
    fargs = fargs,
    rest = (args.args:gsub("^%s*%S+%s*", "")),
    bang = args.bang,
    range = args.range > 0 and { args.line1, args.line2 } or nil,
  }
end

-- verb -> handler(api, ctx). Each handler reads its arguments from ctx and calls the public api
-- verb. Bang selects the verb's variant (insert -> unified picker, map -> clear, report ->
-- aggregate only); a range applies to map.
local VERBS = {
  today = function(api)
    api.today()
  end,
  day = function(api, ctx)
    api.day(ctx.fargs[1])
  end,
  next = function(api, ctx)
    local count, err = parse_step_count(ctx.fargs[1])
    if not count then
      warn(err)
      return
    end
    api.next_day(count)
  end,
  prev = function(api, ctx)
    local count, err = parse_step_count(ctx.fargs[1])
    if not count then
      warn(err)
      return
    end
    api.prev_day(count)
  end,
  report = function(api, ctx)
    api.report(ctx.rest, ctx.bang)
  end,
  insert = function(api, ctx)
    api.insert({ source = ctx.fargs[1], pick = ctx.bang })
  end,
  ["repeat"] = function(api)
    api.repeat_()
  end,
  new = function(api)
    api.new_log()
  end,
  copy = function(api)
    api.copy()
  end,
  order = function(api)
    api.order()
  end,
  log = function(api)
    api.log()
  end,
  balance = function(api, ctx)
    api.balance(ctx.fargs[1])
  end,
  split = function(api, ctx)
    api.split(ctx.fargs)
  end,
  map = function(api, ctx)
    if ctx.bang then
      api.map({ clear = true, range = ctx.range })
      return
    end
    local kind = classify_source_arg(ctx.rest)
    api.map({
      value = kind == "value" and ctx.rest or nil,
      source = kind == "source" and ctx.rest or nil,
      range = ctx.range,
    })
  end,
  rename = function(api, ctx)
    local kind = classify_source_arg(ctx.rest)
    api.rename({
      value = kind == "value" and ctx.rest or nil,
      source = kind == "source" and ctx.rest or nil,
    })
  end,
  refresh = function(api)
    api.refresh()
  end,
  sync = function(api, ctx)
    api.sync(ctx.fargs[1])
  end,
}

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
  -- The single :Daylog <verb> command (bare :Daylog opens today). Dispatches through VERBS; the
  -- per-verb :Daylog* commands below are transitional and retire after the test migration.
  ensure_user_command("Daylog", function(args)
    local verb = args.fargs[1]
    if not verb then
      api.today()
      return
    end

    local handler = VERBS[verb]
    if not handler then
      warn("daylog: unknown verb '" .. verb .. "' -- try :Daylog <Tab>")
      return
    end

    handler(api, verb_context(args))
  end, {
    nargs = "*",
    bang = true,
    range = true,
    complete = daylog_complete,
  })

  ensure_user_command("DaylogInsert", function(args)
    if args.bang then
      api.insert_unified()
      return
    end

    local name = args.fargs[1]
    if not name then
      api.insert_now()
      return
    end

    api.insert_from_source(name)
  end, {
    bang = true,
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

  ensure_user_command("DaylogDays", function(args)
    local request, err = parse_days_request(args.args)
    if not request then
      warn(err)
      return
    end

    api.report(request, args.bang)
  end, {
    bang = true,
    nargs = 1,
  })

  ensure_user_command("DaylogRepeat", function()
    api.repeat_()
  end)

  -- A lone argument that names a configured source opens the unified picker (recent activities +
  -- every source's items) to rename into; any other argument is the new value to rename to
  -- directly; no argument opens the picker.
  ensure_user_command("DaylogRename", function(args)
    local kind = classify_source_arg(args.args)
    if kind == "source" then
      api.rename_summary(nil, args.args)
    elseif kind == "value" then
      api.rename_summary(args.args)
    else
      api.rename_summary()
    end
  end, {
    nargs = "*",
    complete = source_complete,
  })

  -- Map the cursor's entry (or every entry of a summary row) to a label it resolves to
  -- in the summary. A lone argument that names a configured source opens the unified picker; any
  -- other argument is the label to map to directly; no argument opens the picker/prompt.
  -- The bang (`:Daylog! map`) clears the mapping instead.
  ensure_user_command("DaylogMap", function(args)
    -- A visual selection (or :N,M) supplies a line range; a bare :Daylog map has range == 0
    -- and maps the cursor entry / summary row as before.
    local range = args.range > 0 and { args.line1, args.line2 } or nil

    if args.bang then
      api.map_clear(range)
      return
    end

    local kind = classify_source_arg(args.args)
    if kind == "source" then
      api.map_summary(nil, args.args, range)
    elseif kind == "value" then
      api.map_summary(args.args, nil, range)
    else
      api.map_summary(nil, nil, range)
    end
  end, {
    nargs = "*",
    bang = true,
    range = true,
    complete = source_complete,
  })

  ensure_user_command("DaylogOrder", function()
    api.order()
  end)

  ensure_user_command("DaylogCopy", function()
    api.copy()
  end)

  ensure_user_command("DaylogNew", function()
    api.new_log()
  end)

  ensure_user_command("DaylogLog", function()
    api.log()
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
    api.sync(args.fargs[1])
  end, {
    nargs = "?",
    complete = function(arglead)
      return source_complete(arglead)
    end,
  })
end

return M
