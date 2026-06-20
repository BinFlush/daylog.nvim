return function(t)
  local footing = dofile(vim.fn.getcwd() .. "/tests/footing_check.lua")

  -- The always-on suite runs a fast, fixed-seed sample of the footing fuzz so a
  -- regression fails the gate quickly; the full parameterized sweep (any
  -- mode/rounds/seed) lives in `just fuzz` (tests/fuzz.lua). `just fuzz all 400`
  -- reproduces this exact sample.
  local BASE_SEED = 1234567
  local SAMPLE_PER_MODE = 400

  t.test("summary display footing holds across random blotters (fuzz)", function()
    local master = footing.Rng.new(BASE_SEED)
    for _, mode in ipairs(footing.synth.MODES) do
      for _ = 1, SAMPLE_PER_MODE do
        local err = footing.check(master:int(1, 2147483646), mode)
        if err then
          error(err, 0)
        end
      end
    end
  end)
end
