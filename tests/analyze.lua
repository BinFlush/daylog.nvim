return function(t)
  local analyze = require("worklog.analyze")
  local document = require("worklog.document")

  t.test("analyze derives worklog blocks, items, and effective labels", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog default=#ProjectOrion quantize=30 ---",
      "08:00 plan",
      "note about planning",
      "08:30 call #sales",
      "09:00 coffee #ooo",
      "10:00 done",
      "",
      "--- summary exact ---",
      "1.00h activity",
      "",
      "--- worklog ---",
      "11:00 tea",
      "12:00 done",
    }))

    t.eq(analysis.kind, "analysis")
    t.eq(analysis.default_label, "ProjectOrion")
    t.eq(analysis.quantize_minutes, 30)
    t.eq(analysis.diagnostics, {})
    t.eq(#analysis.blocks, 3)
    t.eq(#analysis.worklog_blocks, 2)

    local first = analysis.worklog_blocks[1]
    t.eq(first.start_row, 1)
    t.eq(first.body_start_row, 2)
    t.eq(first.end_row, 8)
    t.eq(first.header_default_label, "ProjectOrion")
    t.eq(first.header_quantize_minutes, 30)
    t.eq(first.default_label, "ProjectOrion")
    t.eq(first.quantize_minutes, 30)
    t.eq(#first.body_nodes, 6)
    t.eq(first.items, {
      {
        kind = "entry_item",
        entry = analysis.document.nodes[2],
        nodes = { analysis.document.nodes[2], analysis.document.nodes[3] },
        start_row = 2,
        end_row = 3,
        minutes = 480,
        text = "plan",
        explicit_label = nil,
        label = "ProjectOrion",
        excluded = false,
      },
      {
        kind = "entry_item",
        entry = analysis.document.nodes[4],
        nodes = { analysis.document.nodes[4] },
        start_row = 4,
        end_row = 4,
        minutes = 510,
        text = "call",
        explicit_label = "sales",
        label = "sales",
        excluded = false,
      },
      {
        kind = "entry_item",
        entry = analysis.document.nodes[5],
        nodes = { analysis.document.nodes[5] },
        start_row = 5,
        end_row = 5,
        minutes = 540,
        text = "coffee",
        explicit_label = "ooo",
        label = "ooo",
        excluded = true,
      },
      {
        kind = "entry_item",
        entry = analysis.document.nodes[6],
        nodes = { analysis.document.nodes[6], analysis.document.nodes[7] },
        start_row = 6,
        end_row = 7,
        minutes = 600,
        text = "done",
        explicit_label = nil,
        label = "ProjectOrion",
        excluded = false,
      },
    })
    t.eq(first.entries, {
      {
        row = 2,
        minutes = 480,
        text = "plan",
        explicit_label = nil,
        label = "ProjectOrion",
        excluded = false,
      },
      {
        row = 4,
        minutes = 510,
        text = "call",
        explicit_label = "sales",
        label = "sales",
        excluded = false,
      },
      {
        row = 5,
        minutes = 540,
        text = "coffee",
        explicit_label = "ooo",
        label = "ooo",
        excluded = true,
      },
      {
        row = 6,
        minutes = 600,
        text = "done",
        explicit_label = nil,
        label = "ProjectOrion",
        excluded = false,
      },
    })

    t.eq(analyze.get_active_worklog(analysis), analysis.worklog_blocks[2])
    t.eq(analyze.get_worklog_at_row(analysis, 1), analysis.worklog_blocks[1])
    t.eq(analyze.get_worklog_at_row(analysis, 11), analysis.worklog_blocks[2])
    t.eq(analyze.get_worklog_at_row(analysis, 8), nil)
  end)

  t.test("analyze reports header, invalid entry, and unordered diagnostics", function()
    local analysis = analyze.analyze(document.parse({
      "--- summary exact ---",
      "1.00h activity",
      "--- worklog default=#sales quantize=60 ---",
      "09:00 later",
      "08:00 earlier",
      "08:30 broken #sales #meeting",
      "10:00 done",
    }))

    t.eq(analysis.default_label, nil)
    t.eq(analysis.diagnostics, {
      {
        code = "invalid_first_header",
        severity = "error",
        row = 1,
        message = "worklog: first line must be a worklog header such as --- worklog --- or --- worklog default=#label ---",
      },
      {
        code = "unexpected_default_label",
        severity = "error",
        row = 3,
        message = "worklog: only the first worklog header may declare a default label",
      },
      {
        code = "unexpected_quantize",
        severity = "error",
        row = 3,
        message = "worklog: only the first worklog header may declare quantize=<minutes>",
      },
      {
        code = "invalid_entry",
        severity = "error",
        row = 6,
        message = "multiple trailing labels are not allowed",
      },
      {
        code = "unordered_timestamps",
        severity = "error",
        row = 4,
        row2 = 5,
        message = "timestamps are not in non-decreasing order",
      },
    })
  end)

  t.test("analyze reports invalid worklog header options", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog quantize=0 default=sales nope unknown=bar ---",
      "08:00 plan",
      "09:00 done",
    }))

    t.eq(analysis.quantize_minutes, 15)
    t.eq(analysis.diagnostics, {
      {
        code = "invalid_worklog_header_option",
        severity = "error",
        row = 1,
        message = "worklog header option quantize must be a positive integer",
      },
      {
        code = "invalid_worklog_header_option",
        severity = "error",
        row = 1,
        message = "worklog header option default must be in the form default=#label",
      },
      {
        code = "invalid_worklog_header_option",
        severity = "error",
        row = 1,
        message = "unknown worklog header option: unknown",
      },
      {
        code = "invalid_worklog_header_option",
        severity = "error",
        row = 1,
        message = "worklog header options must use key=value: nope",
      },
    })
  end)

  t.test("analyze reports duplicate worklog header options", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog default=#ProjectOrion default=#sales quantize=30 quantize=60 ---",
      "08:00 plan",
      "09:00 done",
    }))

    t.eq(analysis.default_label, "ProjectOrion")
    t.eq(analysis.quantize_minutes, 30)
    t.eq(analysis.diagnostics, {
      {
        code = "invalid_worklog_header_option",
        severity = "error",
        row = 1,
        message = "duplicate worklog header option: default",
      },
      {
        code = "invalid_worklog_header_option",
        severity = "error",
        row = 1,
        message = "duplicate worklog header option: quantize",
      },
    })
  end)

  t.test("analyze reports invalid options on later worklog headers", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog default=#ProjectOrion ---",
      "08:00 plan",
      "09:00 done",
      "--- worklog default=sales quantize=0 nope unknown=bar ---",
      "10:00 tea",
      "11:00 done",
    }))

    t.eq(analysis.diagnostics, {
      {
        code = "invalid_worklog_header_option",
        severity = "error",
        row = 4,
        message = "worklog header option default must be in the form default=#label",
      },
      {
        code = "invalid_worklog_header_option",
        severity = "error",
        row = 4,
        message = "worklog header option quantize must be a positive integer",
      },
      {
        code = "invalid_worklog_header_option",
        severity = "error",
        row = 4,
        message = "unknown worklog header option: unknown",
      },
      {
        code = "invalid_worklog_header_option",
        severity = "error",
        row = 4,
        message = "worklog header options must use key=value: nope",
      },
      {
        code = "unexpected_default_label",
        severity = "error",
        row = 4,
        message = "worklog: only the first worklog header may declare a default label",
      },
      {
        code = "unexpected_quantize",
        severity = "error",
        row = 4,
        message = "worklog: only the first worklog header may declare quantize=<minutes>",
      },
    })
  end)

  t.test("analyze keeps unlabeled entries unlabeled without a default", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog ---",
      "08:00 plan",
      "08:30 call #sales",
      "09:00 done",
    }))

    t.eq(analysis.default_label, nil)
    t.eq(analysis.worklog_blocks[1].entries, {
      {
        row = 2,
        minutes = 480,
        text = "plan",
        explicit_label = nil,
        label = nil,
        excluded = false,
      },
      {
        row = 3,
        minutes = 510,
        text = "call",
        explicit_label = "sales",
        label = "sales",
        excluded = false,
      },
      {
        row = 4,
        minutes = 540,
        text = "done",
        explicit_label = nil,
        label = nil,
        excluded = false,
      },
    })
  end)

  t.test("analyze helpers expose structural and block diagnostics", function()
    local analysis = analyze.analyze(document.parse({
      "--- summary exact ---",
      "1.00h activity",
      "--- worklog ---",
      "09:00 later",
      "08:00 earlier",
      "08:30 broken #sales #meeting",
      "10:00 done",
    }))

    t.eq(analyze.structural_error(analysis), "worklog: first line must be a worklog header such as --- worklog --- or --- worklog default=#label ---")
    t.eq(analyze.find_block_diagnostic(analysis, analysis.worklog_blocks[1]), {
      code = "invalid_entry",
      severity = "error",
      row = 6,
      message = "multiple trailing labels are not allowed",
    })
  end)
end
