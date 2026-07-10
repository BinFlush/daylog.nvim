-- Dependency-free line coverage for lua/daylog, collected via a LuaJIT line hook. Run through
-- `just coverage`: start(), dofile the suite, report(). Not part of the gate -- the hook makes the
-- fuzz sweeps run in minutes.

local M = {}

local executed = {}

-- The `lua/daylog/...` suffix of a chunk source ("@./lua/daylog/x.lua" -> "lua/daylog/x.lua"), or nil
-- for anything outside the source tree (test files, vim internals).
local function rel_source(source)
  if type(source) ~= "string" or source:sub(1, 1) ~= "@" then
    return nil
  end
  return source:match("lua/daylog/.*%.lua$")
end

function M.start()
  debug.sethook(function(_, line)
    local info = debug.getinfo(2, "S")
    local rel = info and rel_source(info.source)
    if rel then
      local seen = executed[rel]
      if not seen then
        seen = {}
        executed[rel] = seen
      end
      seen[line] = true
    end
  end, "l")
end

-- A source line that should emit a line event when reached (so a miss is meaningful). Text heuristic:
-- excludes blanks, comments, lone structural tokens, function-declaration headers, and comma-terminated
-- table entries -- none of those fire a line event at call time, so they would read as false misses.
-- Still imperfect (some continuation lines slip through), so triage by contiguous runs of body lines.
local STRUCTURAL = {
  ["end"] = true,
  ["else"] = true,
  ["do"] = true,
  ["then"] = true,
  ["{"] = true,
  ["}"] = true,
  ["})"] = true,
  ["},"] = true,
  ["}),"] = true,
  [")"] = true,
  ["),"] = true,
  ["return"] = true,
}
local function is_code(line)
  local s = line:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" or s:sub(1, 2) == "--" then
    return false
  end
  if STRUCTURAL[s] or s:match("^end[,%)%.]") or s:match("^elseif") or s:match("^until") then
    return false
  end
  -- Declaration headers and table-entry data lines emit no line event when the code runs.
  if s:match("^local function ") or s:match("^function ") or s:match("= function%(") then
    return false
  end
  if not s:match("^local ") and (s:match("^[%w_]+%s*=.*,$") or s:match("^%[.-%]%s*=.*,$")) then
    return false
  end
  return true
end

function M.report()
  debug.sethook()
  local files = vim.fn.globpath("lua/daylog", "**/*.lua", false, true)
  table.sort(files)

  local rows = {}
  for _, file in ipairs(files) do
    local rel = file:match("lua/daylog/.*%.lua$") or file
    local seen = executed[rel] or {}
    local src = vim.fn.readfile(file)
    local code, missed, misses = 0, 0, {}
    for i, line in ipairs(src) do
      if is_code(line) then
        code = code + 1
        if not seen[i] then
          missed = missed + 1
          misses[#misses + 1] = { i, line:gsub("^%s+", "") }
        end
      end
    end
    rows[#rows + 1] =
      { rel = rel, code = code, missed = missed, misses = misses, loaded = executed[rel] ~= nil }
  end

  table.sort(rows, function(a, b)
    if a.missed ~= b.missed then
      return a.missed > b.missed
    end
    return a.rel < b.rel
  end)

  local total_code, total_missed = 0, 0
  print("\n===== daylog line coverage (uncovered code-looking lines) =====")
  for _, r in ipairs(rows) do
    total_code = total_code + r.code
    total_missed = total_missed + r.missed
    if r.missed > 0 then
      local pct = r.code > 0 and math.floor((r.code - r.missed) * 100 / r.code) or 100
      print(
        string.format(
          "\n%s  --  %d/%d covered (%d%%)%s",
          r.rel,
          r.code - r.missed,
          r.code,
          pct,
          r.loaded and "" or "  [MODULE NEVER LOADED]"
        )
      )
      for i = 1, math.min(#r.misses, 45) do
        print(string.format("  %4d  %s", r.misses[i][1], r.misses[i][2]))
      end
      if #r.misses > 45 then
        print(string.format("  ... and %d more", #r.misses - 45))
      end
    end
  end
  local covered = total_code - total_missed
  print(
    string.format(
      "\n===== TOTAL: %d/%d code lines covered (%d%%), %d uncovered =====",
      covered,
      total_code,
      total_code > 0 and math.floor(covered * 100 / total_code) or 100,
      total_missed
    )
  )
end

return M
