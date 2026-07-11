local sources_registry = require("daylog.sources.registry")

local M = {}

-- Command surface (shell).
--
-- Everything about the :Daylog command -- argument parsing, completion, verb dispatch,
-- registration. Dispatch lazy-requires the init module on first use, so this stays cheap to
-- require at plugin load and never forms a require cycle.

-- Lazy so registering :Daylog does not pull buffer (and the core) until the command is used.
local function warn(message)
  require("daylog.buffer").warn(message)
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

local function day_token_complete(arglead)
  return prefix_matches(DAY_TOKENS, arglead)
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

-- :Daylog <verb> -- the single command's dispatch table, and the one place a verb is described:
-- verb -> { run, edit_only?, complete? }. run(api, ctx) reads its arguments from ctx and calls
-- the public api verb. Bang selects the verb's variant (insert -> unified picker, map -> clear,
-- report -> aggregate only); a range applies to map. Entry-point verbs work anywhere; verbs
-- flagged edit_only act on the current daylog buffer (and surface in completion only there).
-- complete(arglead, before) completes the verb's arguments.
local VERBS = {
  today = {
    run = function(api)
      api.today()
    end,
  },
  day = {
    complete = day_token_complete,
    run = function(api, ctx)
      api.day(ctx.fargs[1])
    end,
  },
  next = {
    run = function(api, ctx)
      local count, err = parse_step_count(ctx.fargs[1])
      if not count then
        warn(err)
        return
      end
      api.next_day(count)
    end,
  },
  prev = {
    run = function(api, ctx)
      local count, err = parse_step_count(ctx.fargs[1])
      if not count then
        warn(err)
        return
      end
      api.prev_day(count)
    end,
  },
  report = {
    complete = day_token_complete,
    run = function(api, ctx)
      api.report(ctx.rest, ctx.bang)
    end,
  },
  export = {
    complete = function(arglead, before)
      -- first argument is the format, then the (optional) range tokens
      if before:match("^export%s+%S+%s") then
        return prefix_matches(DAY_TOKENS, arglead)
      end
      return prefix_matches({ "csv", "json" }, arglead)
    end,
    run = function(api, ctx)
      -- Args after the format are the range, with an OPTIONAL trailing output path (path-shaped:
      -- contains a `/`, starts with `~`, or ends `.csv`/`.json`); everything before it is the range.
      local range = {}
      for i = 2, #ctx.fargs do
        range[#range + 1] = ctx.fargs[i]
      end
      local last = range[#range]
      local path
      if
        last
        and (
          last:find("/")
          or last:sub(1, 1) == "~"
          or last:match("%.csv$")
          or last:match("%.json$")
        )
      then
        path = table.remove(range)
      end
      api.export(ctx.fargs[1], table.concat(range, " "), path)
    end,
  },
  insert = {
    edit_only = true,
    complete = source_complete,
    run = function(api, ctx)
      api.insert({ source = ctx.fargs[1], pick = ctx.bang })
    end,
  },
  ["repeat"] = {
    edit_only = true,
    run = function(api)
      api.repeat_()
    end,
  },
  new = {
    edit_only = true,
    run = function(api)
      api.new_log()
    end,
  },
  copy = {
    edit_only = true,
    run = function(api)
      api.copy()
    end,
  },
  order = {
    edit_only = true,
    run = function(api)
      api.order()
    end,
  },
  log = {
    edit_only = true,
    run = function(api, ctx)
      if ctx.bang then
        api.unlog()
      else
        api.log()
      end
    end,
  },
  balance = {
    edit_only = true,
    run = function(api, ctx)
      api.balance(ctx.fargs[1])
    end,
  },
  split = {
    edit_only = true,
    run = function(api, ctx)
      api.split(ctx.fargs)
    end,
  },
  map = {
    edit_only = true,
    complete = source_complete,
    run = function(api, ctx)
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
  },
  rename = {
    edit_only = true,
    complete = source_complete,
    run = function(api, ctx)
      local kind = classify_source_arg(ctx.rest)
      api.rename({
        value = kind == "value" and ctx.rest or nil,
        source = kind == "source" and ctx.rest or nil,
        range = ctx.range,
      })
    end,
  },
  refresh = {
    edit_only = true,
    run = function(api)
      api.refresh()
    end,
  },
  migrate = {
    edit_only = true,
    run = function(api)
      api.migrate_logging()
    end,
  },
  sync = {
    complete = source_complete,
    run = function(api, ctx)
      api.sync(ctx.fargs[1])
    end,
  },
  keys = {
    run = function(api)
      api.keys()
    end,
  },
  bar = {
    edit_only = true,
    run = function(api)
      api.bar()
    end,
  },
}

-- Context-aware completion: the verb at the first argument (edit_only verbs only inside a daylog
-- buffer), then the verb's own argument completion -- date tokens for day/report, source names
-- for insert/sync/rename/map.
local function daylog_complete(arglead, cmdline, cursorpos)
  local before = cmdline:sub(1, cursorpos):gsub(".-Daylog!?%s*", "", 1)
  local verb = before:match("^(%S+)%s")

  if not verb then
    local in_daylog = vim.bo.filetype == "daylog"
    local verbs = {}
    for name, spec in pairs(VERBS) do
      if in_daylog or not spec.edit_only then
        verbs[#verbs + 1] = name
      end
    end
    return prefix_matches(verbs, arglead)
  end

  local spec = VERBS[verb]
  if spec and spec.complete then
    return spec.complete(arglead, before)
  end

  return {}
end

-- The verb names :Daylog dispatches, sorted -- derived from the dispatch table so a consumer
-- (:checkhealth) can never drift from what actually runs.
function M.verb_names()
  local names = {}
  for name in pairs(VERBS) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

-- Register the single :Daylog command. nvim_create_user_command replaces an existing definition,
-- so plugin load and setup() can both call it and a reload leaves no stale closure behind.
function M.register()
  -- Bare :Daylog opens today; :Daylog <verb> dispatches through VERBS; :Daylog! <verb> selects
  -- the verb's variant; a range applies to map.
  vim.api.nvim_create_user_command("Daylog", function(args)
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

    -- Fail soft: a command that raises (an out-of-range edit/cursor, an unexpected buffer state) warns
    -- instead of dumping a raw traceback at the user, matching how apply_refresh isolates its own edit.
    local ok, err = pcall(handler.run, api, verb_context(args))
    if not ok then
      warn("daylog: command failed: " .. tostring(err))
    end
  end, {
    nargs = "*",
    bang = true,
    range = true,
    complete = daylog_complete,
  })
end

return M
