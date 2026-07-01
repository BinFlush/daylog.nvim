return function(t)
  -- Property test encoding the rounding-balance soundness theorems (see
  -- docs/architecture.md / the plan): footing and its corollaries are structural
  -- partition-sum identities, so they must hold for ANY per-cell nudge. This throws
  -- adversarial per-entry nudge vectors (wide range, mixed signs, forcing clamps) at
  -- synthesized logs -- on top of the offsets/tags/locations/ooo/!S the synth
  -- already varies -- and asserts, for the day summary AND a combined week:
  --   T1  every section's rows sum to its own total;
  --   T2  activity = Σtags = Σlocations, workday = Σlogged, activity - workday = Σooo;
  --   T3  displayed + residual = true, per row and per section;
  --   (display) the rendered dec/hm rows foot to each section's shown total.
  -- The always-on footing fuzz only emits small random nudges; this is the strong,
  -- theorem-shaped guard.
  local cwd = vim.fn.getcwd()
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")
  local summary = require("daylog.summary")
  local render = require("daylog.render")
  local Rng = dofile(cwd .. "/tests/rng.lua")
  local synth = dofile(cwd .. "/tests/log_synth.lua")

  local function eq(a, b, ctx)
    if a ~= b then
      error(string.format("%s: %s ~= %s", ctx, tostring(a), tostring(b)), 0)
    end
  end

  local function sum_field(list, field)
    local total = 0
    for _, item in ipairs(list or {}) do
      total = total + (item[field] or 0)
    end
    return total
  end

  -- T1/T2/T3 at the minute level: pure partition-sum identities over the cells.
  local function assert_partition_invariants(ctx, s)
    -- T1: each section is a partition that sums to its OWN total (tag/location
    -- totals round on their own axis and can differ from activity after a nudge).
    eq(sum_field(s.summary_items, "duration"), s.activity_total, ctx .. " T1 items=activity")
    eq(sum_field(s.tag_totals, "duration"), s.tag_total, ctx .. " T1 tags=tag_total")
    eq(sum_field(s.location_totals, "duration"), s.location_total, ctx .. " T1 locs=location_total")

    local workday, ooo = 0, 0
    for _, item in ipairs(s.summary_items) do
      if item.workday_excluded then
        ooo = ooo + item.duration
      else
        workday = workday + item.duration
      end
    end
    eq(workday, s.workday_total, ctx .. " T1 non-ooo items=workday")

    -- T2: the activity/workday gap is exactly the out-of-office time.
    eq(s.activity_total - s.workday_total, ooo, ctx .. " T2 activity-workday=ooo")

    -- T3: displayed + residual = true, per row and summed per section.
    local function residuals(list, name)
      for i, item in ipairs(list or {}) do
        eq(
          item.error_minutes,
          (item.unrounded_duration or item.duration) - item.duration,
          string.format("%s T3 %s[%d]", ctx, name, i)
        )
      end
    end
    residuals(s.summary_items, "items")
    residuals(s.tag_totals, "tags")
    residuals(s.location_totals, "locs")
    eq(
      s.activity_error_minutes,
      sum_field(s.summary_items, "error_minutes"),
      ctx .. " T3 activity residual = Σ item residuals"
    )
  end

  local function parse_duration(line, fmt)
    if fmt == "dec" then
      local whole, frac = line:match("^(%d+)%.(%d+)h")
      return tonumber(whole) * 100 + tonumber(frac)
    end
    local hours, minutes = line:match("^(%d+):(%d+)")
    return tonumber(hours) * 60 + tonumber(minutes)
  end

  -- The displayed section total: dec rounds minutes to centihours, hm is exact minutes.
  local function displayed(minutes, fmt)
    if fmt == "dec" then
      return math.floor(minutes * 100 / 60 + 0.5)
    end
    return minutes
  end

  -- The rendered rows of each section must foot to that section's displayed total.
  local function assert_display_footing(ctx, s)
    local K = render.LAYOUT_KIND
    for _, fmt in ipairs({ "dec", "hm" }) do
      local sections = { summary = {}, tag = {}, location = {} }
      local activity, workday
      for _, row in ipairs(render.summary_layout(s, fmt, {})) do
        if row.kind == K.SUMMARY_ITEM then
          sections.summary[#sections.summary + 1] = parse_duration(row.line, fmt)
        elseif row.kind == K.TAG_TOTAL then
          sections.tag[#sections.tag + 1] = parse_duration(row.line, fmt)
        elseif row.kind == K.LOCATION_TOTAL then
          sections.location[#sections.location + 1] = parse_duration(row.line, fmt)
        elseif row.kind == K.TOTAL then
          local value = parse_duration(row.line, fmt)
          if row.line:find("activity") then
            activity = value
          elseif row.line:find("workday") then
            workday = value
          end
        end
      end

      -- When no #ooo work exists the activity row is omitted and the main
      -- section foots to the workday total instead. Tag and location sections
      -- foot to their OWN displayed totals.
      local whole = activity or workday
      local checks = {
        { "summary", sections.summary, whole },
        { "tag", sections.tag, displayed(s.tag_total, fmt) },
        { "location", sections.location, displayed(s.location_total, fmt) },
      }
      for _, check in ipairs(checks) do
        local rows, want = check[2], check[3]
        if #rows > 0 and want ~= nil then
          local total = 0
          for _, value in ipairs(rows) do
            total = total + value
          end
          eq(total, want, string.format("%s display foot fmt=%s %s", ctx, fmt, check[1]))
        end
      end
    end
  end

  -- A day summary with an adversarial per-entry nudge vector laid over the synth's
  -- own structure (wide range with mixed signs and zeros, forcing clamps).
  local function adversarial_day(seed, mode)
    local wl = synth.generate(Rng.new(seed), mode)
    local block = analyze.get_active_log(analyze.analyze(document.parse(wl.lines)))
    if not block then
      return nil
    end

    local nudge_rng = Rng.new(seed * 7 + 3)
    for _, semantic_entry in ipairs(block.entries) do
      semantic_entry.nudge = nudge_rng:int(-6, 6)
    end

    return summary.summarize_entries(block.entries, block.quantize_minutes)
  end

  t.test("balance invariants hold under adversarial per-cell nudges (day and week)", function()
    local master = Rng.new(20260618)

    for _, mode in ipairs(synth.MODES) do
      for _ = 1, 200 do
        local seed = master:int(1, 2147483646)
        local s = adversarial_day(seed, mode)
        if s then
          local ctx = string.format("%s day seed=%d", mode, seed)
          assert_partition_invariants(ctx, s)
          assert_display_footing(ctx, s)
        end
      end
    end

    -- The week aggregate is the same partition structure one level up: a nudge in
    -- any day must flow into the combined totals while every section still foots.
    for _ = 1, 200 do
      local days = {}
      for _ = 1, master:int(1, 5) do
        local s = adversarial_day(master:int(1, 2147483646), master:choice(synth.MODES))
        if s then
          days[#days + 1] = s
        end
      end

      local week = summary.combine_summaries(days)
      assert_partition_invariants("week", week)
      assert_display_footing("week", week)
    end
  end)
end
