return function(t)
  local analyze = require("daylog.analyze")
  local balance = require("daylog.usecases.balance_summary")
  local document = require("daylog.document")
  local render = require("daylog.render")
  local summary = require("daylog.summary")

  -- A full buffer (log body + its generated summary), so the cursor can sit on a
  -- real summary line exactly as in an open file.
  local function buffer_with_summary(log_lines)
    local analysis = analyze.analyze(document.parse(log_lines))
    local block = analyze.get_active_log(analysis)
    local out = {}
    for _, line in ipairs(log_lines) do
      out[#out + 1] = line
    end
    for _, line in
      ipairs(render.summary_lines(summary.summarize_block(block), block.duration_format, {
        quantize_minutes = block.quantize_minutes,
      }))
    do
      out[#out + 1] = line
    end
    return out
  end

  -- Apply an edit script (edits are pre-sorted highest-row-first, so sequential
  -- application does not shift the not-yet-applied lower edits).
  local function apply(lines, result)
    local out = {}
    for _, line in ipairs(lines) do
      out[#out + 1] = line
    end
    for _, edit in ipairs(result.edits) do
      local next_out = {}
      for i = 1, edit.start_index do
        next_out[#next_out + 1] = out[i]
      end
      for _, line in ipairs(edit.lines) do
        next_out[#next_out + 1] = line
      end
      for i = edit.end_index + 1, #out do
        next_out[#next_out + 1] = out[i]
      end
      out = next_out
    end
    return out
  end

  local function row_of(lines, needle)
    for i, line in ipairs(lines) do
      if line:find(needle, 1, true) then
        return i
      end
    end
    error("line not found: " .. needle)
  end

  local function run(lines, needle, delta)
    local result, err = balance.run(lines, row_of(lines, needle), delta)
    if not result then
      return nil, err
    end
    return apply(lines, result)
  end

  -- plan 50min, review 45min, q=15 -> plan 0.75h(+5m) / review 0.75h(+0m) / workday 1.50h(+5m).
  local function sample()
    return buffer_with_summary({
      "--- log #ClientA @office q=15 ---",
      "08:00 plan",
      "08:50 review",
      "09:35 done",
    })
  end

  t.test("balance rounds the workday total up, marking the least-error entry", function()
    -- plan has the larger remainder (5m vs review's 0m), so it is the cheapest to
    -- round up; the marker lands on its entry and every containing section shifts.
    local out = run(sample(), "workday", 1)

    t.eq(out[2], "08:00 plan round+1")
    t.eq(out[3], "08:50 review")
    t.eq(out[row_of(out, "(-10m) plan")], "1.00h (-10m) plan round+1")
    t.eq(out[row_of(out, "(+0m) review")], "0.75h (+0m) review")
    t.eq(out[row_of(out, "workday")], "1.75h (-10m) workday round+1")
  end)

  t.test("balance rounding the total back down cancels the prior nudge", function()
    local up = run(sample(), "workday", 1)
    local down = run(up, "workday", -1)

    t.eq(down, sample())
  end)

  t.test("balance clears a row's nudge with a zero delta", function()
    local up = run(sample(), "workday", 1)
    local cleared = run(up, "plan round+1", 0)

    t.eq(cleared, sample())
  end)

  t.test("balance set directly on an entry marks that entry", function()
    local out = run(sample(), "08:50 review", 1)

    t.eq(out[3], "08:50 review round+1")
    t.eq(out[row_of(out, "(-15m) review")], "1.00h (-15m) review round+1")
    t.eq(out[row_of(out, "workday")], "1.75h (-10m) workday round+1")
  end)

  t.test("balance on a main row nudges only that activity's rows", function()
    -- Rounding the 'review' row up marks review, not plan, and shifts the total too.
    local out = run(sample(), "0.75h (+0m) review", 1)

    t.eq(out[2], "08:00 plan")
    t.eq(out[3], "08:50 review round+1")
    t.eq(out[row_of(out, "(-15m) review")], "1.00h (-15m) review round+1")
    t.eq(out[row_of(out, "(+5m) plan")], "0.75h (+5m) plan")
  end)

  t.test("balance applies multiple steps to distinct best rows", function()
    -- Two equal-remainder activities; +2 on the total rounds up both.
    local lines = buffer_with_summary({
      "--- log #ClientA q=15 ---",
      "08:00 plan",
      "08:50 review",
      "09:40 done",
    })
    local out = run(lines, "workday", 2)

    t.eq(out[2], "08:00 plan round+1")
    t.eq(out[3], "08:50 review round+1")
  end)

  t.test("balance refuses to round down past empty", function()
    -- A single 10-min task at q=15 rounds up to 0.25h naturally; one -1 takes it to
    -- 0.00h, and a second has nowhere to go.
    local lines = buffer_with_summary({
      "--- log #ClientA q=15 ---",
      "08:00 task",
      "08:10 done",
    })
    local once = run(lines, "workday", -1)
    t.eq(once[2], "08:00 task round-1")
    t.eq(once[row_of(once, "workday")], "0.00h (+10m) workday round-1")

    local _, err = balance.run(once, row_of(once, "workday"), -1)
    t.eq(err, balance.CANNOT_DOWN)
  end)

  t.test("balance marks every interval of a multi-interval activity row", function()
    -- review is three intervals (one fine-grained row, 78min -> 1.25h +3m). Rounding
    -- the row up one bucket marks ALL THREE intervals and lands at 1.50h -- not three
    -- buckets (2.00h), which a per-interval/additive marker would produce.
    local lines = buffer_with_summary({
      "--- log #ClientA @office q=15 ---",
      "08:00 review",
      "08:26 review",
      "08:52 review",
      "09:18 done",
    })
    local out = run(lines, "1.25h", 1)

    t.eq(out[2], "08:00 review round+1")
    t.eq(out[3], "08:26 review round+1")
    t.eq(out[4], "08:52 review round+1")
    t.eq(out[row_of(out, "(-12m) review")], "1.50h (-12m) review round+1")
  end)

  t.test("balance refuses an entry that starts no interval", function()
    -- The closing entry of the day starts no interval, so it belongs to no
    -- quantization row and cannot be rounded.
    local lines = sample()
    local _, err = balance.run(lines, row_of(lines, "09:35 done"), 1)
    t.eq(err, balance.NOT_BALANCEABLE)
  end)

  t.test("balance distinguishes the workday total (non-ooo) from the activity total", function()
    -- work is non-ooo and exact (remainder 0); lunch is #ooo with the larger
    -- remainder, so it is the activity total's best candidate but is excluded from
    -- the workday total's scope.
    local function sample_ooo()
      return buffer_with_summary({
        "--- log #ClientA @office q=15 ---",
        "08:00 work",
        "08:45 lunch #ooo",
        "09:35 done",
      })
    end

    -- The activity total spans all rows: +1 rounds up the larger-remainder #ooo row,
    -- and leaves the workday total untouched.
    local act = run(sample_ooo(), ") activity", 1)
    t.eq(act[2], "08:00 work")
    t.eq(act[3], "08:45 lunch #ooo round+1")
    t.eq(act[row_of(act, ") workday")], "0.75h (+0m) workday")

    -- The workday total excludes #ooo, so +1 must round up the non-ooo row instead.
    local wd = run(sample_ooo(), ") workday", 1)
    t.eq(wd[2], "08:00 work round+1")
    t.eq(wd[3], "08:45 lunch #ooo")
    t.eq(wd[row_of(wd, ") workday")], "1.00h (-15m) workday round+1")
  end)

  t.test("balance refuses when the cursor is not on a summary row or entry", function()
    local lines = sample()
    local _, err = balance.run(lines, row_of(lines, "--- log"), 1)
    t.eq(err, balance.NOT_BALANCEABLE)
  end)
end
