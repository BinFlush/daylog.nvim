return function(t)
  local cwd = vim.fn.getcwd()
  local Rng = dofile(cwd .. "/tests/rng.lua")
  local synth = dofile(cwd .. "/tests/log_synth.lua")
  local document = require("daylog.document")
  local analyze = require("daylog.analyze")
  local summary = require("daylog.summary")
  local render = require("daylog.render")
  local support = require("daylog.usecases.support")
  local refresh = require("daylog.usecases.refresh_summaries")
  local log_current = require("daylog.usecases.log_current")
  local split_summary = require("daylog.usecases.split_summary")
  local rename_summary = require("daylog.usecases.rename_summary")
  local map_summary = require("daylog.usecases.map_summary")
  local balance_summary = require("daylog.usecases.balance_summary")
  local body = require("daylog.body")
  local entry = require("daylog.entry")

  -- Logging behaviors footing can't see -- log/unlog round-trips, guard-parity, where a round nudge
  -- renders. tests/footing_check.lua covers the footing/frozen-value side.

  local function active(lines)
    return analyze.get_active_log(analyze.analyze(document.parse(lines)))
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
  local function rendered(src)
    return support.apply_edits(src, refresh.run(src).edits)
  end
  local function row_line(lines, needle)
    for i, l in ipairs(lines) do
      if l:find(needle, 1, true) then
        return i, l
      end
    end
  end

  local KIND_OF = {
    s = render.LAYOUT_KIND.SUMMARY_ITEM,
    t = render.LAYOUT_KIND.TAG_TOTAL,
    l = render.LAYOUT_KIND.LOCATION_TOTAL,
    w = render.LAYOUT_KIND.TOTAL,
  }
  local NAMES_KEY = { s = "s_names_key", t = "t_names_key", l = "l_names_key", w = "w_names_key" }

  -- A marker-free, refreshed base, so the round-trip's only edits are the one marker added and removed.
  -- Strip via the formatter, not a {logged=nil} override table -- that empty table deletes the line.
  -- The base a log/unlog round-trip starts from: no claims, and no `round±N` either. Freezing
  -- absorbs a nudge (the claim supersedes the display it adjusted), so a nudged row is the one shape
  -- the round-trip cannot restore -- covered on its own below.
  local function marker_free_base(block, header)
    local function strip(e, tag, loc, off)
      local copy = {}
      for k, v in pairs(e) do
        copy[k] = v
      end
      copy.logged = nil
      copy.nudge = nil
      return entry.format(copy, tag, loc, off)
    end
    local full = { header }
    for _, l in ipairs(body.normalized_lines(block, strip)) do
      full[#full + 1] = l
    end
    return support.apply_edits(full, refresh.run(full).edits)
  end

  local function roundtrip(seed, mode)
    local wl = synth.generate(Rng.new(seed), mode)
    if #analyze.analyze(document.parse(wl.lines)).diagnostics > 0 then
      return nil
    end
    local block = active(wl.lines)
    if not block then
      return nil
    end
    local base = marker_free_base(block, wl.lines[1])
    local base_block = active(base)
    if not base_block then
      return nil
    end
    local s_base = summary.summarize_block(base_block)
    local ctx = string.format("seed=%d mode=%s", seed, mode)

    for _, lvl in ipairs({ "s", "t", "l", "w" }) do
      local row
      for _, r in ipairs(render.summary_layout(s_base, "hm", {})) do
        if
          r.kind == KIND_OF[lvl]
          and not r.item.logged
          and (r.item[NAMES_KEY[lvl]] or "") == ""
        then
          row = r
          break
        end
      end
      -- A value over a day (1440) can't be frozen -- the parser rejects such a marker -- and the synth's
      -- heavy over-commitments can inflate a tag/workday total past a real day; skip those, they are not
      -- a loggable operation.
      if row and (row.item.duration or 0) <= 1440 then
        local target = log_current.classify_report_row(row)
        local ok, logged_res = pcall(log_current.run_by_value, base, target, {})
        if not ok then
          return string.format("%s lvl=%s: run_by_value raised: %s", ctx, lvl, tostring(logged_res))
        end
        -- nil: a non-loggable row this seed (e.g. a drift remainder) -- skip, not a failure.
        if logged_res then
          local logged = support.apply_edits(base, logged_res.edits)
          local lblock = active(logged)
          if not lblock then
            return string.format("%s lvl=%s: logging produced no active log", ctx, lvl)
          end
          local after = summary.summarize_block(lblock).activity_total
          if after ~= s_base.activity_total then
            return string.format(
              "%s lvl=%s: a fresh log moved the day total %d -> %d\n%s",
              ctx,
              lvl,
              s_base.activity_total,
              after,
              table.concat(logged, "\n")
            )
          end
          -- The row to unlog is the CLAIM the log just made, not the plain row it grew from: a cell
          -- can hold both, and they are told apart by exactly this flag.
          local claim_target = {}
          for key, value in pairs(target) do
            claim_target[key] = value
          end
          claim_target.logged = true

          local ok2, back_res = pcall(log_current.run_unlog_by_value, logged, claim_target, nil)
          if not ok2 then
            return string.format(
              "%s lvl=%s: run_unlog_by_value raised: %s",
              ctx,
              lvl,
              tostring(back_res)
            )
          end
          if not back_res then
            return string.format("%s lvl=%s: unlog found nothing to reverse", ctx, lvl)
          end
          local back = support.apply_edits(logged, back_res.edits)
          if not lines_equal(back, base) then
            return string.format(
              "%s lvl=%s: log/unlog is not the identity\n--- base ---\n%s\n--- after log+unlog ---\n%s",
              ctx,
              lvl,
              table.concat(base, "\n"),
              table.concat(back, "\n")
            )
          end
        end
      end
    end
    return nil
  end

  t.test(
    "log then unlog is the identity and a fresh log never moves the day total (fuzz)",
    function()
      local master = Rng.new(48271)
      for _, mode in ipairs(synth.MODES) do
        for _ = 1, 60 do
          local err = roundtrip(master:int(1, 2147483646), mode)
          if err then
            error(err, 0)
          end
        end
      end
    end
  )

  -- split refuses any level (a cut would drop the marker); rename/map only reshape activity identity,
  -- keyed on !S alone, so they refuse !S but must keep a !T/!L/!W marker.
  t.test(
    "split refuses a logged row at every level; rename/map refuse only !S and keep T/L/W",
    function()
      for _, mk in ipairs({ "!S[]60", "!T[]60", "!L[]60", "!W[]60" }) do
        local buf = rendered({ "--- log q=15 ---", "08:00 alpha #x @o " .. mk, "09:00 done" })
        local erow = row_line(buf, "08:00 alpha")
        local mrow = row_line(buf, ") alpha")

        t.eq(select(2, split_summary.run(buf, mrow, { 1, 1 })), split_summary.REFUSE_LOGGED)

        if mk:sub(2, 2) == "S" then
          t.eq(select(2, rename_summary.run(buf, erow, "renamed")), rename_summary.REFUSE_LOGGED)
          t.eq(select(2, map_summary.run(buf, erow, "label")), map_summary.REFUSE_LOGGED)
        else
          local renamed = support.apply_edits(buf, rename_summary.run(buf, erow, "renamed").edits)
          t.ok(row_line(renamed, mk) ~= nil, "rename keeps the " .. mk .. " marker")
          local mapped = support.apply_edits(buf, map_summary.run(buf, erow, "label").edits)
          t.ok(row_line(mapped, mk) ~= nil, "map keeps the " .. mk .. " marker")
        end
      end
    end
  )

  t.test("a below-zero nudge warns and shows", function()
    local low = { "--- log q=15 ---", "08:00 small round-3", "08:15 done" }
    t.ok(
      row_line(rendered(low), "0.00h (+15m) small round-3") ~= nil,
      "the clamped item shows its nudge"
    )
    local low_warns = refresh.run(low).warnings
    t.ok(
      #low_warns >= 1 and low_warns[1].message:find("below zero", 1, true) ~= nil,
      "refresh warns the item rounds below zero"
    )
  end)

  -- Every way a set of claims can fail to describe one day, and a clean log failing in none of them.
  -- These are block diagnostics, so they stop the summary being rebuilt at all -- which is why the
  -- footing fuzz (emitting only realizable claims) never sees them.
  t.test("a claim that cannot be realized is a block diagnostic", function()
    local function fires(lines, needle)
      local analysis = analyze.analyze(document.parse(lines))
      local diagnostic = analyze.find_block_diagnostic(analysis, analyze.get_active_log(analysis))
      return diagnostic ~= nil and diagnostic.message:find(needle, 1, true) ~= nil
    end

    t.ok(
      fires(
        { "--- log q=15 ---", "08:00 x #a !S[]30", "09:00 x #a !S[]60", "10:00 done" },
        "disagree"
      ),
      "one slice, two stated values"
    )
    t.ok(
      fires({ "--- log q=15 ---", "09:00 work #T @L !T[]120 !L[]90", "10:00 stop" }, "contradicts"),
      "claims over the same entry stating different totals"
    )
    t.ok(
      fires({ "--- log q=15 ---", "08:00 x round+1 !S[]60", "09:00 done" }, "round nudge"),
      "a nudge on a claimed row"
    )

    -- An off-grid value is a FACT, not a problem: it displays verbatim and raises nothing.
    local off_grid = { "--- log q=15 ---", "08:00 x #a !S[]7", "09:00 done" }
    local analysis = analyze.analyze(document.parse(off_grid))
    t.eq(analyze.find_block_diagnostic(analysis, analyze.get_active_log(analysis)), nil)
    t.ok(row_line(rendered(off_grid), "0.12h (+53m) x !S[]") ~= nil, "the claim shows as written")

    local clean = { "--- log q=15 ---", "08:00 x #a @o !S[]60", "09:00 done" }
    local clean_analysis = analyze.analyze(document.parse(clean))
    t.eq(analyze.find_block_diagnostic(clean_analysis, analyze.get_active_log(clean_analysis)), nil)
  end)

  -- A forward edit and its inverse return the buffer to base, byte-for-byte. rename/map act on the
  -- entry (an activity row may mix bare + mapped entries); balance acts on the summary row.
  t.test("map/clear, rename A->B->A, and balance +N/-N are identities", function()
    local base = rendered({ "--- log q=15 ---", "08:00 alpha #x @o", "09:00 beta", "10:00 done" })

    local mapped = support.apply_edits(base, map_summary.run(base, 2, "mapped").edits)
    t.ok(
      lines_equal(support.apply_edits(mapped, map_summary.run(mapped, 2, "").edits), base),
      "map/clear"
    )

    local renamed = support.apply_edits(base, rename_summary.run(base, 2, "renamed").edits)
    t.ok(
      lines_equal(support.apply_edits(renamed, rename_summary.run(renamed, 2, "alpha").edits), base),
      "rename A->B->A"
    )

    local balanced =
      support.apply_edits(base, balance_summary.run(base, row_line(base, ") alpha"), 2).edits)
    t.ok(
      lines_equal(
        support.apply_edits(
          balanced,
          balance_summary.run(balanced, row_line(balanced, ") alpha"), -2).edits
        ),
        base
      ),
      "balance +N/-N"
    )
  end)
end
