return function(t)
  local analyze = require("worklog.analyze")
  local document = require("worklog.document")
  local INVALID_FIRST_HEADER_MESSAGE = "worklog: first line must be a worklog header such as "
    .. "--- worklog --- or --- worklog #ClientA @office quantize=30 ---"

  t.test("analyze derives worklog blocks, items, and sticky metadata", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog #ProjectOrion @office quantize=30 duration=hhmm ---",
      "08:00 plan",
      "note about planning",
      "08:30 call @home",
      "09:00 coffee #ooo",
      "09:30 prep",
      "10:00 done #ProjectOrion @client",
      "",
      "--- summary exact ---",
      "1.00h activity",
      "",
      "--- worklog #internal @office ---",
      "11:00 tea",
      "12:00 done",
    }))

    t.eq(analysis.kind, "analysis")
    t.eq(analysis.diagnostics, {})
    t.eq(#analysis.blocks, 3)
    t.eq(#analysis.worklog_blocks, 2)

    local first = analysis.worklog_blocks[1]
    t.eq(first.start_row, 1)
    t.eq(first.body_start_row, 2)
    t.eq(first.end_row, 9)
    t.eq(first.header_tag, "ProjectOrion")
    t.eq(first.header_location, "office")
    t.eq(first.header_quantize_minutes, 30)
    t.eq(first.header_duration_format, "hhmm")
    t.eq(first.quantize_minutes, 30)
    t.eq(first.duration_format, "hhmm")
    t.eq(#first.body_nodes, 7)
    t.eq(first.entry_items, {
      {
        kind = "entry_item",
        entry = analysis.document.nodes[2],
        nodes = { analysis.document.nodes[2], analysis.document.nodes[3] },
        start_row = 2,
        end_row = 3,
        minutes = 480,
        text = "plan",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "ProjectOrion",
        location = "office",
        workday_excluded = false,
        logged = false,
      },
      {
        kind = "entry_item",
        entry = analysis.document.nodes[4],
        nodes = { analysis.document.nodes[4] },
        start_row = 4,
        end_row = 4,
        minutes = 510,
        text = "call",
        explicit_tag = nil,
        explicit_location = "home",
        tag = "ProjectOrion",
        location = "home",
        workday_excluded = false,
        logged = false,
      },
      {
        kind = "entry_item",
        entry = analysis.document.nodes[5],
        nodes = { analysis.document.nodes[5] },
        start_row = 5,
        end_row = 5,
        minutes = 540,
        text = "coffee",
        explicit_tag = "ooo",
        explicit_location = nil,
        tag = "ooo",
        location = "home",
        workday_excluded = true,
        logged = false,
      },
      {
        kind = "entry_item",
        entry = analysis.document.nodes[6],
        nodes = { analysis.document.nodes[6] },
        start_row = 6,
        end_row = 6,
        minutes = 570,
        text = "prep",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "ooo",
        location = "home",
        workday_excluded = true,
        logged = false,
      },
      {
        kind = "entry_item",
        entry = analysis.document.nodes[7],
        nodes = { analysis.document.nodes[7], analysis.document.nodes[8] },
        start_row = 7,
        end_row = 8,
        minutes = 600,
        text = "done",
        explicit_tag = "ProjectOrion",
        explicit_location = "client",
        tag = "ProjectOrion",
        location = "client",
        workday_excluded = false,
        logged = false,
      },
    })
    t.eq(first.entries, {
      {
        row = 2,
        minutes = 480,
        text = "plan",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "ProjectOrion",
        location = "office",
        workday_excluded = false,
        logged = false,
      },
      {
        row = 4,
        minutes = 510,
        text = "call",
        explicit_tag = nil,
        explicit_location = "home",
        tag = "ProjectOrion",
        location = "home",
        workday_excluded = false,
        logged = false,
      },
      {
        row = 5,
        minutes = 540,
        text = "coffee",
        explicit_tag = "ooo",
        explicit_location = nil,
        tag = "ooo",
        location = "home",
        workday_excluded = true,
        logged = false,
      },
      {
        row = 6,
        minutes = 570,
        text = "prep",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "ooo",
        location = "home",
        workday_excluded = true,
        logged = false,
      },
      {
        row = 7,
        minutes = 600,
        text = "done",
        explicit_tag = "ProjectOrion",
        explicit_location = "client",
        tag = "ProjectOrion",
        location = "client",
        workday_excluded = false,
        logged = false,
      },
    })

    local second = analysis.worklog_blocks[2]
    t.eq(second.header_tag, "internal")
    t.eq(second.header_location, "office")
    t.eq(second.header_quantize_minutes, nil)
    t.eq(second.quantize_minutes, 15)
    t.eq(second.header_duration_format, nil)
    t.eq(second.duration_format, "decimal")
    t.eq(second.entries, {
      {
        row = 13,
        minutes = 660,
        text = "tea",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "internal",
        location = "office",
        workday_excluded = false,
        logged = false,
      },
      {
        row = 14,
        minutes = 720,
        text = "done",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "internal",
        location = "office",
        workday_excluded = false,
        logged = false,
      },
    })

    t.eq(analyze.get_active_worklog(analysis), analysis.worklog_blocks[2])
    t.eq(analyze.get_worklog_at_row(analysis, 1), analysis.worklog_blocks[1])
    t.eq(analyze.get_worklog_at_row(analysis, 13), analysis.worklog_blocks[2])
    t.eq(analyze.get_worklog_at_row(analysis, 9), nil)
  end)

  t.test("analyze carries logged state without making it sticky", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan !L",
      "09:00 call @home",
      "10:00 done !L",
    }))

    t.eq(analysis.worklog_blocks[1].entries, {
      {
        row = 2,
        minutes = 480,
        text = "plan",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "ProjectOrion",
        location = "office",
        workday_excluded = false,
        logged = true,
      },
      {
        row = 3,
        minutes = 540,
        text = "call",
        explicit_tag = nil,
        explicit_location = "home",
        tag = "ProjectOrion",
        location = "home",
        workday_excluded = false,
        logged = false,
      },
      {
        row = 4,
        minutes = 600,
        text = "done",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "ProjectOrion",
        location = "home",
        workday_excluded = false,
        logged = true,
      },
    })
  end)

  t.test("analyze reports header, invalid entry, and unordered diagnostics", function()
    local analysis = analyze.analyze(document.parse({
      "--- summary exact ---",
      "1.00h activity",
      "--- worklog #sales @office quantize=60 ---",
      "09:00 later",
      "08:00 earlier",
      "08:30 broken #sales #meeting",
      "10:00 done",
    }))

    t.eq(analysis.diagnostics, {
      {
        code = "invalid_first_header",
        category = "structural",
        severity = "error",
        row = 1,
        message = INVALID_FIRST_HEADER_MESSAGE,
      },
      {
        code = "invalid_entry",
        category = "block",
        severity = "error",
        row = 6,
        message = "multiple trailing tags are not allowed",
      },
      {
        code = "unordered_timestamps",
        category = "block",
        severity = "error",
        row = 4,
        row2 = 5,
        message = "timestamps are not in non-decreasing order",
      },
    })

    t.eq(analysis.worklog_blocks[1].header_quantize_minutes, 60)
    t.eq(analysis.worklog_blocks[1].quantize_minutes, 60)
  end)

  t.test("analyze rejects quantize values tonumber would accept but are not integers", function()
    for _, value in ipairs({ "inf", "0x10", "1e2", "5.0", "+5" }) do
      local analysis = analyze.analyze(document.parse({
        "--- worklog quantize=" .. value .. " ---",
        "08:00 work",
        "09:00 done",
      }))

      t.eq(analysis.diagnostics, {
        {
          code = "invalid_worklog_header_option",
          category = "structural",
          severity = "error",
          row = 1,
          message = "worklog header option quantize must be a positive integer",
        },
      })
    end
  end)

  t.test("analyze reports invalid worklog header metadata and options", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog #ProjectOrion #sales @office @home quantize=0 duration=clock nope unknown=bar ---",
      "08:00 plan",
      "09:00 done",
    }))

    t.eq(analysis.diagnostics, {
      {
        code = "invalid_worklog_header_metadata",
        category = "structural",
        severity = "error",
        row = 1,
        message = "multiple worklog header tags are not allowed",
      },
      {
        code = "invalid_worklog_header_metadata",
        category = "structural",
        severity = "error",
        row = 1,
        message = "multiple worklog header locations are not allowed",
      },
      {
        code = "invalid_worklog_header_option",
        category = "structural",
        severity = "error",
        row = 1,
        message = "worklog header option quantize must be a positive integer",
      },
      {
        code = "invalid_worklog_header_option",
        category = "structural",
        severity = "error",
        row = 1,
        message = "worklog header option duration must be decimal or hhmm",
      },
      {
        code = "invalid_worklog_header_option",
        category = "structural",
        severity = "error",
        row = 1,
        message = "unknown worklog header option: unknown",
      },
      {
        code = "invalid_worklog_header_token",
        category = "structural",
        severity = "error",
        row = 1,
        message = "worklog header tokens must be #tag, @location, or key=value: nope",
      },
    })

    t.eq(analysis.worklog_blocks[1].header_quantize_minutes, nil)
    t.eq(analysis.worklog_blocks[1].quantize_minutes, 15)
    t.eq(analysis.worklog_blocks[1].header_duration_format, nil)
    t.eq(analysis.worklog_blocks[1].duration_format, "decimal")
  end)

  t.test("analyze does not flag a two-digit-hour hhmm summary row", function()
    -- An hhmm summary row whose duration is >= 10h (e.g. "16:00 (+0m) workday")
    -- parses as a timestamped entry, but it lives in a generated summary block
    -- and must not be reported as malformed.
    local analysis = analyze.analyze(document.parse({
      "--- worklog quantize=60 duration=hhmm ---",
      "06:00 deep work",
      "22:00 done",
      "",
      "--- summary quantized ---",
      "16:00 (+0m) deep work",
      "",
      "--- totals quantized ---",
      "16:00 (+0m) workday",
    }))

    t.eq(analysis.diagnostics, {})
  end)

  t.test("analyze reports duplicate header metadata when clear tokens are mixed in", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog #- #ClientA ---",
      "08:00 plan",
      "09:00 done",
      "--- worklog #ClientA #- ---",
      "10:00 plan",
      "11:00 done",
      "--- worklog @- @home ---",
      "12:00 plan",
      "13:00 done",
      "--- worklog @home @- ---",
      "14:00 plan",
      "15:00 done",
    }))

    t.eq(analysis.diagnostics, {
      {
        code = "invalid_worklog_header_metadata",
        category = "structural",
        severity = "error",
        row = 1,
        message = "multiple worklog header tags are not allowed",
      },
      {
        code = "invalid_worklog_header_metadata",
        category = "structural",
        severity = "error",
        row = 4,
        message = "multiple worklog header tags are not allowed",
      },
      {
        code = "invalid_worklog_header_metadata",
        category = "structural",
        severity = "error",
        row = 7,
        message = "multiple worklog header locations are not allowed",
      },
      {
        code = "invalid_worklog_header_metadata",
        category = "structural",
        severity = "error",
        row = 10,
        message = "multiple worklog header locations are not allowed",
      },
    })
  end)

  t.test("analyze reports duplicate worklog header options", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog #ProjectOrion @office quantize=30 duration=decimal quantize=60 duration=hhmm ---",
      "08:00 plan",
      "09:00 done",
    }))

    t.eq(analysis.diagnostics, {
      {
        code = "invalid_worklog_header_option",
        category = "structural",
        severity = "error",
        row = 1,
        message = "duplicate worklog header option: quantize",
      },
      {
        code = "invalid_worklog_header_option",
        category = "structural",
        severity = "error",
        row = 1,
        message = "duplicate worklog header option: duration",
      },
    })

    t.eq(analysis.worklog_blocks[1].header_quantize_minutes, 30)
    t.eq(analysis.worklog_blocks[1].quantize_minutes, 30)
    t.eq(analysis.worklog_blocks[1].header_duration_format, "decimal")
    t.eq(analysis.worklog_blocks[1].duration_format, "decimal")
  end)

  t.test("analyze reports invalid options on later worklog headers", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "09:00 done",
      "--- worklog #internal @home quantize=0 duration=clock nope unknown=bar ---",
      "10:00 tea",
      "11:00 done",
    }))

    t.eq(analysis.diagnostics, {
      {
        code = "invalid_worklog_header_option",
        category = "structural",
        severity = "error",
        row = 4,
        message = "worklog header option quantize must be a positive integer",
      },
      {
        code = "invalid_worklog_header_option",
        category = "structural",
        severity = "error",
        row = 4,
        message = "worklog header option duration must be decimal or hhmm",
      },
      {
        code = "invalid_worklog_header_option",
        category = "structural",
        severity = "error",
        row = 4,
        message = "unknown worklog header option: unknown",
      },
      {
        code = "invalid_worklog_header_token",
        category = "structural",
        severity = "error",
        row = 4,
        message = "worklog header tokens must be #tag, @location, or key=value: nope",
      },
    })

    t.eq(analysis.worklog_blocks[1].quantize_minutes, 15)
    t.eq(analysis.worklog_blocks[2].header_quantize_minutes, nil)
    t.eq(analysis.worklog_blocks[2].quantize_minutes, 15)
    t.eq(analysis.worklog_blocks[2].header_duration_format, nil)
    t.eq(analysis.worklog_blocks[2].duration_format, "decimal")
  end)

  t.test("analyze keeps quantize and duration format local to each worklog", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog #ProjectOrion @office quantize=30 duration=hhmm ---",
      "08:00 plan",
      "09:00 done",
      "--- worklog #internal @home quantize=60 duration=decimal ---",
      "10:00 tea",
      "11:00 done",
      "--- worklog #sales @client ---",
      "12:00 call",
      "13:00 done",
    }))

    t.eq(analysis.diagnostics, {})
    t.eq(analysis.worklog_blocks[1].header_quantize_minutes, 30)
    t.eq(analysis.worklog_blocks[1].quantize_minutes, 30)
    t.eq(analysis.worklog_blocks[1].header_duration_format, "hhmm")
    t.eq(analysis.worklog_blocks[1].duration_format, "hhmm")
    t.eq(analysis.worklog_blocks[2].header_quantize_minutes, 60)
    t.eq(analysis.worklog_blocks[2].quantize_minutes, 60)
    t.eq(analysis.worklog_blocks[2].header_duration_format, "decimal")
    t.eq(analysis.worklog_blocks[2].duration_format, "decimal")
    t.eq(analysis.worklog_blocks[3].header_quantize_minutes, nil)
    t.eq(analysis.worklog_blocks[3].quantize_minutes, 15)
    t.eq(analysis.worklog_blocks[3].header_duration_format, nil)
    t.eq(analysis.worklog_blocks[3].duration_format, "decimal")
  end)

  t.test("analyze keeps sticky metadata nil until changed", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog ---",
      "08:00 plan",
      "08:30 call #sales",
      "09:00 travel @client",
      "09:15 done",
    }))

    t.eq(analysis.worklog_blocks[1].entries, {
      {
        row = 2,
        minutes = 480,
        text = "plan",
        explicit_tag = nil,
        explicit_location = nil,
        tag = nil,
        location = nil,
        workday_excluded = false,
        logged = false,
      },
      {
        row = 3,
        minutes = 510,
        text = "call",
        explicit_tag = "sales",
        explicit_location = nil,
        tag = "sales",
        location = nil,
        workday_excluded = false,
        logged = false,
      },
      {
        row = 4,
        minutes = 540,
        text = "travel",
        explicit_tag = nil,
        explicit_location = "client",
        tag = "sales",
        location = "client",
        workday_excluded = false,
        logged = false,
      },
      {
        row = 5,
        minutes = 555,
        text = "done",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "sales",
        location = "client",
        workday_excluded = false,
        logged = false,
      },
    })
  end)

  t.test("analyze clears sticky tag and location when asked", function()
    local entries = analyze.analyze(document.parse({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "09:00 reset #- @-",
      "10:00 done",
    })).worklog_blocks[1].entries

    t.eq(entries[2], {
      row = 3,
      minutes = 540,
      text = "reset",
      explicit_tag = nil,
      explicit_tag_clear = true,
      explicit_location = nil,
      explicit_location_clear = true,
      tag = nil,
      location = nil,
      workday_excluded = false,
      logged = false,
    })
    t.eq(entries[3], {
      row = 4,
      minutes = 600,
      text = "done",
      explicit_tag = nil,
      explicit_location = nil,
      tag = nil,
      location = nil,
      workday_excluded = false,
      logged = false,
    })
  end)

  t.test("analyze treats clear-only headers as harmless nil metadata", function()
    local block = analyze.analyze(document.parse({
      "--- worklog #- @- ---",
      "08:00 plan",
      "09:00 client #ClientA @home",
      "10:00 reset #- @-",
      "11:00 done",
    })).worklog_blocks[1]

    t.eq(block.header_tag, nil)
    t.eq(block.header_location, nil)
    t.eq(block.entries, {
      {
        row = 2,
        minutes = 480,
        text = "plan",
        explicit_tag = nil,
        explicit_location = nil,
        tag = nil,
        location = nil,
        workday_excluded = false,
        logged = false,
      },
      {
        row = 3,
        minutes = 540,
        text = "client",
        explicit_tag = "ClientA",
        explicit_location = "home",
        tag = "ClientA",
        location = "home",
        workday_excluded = false,
        logged = false,
      },
      {
        row = 4,
        minutes = 600,
        text = "reset",
        explicit_tag = nil,
        explicit_tag_clear = true,
        explicit_location = nil,
        explicit_location_clear = true,
        tag = nil,
        location = nil,
        workday_excluded = false,
        logged = false,
      },
      {
        row = 5,
        minutes = 660,
        text = "done",
        explicit_tag = nil,
        explicit_location = nil,
        tag = nil,
        location = nil,
        workday_excluded = false,
        logged = false,
      },
    })
  end)

  t.test("analyze keeps ooo sticky until another tag replaces it", function()
    local entries = analyze.analyze(document.parse({
      "--- worklog #ProjectOrion @office ---",
      "08:00 break #ooo",
      "08:30 lunch",
      "09:00 work #ProjectOrion",
      "09:30 done",
    })).worklog_blocks[1].entries

    t.eq(entries[1], {
      row = 2,
      minutes = 480,
      text = "break",
      explicit_tag = "ooo",
      explicit_location = nil,
      tag = "ooo",
      location = "office",
      workday_excluded = true,
      logged = false,
    })
    t.eq(entries[2], {
      row = 3,
      minutes = 510,
      text = "lunch",
      explicit_tag = nil,
      explicit_location = nil,
      tag = "ooo",
      location = "office",
      workday_excluded = true,
      logged = false,
    })
    t.eq(entries[3], {
      row = 4,
      minutes = 540,
      text = "work",
      explicit_tag = "ProjectOrion",
      explicit_location = nil,
      tag = "ProjectOrion",
      location = "office",
      workday_excluded = false,
      logged = false,
    })
  end)

  t.test("analyze can return from ooo to untagged with tag clear", function()
    local entries = analyze.analyze(document.parse({
      "--- worklog ---",
      "08:00 break #ooo",
      "09:00 resume #-",
      "10:00 done",
    })).worklog_blocks[1].entries

    t.eq(entries[2], {
      row = 3,
      minutes = 540,
      text = "resume",
      explicit_tag = nil,
      explicit_tag_clear = true,
      explicit_location = nil,
      tag = nil,
      location = nil,
      workday_excluded = false,
      logged = false,
    })
    t.eq(entries[3], {
      row = 4,
      minutes = 600,
      text = "done",
      explicit_tag = nil,
      explicit_location = nil,
      tag = nil,
      location = nil,
      workday_excluded = false,
      logged = false,
    })
  end)

  t.test("analyze keeps sticky tag when only location changes", function()
    local entries = analyze.analyze(document.parse({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "09:00 travel @client",
      "10:00 done",
    })).worklog_blocks[1].entries

    t.eq(entries[2], {
      row = 3,
      minutes = 540,
      text = "travel",
      explicit_tag = nil,
      explicit_location = "client",
      tag = "ProjectOrion",
      location = "client",
      workday_excluded = false,
      logged = false,
    })
    t.eq(entries[3], {
      row = 4,
      minutes = 600,
      text = "done",
      explicit_tag = nil,
      explicit_location = nil,
      tag = "ProjectOrion",
      location = "client",
      workday_excluded = false,
      logged = false,
    })
  end)

  t.test("analyze can return from a location to no location with location clear", function()
    local entries = analyze.analyze(document.parse({
      "--- worklog ---",
      "08:00 travel @home",
      "09:00 arrive @-",
      "10:00 done",
    })).worklog_blocks[1].entries

    t.eq(entries[2], {
      row = 3,
      minutes = 540,
      text = "arrive",
      explicit_tag = nil,
      explicit_location = nil,
      explicit_location_clear = true,
      tag = nil,
      location = nil,
      workday_excluded = false,
      logged = false,
    })
    t.eq(entries[3], {
      row = 4,
      minutes = 600,
      text = "done",
      explicit_tag = nil,
      explicit_location = nil,
      tag = nil,
      location = nil,
      workday_excluded = false,
      logged = false,
    })
  end)

  t.test("analyze keeps sticky location when only tag changes", function()
    local entries = analyze.analyze(document.parse({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "09:00 internal #internal",
      "10:00 done",
    })).worklog_blocks[1].entries

    t.eq(entries[2], {
      row = 3,
      minutes = 540,
      text = "internal",
      explicit_tag = "internal",
      explicit_location = nil,
      tag = "internal",
      location = "office",
      workday_excluded = false,
      logged = false,
    })
    t.eq(entries[3], {
      row = 4,
      minutes = 600,
      text = "done",
      explicit_tag = nil,
      explicit_location = nil,
      tag = "internal",
      location = "office",
      workday_excluded = false,
      logged = false,
    })
  end)

  t.test("analyze helpers expose structural and block diagnostics", function()
    local analysis = analyze.analyze(document.parse({
      "--- summary exact ---",
      "1.00h activity",
      "--- worklog ---",
      "09:00 later",
      "08:00 earlier",
      "08:30 broken @office @home",
      "10:00 done",
    }))

    t.eq(analyze.structural_error(analysis), INVALID_FIRST_HEADER_MESSAGE)
    t.eq(analyze.find_block_diagnostic(analysis, analysis.worklog_blocks[1]), {
      code = "invalid_entry",
      category = "block",
      severity = "error",
      row = 6,
      message = "multiple trailing locations are not allowed",
    })
  end)

  t.test("analyze accepts 24:00 as the final closing entry", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog ---",
      "22:30 writing report",
      "24:00",
    }))

    t.eq(analysis.diagnostics, {})
    t.eq(analyze.find_block_diagnostic(analysis, analysis.worklog_blocks[1]), nil)
    t.eq(analysis.worklog_blocks[1].entry_items[2].minutes, 1440)
  end)

  t.test("analyze reports a 24:00 entry that is not the final entry", function()
    local analysis = analyze.analyze(document.parse({
      "--- worklog ---",
      "08:00 plan",
      "24:00 overnight",
      "24:00 done",
    }))

    local diagnostic = {
      code = "midnight_not_final",
      category = "block",
      severity = "error",
      row = 3,
      message = "24:00 must be the final entry in a worklog block",
    }

    t.eq(analysis.diagnostics, { diagnostic })
    t.eq(analyze.find_block_diagnostic(analysis, analysis.worklog_blocks[1]), diagnostic)
  end)
end
