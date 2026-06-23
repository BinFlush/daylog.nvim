return function(t)
  local split = require("daylog.split")

  -- The usecase and fuzz suites assert that a split preserves total time and that the
  -- summary still foots; these pin the apportionment arithmetic at the module boundary.

  local function row_sums_match(matrix, durations)
    for j, row in ipairs(matrix) do
      local sum = 0
      for _, v in ipairs(row) do
        sum = sum + v
      end
      if sum ~= durations[j] then
        return false
      end
    end
    return true
  end

  t.test("allocate splits one interval evenly", function()
    t.eq(split.allocate({ 60 }, { 1, 1 }), { { 30, 30 } })
  end)

  t.test("allocate splits one interval by weight", function()
    t.eq(split.allocate({ 60 }, { 2, 1 }), { { 40, 20 } })
  end)

  t.test("allocate distributes a remainder by largest share, ties to lower index", function()
    -- 10 / 3 = 3.33 each; the single leftover minute goes to the first part.
    t.eq(split.allocate({ 10 }, { 1, 1, 1 }), { { 4, 3, 3 } })
  end)

  t.test("allocate compensates a short interval in a later, longer one", function()
    -- Targets are p = [1/6, 5/6] of 12 = [2, 10]. The 2-minute interval cannot afford
    -- part 1's 0.33 share, so it goes entirely to part 2; the debt is repaid in the
    -- 10-minute interval and the column totals land exactly on target.
    local matrix = split.allocate({ 2, 10 }, { 1, 5 })
    t.eq(matrix, { { 0, 2 }, { 2, 8 } })
    t.eq(matrix[1][1] + matrix[2][1], 2)
    t.eq(matrix[1][2] + matrix[2][2], 10)
  end)

  t.test("allocate drops a part whose total share rounds to zero", function()
    t.eq(split.allocate({ 10 }, { 100, 1 }), { { 10, 0 } })
  end)

  t.test("allocate keeps exact row sums across many intervals", function()
    local durations = { 7, 13, 2, 41, 1, 28 }
    local matrix = split.allocate(durations, { 3, 2, 1 })
    t.ok(row_sums_match(matrix, durations), "every interval must sum to its duration")
  end)

  t.test("allocate accepts unnormalized float weights", function()
    t.eq(split.allocate({ 60 }, { 1.5, 0.5 }), { { 45, 15 } })
  end)

  t.test("allocate is deterministic", function()
    local a = split.allocate({ 17, 4, 23 }, { 5, 3, 2, 1 })
    local b = split.allocate({ 17, 4, 23 }, { 5, 3, 2, 1 })
    t.eq(a, b)
  end)

  t.test("parts lists present sub-activities in index order with offsets", function()
    t.eq(split.parts({ 2, 8 }), {
      { index = 1, offset = 0, minutes = 2 },
      { index = 2, offset = 2, minutes = 8 },
    })
  end)

  t.test(
    "parts drops zero parts and starts the first present part at the interval start",
    function()
      -- Part 1 is absent, so part 2 begins at offset 0 (it becomes the renamed original).
      t.eq(split.parts({ 0, 2 }), { { index = 2, offset = 0, minutes = 2 } })
    end
  )
end
