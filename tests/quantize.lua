return function(t)
  local quantize = require("daylog.quantize")
  local projection = require("daylog.projection")

  -- The aggregate fuzz suites assert that summaries foot; these pin the per-row
  -- arithmetic at the module boundary, where a reshuffled tie-break or a broken
  -- clamp would still foot and pass the aggregate checks.

  t.test("round_to_nearest_bucket rounds an exact half up", function()
    t.eq(quantize.round_to_nearest_bucket(5, 10), 10)
    t.eq(quantize.round_to_nearest_bucket(4, 10), 0)
    t.eq(quantize.round_to_nearest_bucket(14, 10), 10)
    t.eq(quantize.round_to_nearest_bucket(15, 10), 20)
  end)

  t.test("quantize_rows breaks largest-remainder ties by first-seen order", function()
    local rows = {
      { unrounded_duration = 10 },
      { unrounded_duration = 10 },
      { unrounded_duration = 10 },
    }

    -- Each row floors to 0 with remainder 10; the single extra bucket (target 15)
    -- goes to the first-seen row, the others stay at 0.
    local result = quantize.quantize_rows(rows, 15, 15)
    t.eq(result[1].duration, 15)
    t.eq(result[2].duration, 0)
    t.eq(result[3].duration, 0)
    t.eq(result[1].error_minutes, -5)
    t.eq(result[2].error_minutes, 10)
    t.eq(result[3].error_minutes, 10)
  end)

  t.test("quantize_rows clamps a negative nudge at zero", function()
    local rows = { { unrounded_duration = 10, nudge = -1 } }

    -- A nudge cannot drive the displayed duration below zero.
    local result = quantize.quantize_rows(rows, 15, 0)
    t.eq(result[1].duration, 0)
    t.eq(result[1].error_minutes, 10)
  end)

  t.test("quantize_rows applies a positive nudge above the rounded baseline", function()
    local rows = { { unrounded_duration = 10, nudge = 1 } }

    local result = quantize.quantize_rows(rows, 15, 0)
    t.eq(result[1].duration, 15)
    t.eq(result[1].error_minutes, -5)
  end)

  t.test("quantize_rows holds a frozen row at its value and excludes it from the pool", function()
    -- Given a target, a frozen row is held at its committed value and pulled out of the
    -- pool; the leftover budget (target - frozen = 75 - 60 = 15) distributes over the
    -- un-frozen rows. The target itself is the caller's business: summarize_entries now
    -- derives it via frozen_aware_target (tested below), so this exact 75-budget only
    -- arises when the un-frozen rows' own total is 15.
    local rows = {
      { unrounded_duration = 67, logged_minutes = 60 },
      { unrounded_duration = 2 },
    }

    local result = quantize.quantize_rows(rows, 15, 75)
    t.eq(result[1].duration, 60)
    t.eq(result[1].error_minutes, 7)
    t.eq(result[2].duration, 15)
    t.eq(result[2].error_minutes, -13)
    t.eq(result[1].duration + result[2].duration, 75)
  end)

  t.test("quantize_rows keeps a frozen value fixed when an unrelated row grows", function()
    -- Appending more activity (the second row growing) never moves the committed row.
    local before = quantize.quantize_rows({
      { unrounded_duration = 67, logged_minutes = 60 },
      { unrounded_duration = 2 },
    }, 15, 75)
    local after = quantize.quantize_rows({
      { unrounded_duration = 67, logged_minutes = 60 },
      { unrounded_duration = 40 },
    }, 15, 105)
    t.eq(before[1].duration, 60)
    t.eq(after[1].duration, 60)
  end)

  t.test("quantize_rows ignores a nudge on a frozen row", function()
    -- A frozen value wins over a manual nudge if both ever land on one row.
    local result = quantize.quantize_rows(
      { { unrounded_duration = 67, logged_minutes = 60, nudge = 1 } },
      15,
      60
    )
    t.eq(result[1].duration, 60)
  end)

  t.test("frozen_aware_target is the plain rounded total when nothing is frozen", function()
    -- No frozen rows -> the whole rounds to the nearest bucket, exactly as before.
    t.eq(
      quantize.frozen_aware_target({
        { unrounded_duration = 60 },
        { unrounded_duration = 68 },
      }, 15),
      135
    )
  end)

  t.test("frozen_aware_target rounds only the un-frozen rows, then adds the commitments", function()
    -- thing two (68m) is frozen at a manually-rounded 60; thing one (60m) is un-frozen.
    -- The target is round(60) + 60 = 120, NOT round(128) = 135 -- so the un-frozen row
    -- keeps its own honest 60 instead of being pushed up to absorb the frozen row's nudge.
    t.eq(
      quantize.frozen_aware_target({
        { unrounded_duration = 60 },
        { unrounded_duration = 68, logged_minutes = 60 },
      }, 15),
      120
    )
  end)

  t.test("frozen_aware_target is the sum of commitments when every row is frozen", function()
    -- All rows frozen -> nothing to round; the target is just the committed minutes,
    -- even when a commitment is not bucket-aligned.
    t.eq(
      quantize.frozen_aware_target({
        { unrounded_duration = 67, logged_minutes = 45 },
        { unrounded_duration = 20, logged_minutes = 15 },
      }, 30),
      60
    )
  end)

  t.test("project_rows groups by key fields and sums durations", function()
    local rows = {
      { tag = "a", duration = 10 },
      { tag = "b", duration = 5 },
      { tag = "a", duration = 7 },
    }

    local out = projection.project_rows(rows, { "tag" }, { "tag" })
    t.eq(#out, 2)
    t.eq(out[1].tag, "a")
    t.eq(out[1].duration, 17)
    t.eq(out[2].tag, "b")
    t.eq(out[2].duration, 5)
  end)

  t.test("project_rows preserves first-seen group order", function()
    local rows = {
      { tag = "z", duration = 1 },
      { tag = "a", duration = 1 },
    }

    local out = projection.project_rows(rows, { "tag" }, { "tag" })
    t.eq(out[1].tag, "z")
    t.eq(out[2].tag, "a")
  end)

  t.test("constrained_quantize shifts a cell up to its committed target", function()
    local rows = { { unrounded_duration = 90 }, { unrounded_duration = 30 } }
    local out = quantize.constrained_quantize(rows, 15, { { members = { 1 }, target = 120 } })
    t.eq(out[1].duration, 120)
    t.eq(out[2].duration, 30)
  end)

  t.test("constrained_quantize rounds a cell all the way down to its target", function()
    -- Regression: a multi-bucket round-down must reach the target, not stop after one cycle over the
    -- members (the loop used to break on a raw iteration count, leaving {90,30}->0 stuck at 30).
    local rows = { { unrounded_duration = 90 }, { unrounded_duration = 30 } }
    local out = quantize.constrained_quantize(rows, 15, { { members = { 1, 2 }, target = 0 } })
    t.eq(out[1].duration + out[2].duration, 0)
  end)
end
