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
local refresh_summaries = require("daylog.usecases.refresh_summaries")
local support = require("daylog.usecases.support")
local body = require("daylog.body")
local entry = require("daylog.entry")

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
-- rendered lines, and the totals. The totals section is a single `workday` row = the
-- whole counted day, so the "whole" is the sum of the total row(s) and the main
-- section foots to it.
local function dissect(layout, fmt)
  local K = render.LAYOUT_KIND
  local sec = { summary = {}, tag = {}, location = {} }
  local rendered = {}
  local whole = 0
  for _, row in ipairs(layout) do
    rendered[#rendered + 1] = row.line
    if row.kind == K.SUMMARY_ITEM then
      sec.summary[#sec.summary + 1] = parse_duration(row.line, fmt)
    elseif row.kind == K.TAG_TOTAL then
      sec.tag[#sec.tag + 1] = parse_duration(row.line, fmt)
    elseif row.kind == K.LOCATION_TOTAL then
      sec.location[#sec.location + 1] = parse_duration(row.line, fmt)
    elseif row.kind == K.TOTAL then
      whole = whole + parse_duration(row.line, fmt)
    end
  end
  return sec, rendered, whole
end

local function total(list)
  local s = 0
  for _, v in ipairs(list) do
    s = s + v
  end
  return s
end

local function lines_equal(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

local function sum_field(list, field)
  local n = 0
  for _, it in ipairs(list or {}) do
    n = n + (it[field] or 0)
  end
  return n
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
      { "tag totals", sec.tag, displayed(s.activity_total, fmt) },
      { "location totals", sec.location, displayed(s.activity_total, fmt) },
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

  -- Partition + residual identities (T1/T2/T3), minute-level: tags and locations are partitions of the
  -- same activity total, and each row's residual is exactly unrounded - displayed. Stronger than the
  -- displayed-section footing above; extends tests/balance_invariants to the deep sweep.
  for _, part in ipairs({ { "tags", s.tag_totals }, { "locations", s.location_totals } }) do
    if sum_field(part[2], "duration") ~= s.activity_total then
      return report(
        sub,
        mode,
        wl,
        "min",
        {},
        string.format(
          "%s partition sum=%d activity=%d",
          part[1],
          sum_field(part[2], "duration"),
          s.activity_total
        )
      )
    end
  end
  for _, part in ipairs({
    { "items", s.summary_items },
    { "tags", s.tag_totals },
    { "locs", s.location_totals },
  }) do
    for i, it in ipairs(part[2]) do
      local want = (it.unrounded_duration or it.duration) - it.duration
      if (it.error_minutes or 0) ~= want then
        return report(
          sub,
          mode,
          wl,
          "min",
          {},
          string.format("%s[%d] residual=%d expected=%d", part[1], i, it.error_minutes or 0, want)
        )
      end
    end
  end
  if (s.activity_error_minutes or 0) ~= sum_field(s.summary_items, "error_minutes") then
    return report(
      sub,
      mode,
      wl,
      "min",
      {},
      string.format(
        "activity residual %d != sum item residuals %d",
        s.activity_error_minutes or 0,
        sum_field(s.summary_items, "error_minutes")
      )
    )
  end

  -- Commit consistency: the rows :Daylog log / balance freeze (summary.fine_grained_quantized) must carry
  -- the DISPLAY's durations, so logging a row freezes exactly the value it shows and strands nothing.
  -- Those rows split per (activity, location) so an `!S[]` commits per location; aggregating them back per
  -- activity+names must match the summary items. (Compared by total, not the logged/unlogged split, which
  -- differs harmlessly for a valueless `!S[]` marker coexisting with a committed value across locations.) This is
  -- the exact drift behind the reported bug: frozen siblings under-committed, so a lone un-frozen row
  -- absorbed the leftover buckets on screen but fine_grained rounded it to its own total.
  local function activity_cell_totals(rows)
    local totals = {}
    for _, row in ipairs(rows) do
      local key = table.concat({ row.text or "", row.tag or "", row.s_names_key or "" }, "\0")
      totals[key] = (totals[key] or 0) + row.duration
    end
    return totals
  end
  local fg_total =
    activity_cell_totals(summary.fine_grained_quantized(block.entries, block.quantize_minutes))
  for key, shown in pairs(activity_cell_totals(s.summary_items)) do
    if (fg_total[key] or 0) ~= shown then
      return report(
        sub,
        mode,
        wl,
        "min",
        {},
        string.format(
          "log-commit drift: activity cell %q freezes %d but shows %d",
          key,
          fg_total[key] or 0,
          shown
        )
      )
    end
  end

  -- Refresh fixpoint: summary regeneration is idempotent on raw text, so refreshing an
  -- already-refreshed log changes nothing. Stresses named-marker re-location -- refresh must re-find
  -- the !S[names] row it just wrote.
  local once = support.apply_edits(wl.lines, refresh_summaries.run(wl.lines).edits)
  -- Empty edit set on an already-refreshed log IS the fixpoint (applying it returns `once` unchanged),
  -- so one re-run suffices -- no need for a third refresh.
  if #refresh_summaries.run(once).edits ~= 0 then
    return report(sub, mode, wl, "-", once, "refresh is not a fixpoint")
  end

  -- Entry-writer fixpoint: re-emit the block's entries through the canonical writer (as :Daylog copy
  -- does), re-parse, and re-emit again -- byte-identical, or a named/multilevel marker was mangled on
  -- rewrite. (A synth log starts with its header on line 1.)
  local reemit = body.normalized_lines(block, entry.format)
  local full = { wl.lines[1] }
  for _, l in ipairs(reemit) do
    full[#full + 1] = l
  end
  local reblock = analyze.get_active_log(analyze.analyze(document.parse(full)))
  if not reblock then
    return report(sub, mode, wl, "-", reemit, "re-emitted entries no longer parse as a log")
  end
  if not lines_equal(reemit, body.normalized_lines(reblock, entry.format)) then
    return report(
      sub,
      mode,
      wl,
      "-",
      reemit,
      "entry writer is not a fixpoint (marker mangled on rewrite)"
    )
  end

  return nil
end

return M
