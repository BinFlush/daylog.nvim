return function(t)
  local footing = dofile(vim.fn.getcwd() .. "/tests/footing_check.lua")

  -- The always-on suite runs a fast, fixed-seed sample of the footing + logging-invariant fuzz
  -- (footing, partition/residual, refresh fixpoint, entry-writer fixpoint) so a regression fails the
  -- gate quickly; the full parameterized sweep (any mode/rounds/seed) lives in `just fuzz`
  -- (tests/fuzz.lua), which now carries the volume via the commit-hash seed. `just fuzz all 200`
  -- reproduces this exact sample.
  local BASE_SEED = 1234567
  local SAMPLE_PER_MODE = 200

  t.test("summary display footing holds across random logs (fuzz)", function()
    local master = footing.Rng.new(BASE_SEED)
    local checked, skipped = 0, 0
    for _, mode in ipairs(footing.synth.MODES) do
      for _ = 1, SAMPLE_PER_MODE do
        local err, contradicted = footing.check(master:int(1, 2147483646), mode)
        if err then
          error(err, 0)
        end
        if contradicted then
          skipped = skipped + 1
        else
          checked = checked + 1
        end
      end
    end

    -- A log whose claims contradict each other is skipped -- it is never summarized, so there is
    -- nothing to foot. The counts ARE the coverage: a generator that drifted into producing only
    -- contradictions would skip everything and pass vacuously. Assert both that real logs are being
    -- checked and that contradictions still occur, since those exercise the refusal path.
    t.ok(
      checked > skipped,
      string.format("most synthesized logs must resolve (checked %d, skipped %d)", checked, skipped)
    )
    t.ok(skipped > 0, "some synthesized logs must contradict, or the refusal path is untested")
  end)
end
