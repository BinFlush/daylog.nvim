return function(t)
  local cwd = vim.fn.getcwd()
  local Rng = dofile(cwd .. "/tests/rng.lua")
  local synth = dofile(cwd .. "/tests/worklog_synth.lua")
  local document = require("worklog.document")
  local analyze = require("worklog.analyze")
  local summary = require("worklog.summary")
  local render = require("worklog.render")
  local diagnostics = require("worklog.diagnostics")

  local BASE_SEED = 1234567
  -- The full sweep is exhaustive but slow, so the always-on suite runs a sample
  -- that still hammers every mode and failing-q bucket; `just fuzz`
  -- (WORKLOG_FUZZ=full) runs all 5000/mode on demand or in CI.
  local PER_MODE = os.getenv("WORKLOG_FUZZ") == "full" and 5000 or 400

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

  -- Group a rendered summary layout into per-section displayed durations, the
  -- raw rendered lines, and the activity / workday totals.
  local function dissect(layout, fmt)
    local K = render.LAYOUT_KIND
    local sec = { summary = {}, tag = {}, location = {}, logged = {} }
    local rendered = {}
    local activity, workday
    for _, row in ipairs(layout) do
      rendered[#rendered + 1] = row.line
      if row.kind == K.SUMMARY_ITEM then
        sec.summary[#sec.summary + 1] = parse_duration(row.line, fmt)
      elseif row.kind == K.TAG_TOTAL then
        sec.tag[#sec.tag + 1] = parse_duration(row.line, fmt)
      elseif row.kind == K.LOCATION_TOTAL then
        sec.location[#sec.location + 1] = parse_duration(row.line, fmt)
      elseif row.kind == K.LOGGED_TOTAL then
        sec.logged[#sec.logged + 1] = parse_duration(row.line, fmt)
      elseif row.kind == K.TOTAL then
        local d = parse_duration(row.line, fmt)
        if row.line:find("activity") then
          activity = d
        elseif row.line:find("workday") then
          workday = d
        end
      end
    end
    return sec, rendered, (activity or workday), workday
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
      "%s\n  replay: synth.generate(Rng.new(%d), %q)  fmt=%s\n--- worklog ---\n%s\n--- rendered ---\n%s",
      msg,
      sub,
      mode,
      fmt,
      table.concat(wl.lines, "\n"),
      table.concat(rendered, "\n")
    )
  end

  -- Synthesize one worklog and assert every displayed section sums to its total.
  local function check_one(sub, mode)
    local wl = synth.generate(Rng.new(sub), mode)

    local analysis = analyze.analyze(document.parse(wl.lines))
    if #analysis.diagnostics > 0 then
      local msg = "synth produced an invalid worklog: "
        .. diagnostics.message(analysis.diagnostics[1])
      error(report(sub, mode, wl, "-", {}, msg), 0)
    end

    local block = analyze.get_active_worklog(analysis)
    if not block then
      error(report(sub, mode, wl, "-", {}, "synth produced no active worklog"), 0)
    end

    local s = summary.summarize_block(block)

    -- Minute-level regression guard (already holds; guards the quantization layer).
    local item_min = 0
    for _, it in ipairs(s.summary_items) do
      item_min = item_min + it.duration
    end
    if item_min ~= s.activity_total then
      local msg = string.format("minute footing: items=%d activity=%d", item_min, s.activity_total)
      error(report(sub, mode, wl, "min", {}, msg), 0)
    end

    for _, fmt in ipairs({ "dec", "hm" }) do
      local sec, rendered, activity, workday = dissect(render.summary_layout(s, fmt, {}), fmt)
      local checks = {
        { "summary items", sec.summary, activity },
        { "tag totals", sec.tag, activity },
        { "location totals", sec.location, activity },
        { "logged totals", sec.logged, workday },
      }
      for _, c in ipairs(checks) do
        local name, rows, want = c[1], c[2], c[3]
        if #rows > 0 and want ~= nil and total(rows) ~= want then
          local msg =
            string.format("%s sum to %d but the section total is %d", name, total(rows), want)
          error(report(sub, mode, wl, fmt, rendered, msg), 0)
        end
      end
    end
  end

  -- One deterministic master stream feeds every mode's per-iteration seed, so
  -- the whole sweep replays from BASE_SEED and each failure prints its own seed.
  local function run_fuzz()
    local master = Rng.new(BASE_SEED)
    for _, mode in ipairs(synth.MODES) do
      for _ = 1, PER_MODE do
        check_one(master:int(1, 2147483646), mode)
      end
    end
  end

  t.test("summary display footing holds across random worklogs (fuzz)", run_fuzz)
end
