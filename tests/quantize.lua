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
    -- The 67-min row was logged externally at 60 (1.00h). A later 2-min row is appended.
    -- Largest-remainder alone would hand the new bucket to the 67-min row's bigger
    -- remainder and restate it to 75; pinning holds it at 60 and the leftover bucket
    -- (budget 75 - 60 = 15) flows to the 2-min row instead.
    local rows = {
      { unrounded_duration = 67, logged_minutes = 60 },
      { unrounded_duration = 2 },
    }

    local result = quantize.quantize_rows(rows, 15, 75)
    t.eq(result[1].duration, 60)
    t.eq(result[1].error_minutes, 7)
    t.eq(result[2].duration, 15)
    t.eq(result[2].error_minutes, -13)
    -- Foots: the displayed total is still the honest rounded total.
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
end
