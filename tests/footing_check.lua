-- Shared footing-invariant check for one synthesized log.
--
-- Given a per-iteration seed and a mode name it synthesizes a log
-- (tests/log_synth.lua), summarizes it, renders both duration formats, and
-- returns a detailed error report for the first section that fails to foot (its
-- displayed rows do not sum to the displayed total), or nil when every section
-- foots. Shared by the always-on suite sample (tests/summary_fuzz.lua) and the
-- CLI sweep (tests/fuzz.lua, `just fuzz`).

local cwd = vim.fn.getcwd()
local Rng = dofile(cwd .. "/tests/rng.lua")
local synth = dofile(cwd .. "/tests/log_synth.lua")
local document = require("daylog.document")
local analyze = require("daylog.analyze")
local summary = require("daylog.summary")
local render = require("daylog.render")
local diagnostics = require("daylog.diagnostics")

local M = { Rng = Rng, synth = synth }

-- Parse a rendered row's leading duration into an integer: centihours for
-- `dec` ("1.50h" -> 150), minutes for `hm` ("1:30" -> 90).
local function parse_duration(line, fmt)
  if fmt == "dec" then
    local whole, frac = line:match("^(%d+)%.(%d+)h")
    if not whole then
      error("unparseable dec duration: " .. line, 0)
    end
    return tonumber(whole) * 100 + tonumber(frac)
  end
  local h, m = line:match("^(%d+):(%d+)")
  if not h then
    error("unparseable hm duration: " .. line, 0)
  end
  return tonumber(h) * 60 + tonumber(m)
end

-- Group a rendered summary layout into per-section displayed durations, the raw
-- rendered lines, and the totals. The totals partition foots to the whole day, so
-- the "whole" is the sum of every total row (workday + non-work); the workday row is
-- captured separately for the non-#ooo scope.
local function dissect(layout, fmt)
  local K = render.LAYOUT_KIND
  local sec = { summary = {}, tag = {}, location = {} }
  local rendered = {}
  local whole, workday = 0, nil
  for _, row in ipairs(layout) do
    rendered[#rendered + 1] = row.line
    if row.kind == K.SUMMARY_ITEM then
      sec.summary[#sec.summary + 1] = parse_duration(row.line, fmt)
    elseif row.kind == K.TAG_TOTAL then
      sec.tag[#sec.tag + 1] = parse_duration(row.line, fmt)
    elseif row.kind == K.LOCATION_TOTAL then
      sec.location[#sec.location + 1] = parse_duration(row.line, fmt)
    elseif row.kind == K.TOTAL then
      local d = parse_duration(row.line, fmt)
      whole = whole + d
      if row.line:find("workday") then
        workday = d
      end
    end
  end
  return sec, rendered, whole, workday
end

local function total(list)
  local s = 0
  for _, v in ipairs(list) do
    s = s + v
  end
  return s
end

-- Built only on failure (guarded by the caller) so the hot loop stays cheap.
local function report(sub, mode, wl, fmt, rendered, msg)
  return string.format(
    "%s\n  replay: synth.generate(Rng.new(%d), %q)  fmt=%s\n--- log ---\n%s\n--- rendered ---\n%s",
    msg,
    sub,
    mode,
    fmt,
    table.concat(wl.lines, "\n"),
    table.concat(rendered, "\n")
  )
end

-- Synthesize one log and check that every displayed section sums to its
-- total. Returns nil on success, or a detailed report string on failure.
function M.check(sub, mode)
  local wl = synth.generate(Rng.new(sub), mode)

  local analysis = analyze.analyze(document.parse(wl.lines))
  if #analysis.diagnostics > 0 then
    local msg = "synth produced an invalid daylog: " .. diagnostics.message(analysis.diagnostics[1])
    return report(sub, mode, wl, "-", {}, msg)
  end

  local block = analyze.get_active_log(analysis)
  if not block then
    return report(sub, mode, wl, "-", {}, "synth produced no active log")
  end

  local s = summary.summarize_block(block)

  -- Minute-level regression guard (already holds; guards the quantization layer).
  local item_min = 0
  for _, it in ipairs(s.summary_items) do
    item_min = item_min + it.duration
  end
  if item_min ~= s.activity_total then
    local msg = string.format("minute footing: items=%d activity=%d", item_min, s.activity_total)
    return report(sub, mode, wl, "min", {}, msg)
  end

  -- The displayed section total: dec rounds minutes to centihours, hm is exact minutes.
  local function displayed(minutes, fmt)
    if fmt == "dec" then
      return math.floor(minutes * 100 / 60 + 0.5)
    end
    return minutes
  end

  for _, fmt in ipairs({ "dec", "hm" }) do
    local sec, rendered, activity = dissect(render.summary_layout(s, fmt, {}), fmt)
    local checks = {
      { "summary items", sec.summary, activity },
      { "tag totals", sec.tag, displayed(s.tag_total, fmt) },
      { "location totals", sec.location, displayed(s.location_total, fmt) },
    }
    for _, c in ipairs(checks) do
      local name, rows, want = c[1], c[2], c[3]
      if #rows > 0 and want ~= nil and total(rows) ~= want then
        local msg =
          string.format("%s sum to %d but the section total is %d", name, total(rows), want)
        return report(sub, mode, wl, fmt, rendered, msg)
      end
    end
  end

  return nil
end

return M
