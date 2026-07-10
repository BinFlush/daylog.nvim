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
  local function marker_free_base(block, header)
    local function strip(e, tag, loc, off)
      local copy = {}
      for k, v in pairs(e) do
        copy[k] = v
      end
      copy.logged = nil
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
      if row then
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
          local ok2, back_res = pcall(log_current.run_unlog_by_value, logged, target, nil)
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
        for _ = 1, 250 do
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

  -- An over-committed cell's nudge is inert, so it must show on no section and raise no below-zero
  -- warning -- footing can't see it, the nudge being already baked into the duration.
  t.test(
    "a below-zero nudge warns and shows; an over-committed cell's inert nudge shows nowhere",
    function()
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

      -- !S[]90 over-commits the 60m cell, so round-2 goes inert.
      local over = { "--- log q=15 ---", "08:00 big #x @o round-2 !S[]90", "09:00 done" }
      for _, l in ipairs(rendered(over)) do
        if l:match("^%d+%.%d+h") then -- a rendered duration row
          t.ok(l:match("round[%+%-]%d") == nil, "no inert nudge token on: " .. l)
        end
      end
      t.eq(#refresh.run(over).warnings, 0)
    end
  )
end
