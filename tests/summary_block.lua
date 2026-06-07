return function(t)
  local analyze = require("worklog.analyze")
  local document = require("worklog.document")
  local summary_block = require("worklog.summary_block")

  local function analyze_lines(lines)
    return analyze.analyze(document.parse(lines))
  end

  t.test("summary_block finds an exact summary region for the active worklog", function()
    local analysis = analyze_lines({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary ---",
      "1.00h plan",
      "",
      "--- totals ---",
      "1.00h workday",
    })

    t.eq(summary_block.find(analysis, analyze.get_active_worklog(analysis)), {
      start_row = 5,
      end_row = 10,
    })
  end)

  t.test("summary_block finds a quantized summary region", function()
    local analysis = analyze_lines({
      "--- worklog quantize=30 ---",
      "08:00 plan",
      "08:34 done",
      "",
      "--- summary ---",
      "0.50h (+4m) plan",
      "",
      "--- totals ---",
      "0.50h (+4m) workday",
    })

    t.eq(summary_block.find(analysis, analyze.get_active_worklog(analysis)), {
      start_row = 5,
      end_row = 10,
    })
  end)

  t.test("summary_block still recognizes a legacy exact/quantized summary header", function()
    local analysis = analyze_lines({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary quantized ---",
      "1.00h (+0m) plan",
      "",
      "--- totals quantized ---",
      "1.00h (+0m) workday",
    })

    -- Summaries written by an older worklog.nvim still resolve, so a refresh can
    -- locate and rewrite them to the current kind-less form.
    t.eq(summary_block.find(analysis, analyze.get_active_worklog(analysis)), {
      start_row = 5,
      end_row = 10,
    })
  end)

  t.test("summary_block returns nil when the worklog has no summary", function()
    local analysis = analyze_lines({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
    })

    t.eq(summary_block.find(analysis, analyze.get_active_worklog(analysis)), nil)
  end)

  t.test("summary_block bounds a region to its worklog and ignores others", function()
    local analysis = analyze_lines({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary ---",
      "1.00h plan",
      "",
      "--- totals ---",
      "1.00h workday",
      "",
      "--- worklog ---",
      "10:00 tea",
      "11:00 done",
    })

    -- The first worklog's summary stops after its totals line (row 9), trimming
    -- the blank separator before the second worklog; the active (second) worklog
    -- has no summary of its own.
    t.eq(summary_block.find(analysis, analysis.worklog_blocks[1]), {
      start_row = 5,
      end_row = 10,
    })
    t.eq(summary_block.find(analysis, analysis.worklog_blocks[2]), nil)
  end)
end
