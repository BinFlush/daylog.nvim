return function(t)
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")
  local rename_summary = require("daylog.usecases.rename_summary")
  local render = require("daylog.render")
  local summary = require("daylog.summary")
  local support = require("daylog.usecases.support")

  -- A full buffer (log body + its generated summary), mirroring tests/map_summary.lua, so a range
  -- can cover real entry rows exactly as in an open file.
  local function buffer_with_summary(log_lines)
    local block = analyze.get_active_log(analyze.analyze(document.parse(log_lines)))
    local out = {}
    for _, line in ipairs(log_lines) do
      out[#out + 1] = line
    end
    out[#out + 1] = ""
    out[#out + 1] = ""
    for _, line in
      ipairs(render.summary_lines(summary.summarize_block(block), block.duration_format, {
        leading_blank = false,
        quantize_minutes = block.quantize_minutes,
      }))
    do
      out[#out + 1] = line
    end
    return out
  end

  local function run(lines, r1, r2, value)
    local result, err = rename_summary.run_range(lines, r1, r2, value)
    if not result then
      return nil, err
    end
    return support.apply_edits(lines, result.edits)
  end

  t.test("ranged rename sets every selected entry to one description", function()
    local lines =
      { "--- log ---", "08:00 fix login", "09:00 review pr", "10:00 deploy", "12:00 done" }
    local out = run(lines, 2, 3, "meeting")
    t.eq(out[2], "08:00 meeting")
    t.eq(out[3], "09:00 meeting")
    t.eq(out[4], "10:00 deploy") -- out of range, untouched
    t.eq(out[5], "12:00 done")
  end)

  t.test("ranged rename rebuilds the summary, folding the renamed entries", function()
    local lines =
      buffer_with_summary({ "--- log ---", "08:00 fix login", "10:00 review pr", "12:00 done" })
    local out = run(lines, 2, 3, "meeting")
    local joined = table.concat(out, "\n")
    t.eq(out[2], "08:00 meeting")
    t.eq(out[3], "10:00 meeting")
    t.ok(joined:match("meeting") ~= nil, "the summary shows the folded activity")
    t.ok(not joined:match("fix login"), "the old text is gone everywhere")
    t.ok(not joined:match("review pr"), "the old text is gone everywhere")
  end)

  t.test("an empty selection is refused", function()
    local lines = { "--- log ---", "08:00 a", "09:00 done" }
    local _, err = rename_summary.run_range(lines, 1, 1, "x")
    t.eq(err, rename_summary.NO_ENTRIES_IN_RANGE)
  end)
end
