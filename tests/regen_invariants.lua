return function(t)
  -- Property test for the load-bearing summary-regeneration invariant: regen is a
  -- pure projection over the blots, so it must NEVER edit the source. Whatever state
  -- the summary is in -- current, drifted, half-deleted, gone -- rebuilding it leaves
  -- the blots (header + timestamped lines + notes) byte-for-byte unchanged.
  --
  -- A ladder of guarantees, each a property test over the synth + rng harness:
  --   Rung 1 -- regen never edits the blots (rules out the scariest bug: silent loss).
  --   Rung 2 -- regen is idempotent (the auto-refresh autocmd relies on a fixed point).
  --   Rung 3 -- regen never eats a body note (the "never corrupt authored content" rule),
  --             even a blank-separated one, even when the summary banner is destroyed.
  -- Plus: an arbitrarily-corrupted banner reclaims in place to one clean summary. Rung 3
  -- and the reclaim guard the two bugs the realistic-generator bake-off surfaced.
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

  -- Rung 2: refresh is idempotent -- one pass reaches a fixed point, so a second pass
  -- makes no edits. This is the loop-free guarantee the auto-refresh autocmd relies on
  -- (apply_refresh early-returns when #edits == 0); the documented "an already-current
  -- summary yields no edit". The critical thing it stresses: refresh must be able to
  -- RE-LOCATE the summary it just wrote (whether it replaced an existing region or
  -- created a fresh one after a mutation destroyed the old one) -- otherwise the second
  -- pass appends yet another summary and the buffer never stabilises.
  t.test(
    "regen is idempotent: a second refresh after any summary mutation makes no edits",
    function()
      local master = Rng.new(20260621)

      for _, mode in ipairs(synth.MODES) do
        for _ = 1, 300 do
          local seed = master:int(1, 2147483646)
          local rng = Rng.new(seed)

          local source = synth.generate(rng, mode).lines
          local k = #source

          local materialized = regen(source)
          if #materialized > k then
            local mutator = MUTATORS[rng:int(1, #MUTATORS)]
            local mutated = mutator[2](rng, materialized, k)

            -- One refresh should land on a fixed point...
            local once = regen(mutated)
            -- ...so refreshing that result must want nothing further.
            local again = refresh_summaries.run(once)

            if #again.edits > 0 then
              error(
                string.format(
                  "%s seed=%d mutator=%s: refresh is not idempotent -- the second pass still "
                    .. "wants %d edit(s) (the buffer never stabilises)",
                  mode,
                  seed,
                  mutator[1],
                  #again.edits
                ),
                0
              )
            end
          end
        end
      end
    end
  )

  -- Rung 3: a body note is NEVER eaten -- not even one separated from its blot by a
  -- blank line, and not even when the summary banner is destroyed. This is the load-
  -- bearing "never corrupt authored content" guarantee. The realistic-generator bake-off
  -- found a recognizer that aligned across the separator blank and swept such a note into
  -- the regenerated summary; this pins it shut. Inject a blank-separated note into the
  -- body, apply every summary mutator (including banner deletion), and assert the note --
  -- and every source row above it -- survive each regen.
  t.test("regen never eats a body note, even blank-separated, even with a dead banner", function()
    local master = Rng.new(20260622)
    local NOTE = "BODY_NOTE_KEEPME a freeform authored line"

    for _, mode in ipairs(synth.MODES) do
      for _ = 1, 100 do
        local seed = master:int(1, 2147483646)
        local rng = Rng.new(seed)

        local source = synth.generate(rng, mode).lines
        local k = #source
        local materialized = regen(source)
        if #materialized > k then
          -- A blank-separated body note: source, a blank, the NOTE, then the summary.
          local withnote = {}
          for i = 1, k do
            withnote[#withnote + 1] = source[i]
          end
          withnote[#withnote + 1] = ""
          withnote[#withnote + 1] = NOTE
          for i = k + 1, #materialized do
            withnote[#withnote + 1] = materialized[i]
          end
          local note_k = k + 2 -- body now spans rows 1..note_k

          for _, mutator in ipairs(MUTATORS) do
            local result = regen(mutator[2](rng, withnote, note_k))

            local kept = false
            for _, line in ipairs(result) do
              if line == NOTE then
                kept = true
                break
              end
            end
            if not kept then
              error(
                string.format(
                  "%s seed=%d mutator=%s: a blank-separated body note was EATEN by regen",
                  mode,
                  seed,
                  mutator[1]
                ),
                0
              )
            end

            for i = 1, k do
              if result[i] ~= source[i] then
                error(
                  string.format(
                    "%s seed=%d mutator=%s: body row %d changed by regen",
                    mode,
                    seed,
                    mutator[1],
                    i
                  ),
                  0
                )
              end
            end
          end
        end
      end
    end
  end)

  -- The character-level banner reclaim (Needleman-Wunsch edit distance over the banner
  -- line): an arbitrary light corruption of `--- summary q=N d=fmt ---` -- a dropped
  -- dash, pasted prefix/suffix junk, a typo, a misspelling -- is still recognized as the
  -- banner (within edit distance), so the summary is reclaimed IN PLACE to a single clean
  -- copy: no duplicate, no lingering garbage, body untouched. Each corruption stays well
  -- within the similarity threshold, so a correct refresh restores the exact canonical.
  t.test("regen reclaims an arbitrarily-corrupted banner to one clean summary", function()
    local master = Rng.new(20260623)
    local CORRUPTORS = {
      {
        "dropped dash",
        function(b)
          return (b:gsub("^%-%-%-", "--"))
        end,
      },
      {
        "prefix junk",
        function(b)
          return "hello" .. b
        end,
      },
      {
        "suffix junk",
        function(b)
          return b .. "wefweofi"
        end,
      },
      {
        "misspelling",
        function(b)
          return (b:gsub("summary", "sumary"))
        end,
      },
      {
        "one-char typo",
        function(b)
          local mid = math.floor(#b / 2)
          local c = (b:sub(mid, mid) == "x") and "y" or "x"
          return b:sub(1, mid - 1) .. c .. b:sub(mid + 1)
        end,
      },
    }

    for _, mode in ipairs(synth.MODES) do
      for _ = 1, 100 do
        local seed = master:int(1, 2147483646)
        local source = synth.generate(Rng.new(seed), mode).lines
        local k = #source
        local materialized = regen(source)

        local banner_row
        for row = k + 1, #materialized do
          if materialized[row]:match("^%-%-%- summary q=%d+ d=%a+ %-%-%-$") then
            banner_row = row
            break
          end
        end

        if banner_row then
          for _, corruptor in ipairs(CORRUPTORS) do
            local mutated = copy(materialized)
            mutated[banner_row] = corruptor[2](materialized[banner_row])
            local result = regen(mutated)

            local same = #result == #materialized
            if same then
              for i = 1, #result do
                if result[i] ~= materialized[i] then
                  same = false
                  break
                end
              end
            end
            if not same then
              error(
                string.format(
                  "%s seed=%d corruptor=%s: a corrupted banner did not reclaim to the exact "
                    .. "canonical summary (duplicate / lingering junk / body change)",
                  mode,
                  seed,
                  corruptor[1]
                ),
                0
              )
            end
          end
        end
      end
    end
  end)
end
