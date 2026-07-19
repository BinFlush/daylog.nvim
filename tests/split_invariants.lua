return function(t)
  local cwd = vim.fn.getcwd()
  local Rng = dofile(cwd .. "/tests/rng.lua")
  local synth = dofile(cwd .. "/tests/log_synth.lua")
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")
  local render = require("daylog.render")
  local summary = require("daylog.summary")
  local split_summary = require("daylog.usecases.split_summary")

  -- Splitting an activity must preserve total time and leave a valid, footing log: the
  -- interval endpoints never move, so the day's minutes are unchanged; only the
  -- breakdown is finer. This fuzzes that over synthesized logs.

  local BASE_SEED = 92143
  local SAMPLE_PER_MODE = 150

  local function raw_total(block)
    local s = summary.summarize_block(block)
    local minutes = 0
    for _, item in ipairs(s.summary_items) do
      minutes = minutes + (item.unrounded_duration or item.duration)
    end
    return minutes, s
  end

  local function apply(lines, edits)
    local out = {}
    for _, line in ipairs(lines) do
      out[#out + 1] = line
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

  -- The buffer as an open file would hold it: log body plus its rendered summary.
  local function buffer_with_summary(block, log_lines)
    local out = {}
    for _, line in ipairs(log_lines) do
      out[#out + 1] = line
    end
    local opts = { quantize_minutes = block.quantize_minutes }
    for _, line in
      ipairs(render.summary_lines(summary.summarize_block(block), block.duration_format, opts))
    do
      out[#out + 1] = line
    end
    return out, opts
  end

  -- A cursor row sitting on the first main summary row `split` can actually act on with these
  -- weights, or nil. A non-logged row is not enough: a partially-committed entry renders a
  -- non-logged *remainder* row backed by no splittable interval (split refuses it with NOTHING),
  -- so the row is only a candidate once a trial split confirms it (a success, or an offset refusal
  -- that the caller skips just the same).
  local function first_splittable(block, buffer, log_count, opts, weights)
    local layout =
      render.summary_layout(summary.summarize_block(block), block.duration_format, opts)
    for _, row in ipairs(layout) do
      if row.kind == render.LAYOUT_KIND.SUMMARY_ITEM and not row.item.logged then
        for i = log_count + 1, #buffer do
          if buffer[i] == row.line then
            local _, err = split_summary.run(buffer, i, weights)
            -- Skip rows the split refuses because a contributing entry carries a logging marker at
            -- any level (!S/!T/!L/!W) -- only a marker-free interval is splittable.
            if err ~= split_summary.NOTHING and err ~= split_summary.REFUSE_LOGGED then
              return i
            end
            break
          end
        end
      end
    end
    return nil
  end

  local function check(seed, mode)
    local wl = synth.generate(Rng.new(seed), mode)
    local analysis = analyze.analyze(document.parse(wl.lines))
    local block = analyze.get_active_log(analysis)
    if not block then
      return nil
    end

    -- A log whose claims contradict each other is never summarized and every entry command refuses
    -- it, split included -- that is the specified behaviour, not a split bug. Skip it.
    if analyze.find_block_diagnostic(analysis, block) then
      return nil
    end

    local before_minutes = raw_total(block)
    local buffer, opts = buffer_with_summary(block, wl.lines)

    -- A weight vector of 2..4 positive parts, varied by seed.
    local rng = Rng.new(seed * 31 + 7)
    local n = rng:int(2, 4)
    local weights = {}
    for i = 1, n do
      weights[i] = rng:int(1, 5)
    end

    local cursor = first_splittable(block, buffer, #wl.lines, opts, weights)
    if not cursor then
      return nil -- no row with a splittable interval (all-logged / only remainder rows); skip
    end

    local result, err = split_summary.run(buffer, cursor, weights)
    if not result then
      if err == split_summary.REFUSE_OFFSET or err == split_summary.REFUSE_LOGGED then
        return nil -- correctly refused: a UTC-offset-crossing cut, or an entry carrying a marker
      end
      return string.format(
        "split refused (%s) on seed=%d mode=%s\n%s",
        err,
        seed,
        mode,
        table.concat(wl.lines, "\n")
      )
    end

    local out = apply(buffer, result.edits)

    local reanalysis = analyze.analyze(document.parse(out))
    if #reanalysis.diagnostics > 0 then
      return string.format(
        "split produced an invalid log on seed=%d mode=%s\n--- before ---\n%s\n--- after ---\n%s",
        seed,
        mode,
        table.concat(buffer, "\n"),
        table.concat(out, "\n")
      )
    end

    local after_block = analyze.get_active_log(reanalysis)
    local after_minutes, after_summary = raw_total(after_block)
    if after_minutes ~= before_minutes then
      return string.format(
        "split changed total minutes %d -> %d on seed=%d mode=%s\n%s",
        before_minutes,
        after_minutes,
        seed,
        mode,
        table.concat(out, "\n")
      )
    end

    local item_min = 0
    for _, item in ipairs(after_summary.summary_items) do
      item_min = item_min + item.duration
    end
    if item_min ~= after_summary.activity_total then
      return string.format(
        "split summary does not foot: items=%d activity=%d on seed=%d mode=%s\n%s",
        item_min,
        after_summary.activity_total,
        seed,
        mode,
        table.concat(out, "\n")
      )
    end

    return nil
  end

  t.test("split preserves total time and validity across random logs (fuzz)", function()
    local master = Rng.new(BASE_SEED)
    for _, mode in ipairs(synth.MODES) do
      for _ = 1, SAMPLE_PER_MODE do
        local err = check(master:int(1, 2147483646), mode)
        if err then
          error(err, 0)
        end
      end
    end
  end)
end
