return function(t)
  -- Property test for the load-bearing summary-regeneration invariant: regen is a
  -- pure projection over the blots, so it must NEVER edit the source. Whatever state
  -- the summary is in -- current, drifted, half-deleted, gone -- rebuilding it leaves
  -- the blots (header + timestamped lines + notes) byte-for-byte unchanged.
  --
  -- Rung 1 of a ladder (see the plan): blots-unchanged is the floor that rules out
  -- the scariest bug class, silent corruption/loss of a blot. Idempotence and
  -- self-heal-to-canonical come later.
  --
  -- Pure throughout: refresh_summaries.run(lines) -> { edits } IS the regen, so the
  -- test is line-list in / line-list out (no Neovim buffer), reusing the synth + rng
  -- harness like balance_invariants / footing_check.
  --
  -- Soundness of the top-K check: refresh only ever replaces the located summary
  -- region or inserts at the block's last content row, both at row >= K (the summary
  -- is always appended below the K source lines). So it structurally cannot write
  -- above line K; comparing the top K lines is exactly "the blots are unchanged", and
  -- a bug that wrote into the source would fail it loudly.
  local cwd = vim.fn.getcwd()
  local refresh_summaries = require("blotter.usecases.refresh_summaries")
  local Rng = dofile(cwd .. "/tests/rng.lua")
  local synth = dofile(cwd .. "/tests/blotter_synth.lua")

  -- Apply an edit script ({ start_index, end_index, lines }, 0-based, pre-sorted
  -- highest-start-first by the use case) to a plain line list -- the pure mirror of
  -- the buffer's nvim_buf_set_lines, identical in shape to rename.lua's helper.
  local function apply(lines, edits)
    local out = {}
    for i, line in ipairs(lines) do
      out[i] = line
    end

    for _, edit in ipairs(edits) do
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

  local function regen(lines)
    return apply(lines, refresh_summaries.run(lines).edits)
  end

  -- A copy of `lines` for non-destructive mutation.
  local function copy(lines)
    local out = {}
    for i, line in ipairs(lines) do
      out[i] = line
    end
    return out
  end

  -- Summary-flavoured junk that can never be read as a blot (no leading HH:MM), so a
  -- mutation fiddles with the summary without smuggling in a new timestamped entry.
  local JUNK = { "garbage", "1.5h orphan", "xxxx yyyy", "--- stray", "total: maybe", "(+9m) drift" }

  -- Each mutator rewrites ONLY the summary region (rows k+1 .. #lines) and returns the
  -- new lines. They span gentle (tweak a row) to aggressive (delete the header / the
  -- whole summary), to exercise every regen path: locate-and-replace, locate-fail-and-
  -- recreate, and structural-error-no-op. All are no-ops on an empty region.
  local MUTATORS = {
    {
      "noop",
      function(_, lines)
        return copy(lines)
      end,
    },
    {
      "corrupt_digit",
      function(rng, lines, k)
        local out = copy(lines)
        -- Walk from a random summary row to find one with a digit, then bump it.
        for step = 0, #out - k - 1 do
          local row = k + 1 + (rng:int(0, #out - k - 1) + step) % (#out - k)
          local digits = {}
          for pos = 1, #out[row] do
            if out[row]:sub(pos, pos):match("%d") then
              digits[#digits + 1] = pos
            end
          end
          if #digits > 0 then
            local pos = rng:choice(digits)
            local d = tonumber(out[row]:sub(pos, pos))
            out[row] = out[row]:sub(1, pos - 1) .. tostring((d + 1) % 10) .. out[row]:sub(pos + 1)
            return out
          end
        end
        return out
      end,
    },
    {
      "blank_row",
      function(rng, lines, k)
        local out = copy(lines)
        out[rng:int(k + 1, #out)] = ""
        return out
      end,
    },
    {
      "delete_row",
      function(rng, lines, k)
        local out = copy(lines)
        table.remove(out, rng:int(k + 1, #out))
        return out
      end,
    },
    {
      "duplicate_row",
      function(rng, lines, k)
        local out = copy(lines)
        local row = rng:int(k + 1, #out)
        table.insert(out, row, out[row])
        return out
      end,
    },
    {
      "swap_rows",
      function(rng, lines, k)
        local out = copy(lines)
        if #out - k >= 2 then
          local a = rng:int(k + 1, #out)
          local b = rng:int(k + 1, #out)
          out[a], out[b] = out[b], out[a]
        end
        return out
      end,
    },
    {
      "insert_junk",
      function(rng, lines, k)
        local out = copy(lines)
        table.insert(out, rng:int(k + 1, #out + 1), rng:choice(JUNK))
        return out
      end,
    },
    {
      "delete_header",
      function(rng, lines, k)
        local out = copy(lines)
        -- Drop a `--- ... ---` divider (summary/totals header) to make the region
        -- unlocatable; fall back to deleting any row if somehow none is present.
        local headers = {}
        for row = k + 1, #out do
          if out[row]:match("^%-%-%-") then
            headers[#headers + 1] = row
          end
        end
        table.remove(out, #headers > 0 and rng:choice(headers) or rng:int(k + 1, #out))
        return out
      end,
    },
    {
      "delete_all",
      function(_, lines, k)
        local out = {}
        for i = 1, k do
          out[i] = lines[i]
        end
        return out
      end,
    },
    {
      "truncate",
      function(rng, lines, k)
        local out = {}
        local cut = rng:int(k + 1, #lines)
        for i = 1, cut - 1 do
          out[i] = lines[i]
        end
        return out
      end,
    },
  }

  t.test("regen never edits the blots (random summary mutation, all synth modes)", function()
    local master = Rng.new(20260620)
    local materialized_rounds = 0

    for _, mode in ipairs(synth.MODES) do
      for _ = 1, 300 do
        local seed = master:int(1, 2147483646)
        local rng = Rng.new(seed)

        local source = synth.generate(rng, mode).lines
        local k = #source

        -- Materialize: one regen appends the canonical summary below the blots.
        local materialized = regen(source)
        if #materialized > k then
          materialized_rounds = materialized_rounds + 1

          local mutator = MUTATORS[rng:int(1, #MUTATORS)]
          local mutated = mutator[2](rng, materialized, k)
          local result = regen(mutated)

          for i = 1, k do
            if result[i] ~= source[i] then
              error(
                string.format(
                  "%s seed=%d mutator=%s: blot row %d changed after regen:\n  was: %s\n  now: %s",
                  mode,
                  seed,
                  mutator[1],
                  i,
                  tostring(source[i]),
                  tostring(result[i])
                ),
                0
              )
            end
          end
        end
      end
    end

    -- Guard the guard: the synth always yields a valid blotter, so every round must
    -- have actually materialized a summary (else the assertion above is vacuous).
    t.ok(materialized_rounds == 3 * 300, "every round materialized a summary to mutate")
  end)
end
