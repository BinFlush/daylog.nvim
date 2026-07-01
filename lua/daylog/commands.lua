local sources_registry = require("daylog.sources.registry")

local M = {}

-- Command surface (shell).
--
-- Gathers everything about the :Daylog command -- argument parsing, source-name completion,
-- the verb dispatch, and registration -- in one place. register() defines the command; its
-- dispatch lazy-requires the init module (the public verbs) on first use, so this module stays
-- cheap to require at plugin load (to register :Daylog) and never forms a require cycle.

-- Lazy so requiring this module to register :Daylog does not pull buffer (and the core through
-- it) until the command is actually used.
local function warn(message)
  require("daylog.buffer").warn(message)
end

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
local ENTRY_VERBS = { "today", "day", "next", "prev", "report", "export", "sync", "keys" }
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
  "migrate",
  "bar",
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
  elseif verb == "export" then
    -- first argument is the format, then the (optional) range tokens
    if before:match("^export%s+%S+%s") then
      return prefix_matches(DAY_TOKENS, arglead)
    end
    return prefix_matches({ "csv", "json" }, arglead)
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
  export = function(api, ctx)
    -- ctx.rest is "<format> <range...>"; split the format word off the range.
    api.export(ctx.fargs[1], (ctx.rest:gsub("^%s*%S+%s*", "")))
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
      range = ctx.range,
    })
  end,
  refresh = function(api)
    api.refresh()
  end,
  migrate = function(api)
    api.migrate_logging()
  end,
  sync = function(api, ctx)
    api.sync(ctx.fargs[1])
  end,
  keys = function(api)
    api.keys()
  end,
  bar = function(api)
    api.bar()
  end,
}

-- Register the single :Daylog command. Idempotent (the exists-guard), so both plugin load and
-- setup() can call it. The dispatch lazy-requires the init module on first invocation, so the
-- command is available the moment the plugin loads without pulling the implementation at startup.
function M.register()
  -- Bare :Daylog opens today; :Daylog <verb> dispatches through VERBS; :Daylog! <verb> selects
  -- the verb's variant; a range applies to map.
  ensure_user_command("Daylog", function(args)
    local api = require("daylog")
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
end

return M
