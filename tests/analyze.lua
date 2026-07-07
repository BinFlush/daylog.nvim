return function(t)
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")
  local INVALID_FIRST_HEADER_MESSAGE = "daylog: first line must be a log header such as "
    .. "--- log --- or --- log #ClientA @office q=30 ---"

  t.test("analyze derives log blocks, items, and sticky metadata", function()
    local analysis = analyze.analyze(document.parse({
      "--- log #ProjectOrion @office q=30 d=hm ---",
      "08:00 plan",
      "note about planning",
      "08:30 call @home",
      "09:00 coffee #ooo",
      "09:30 prep",
      "10:00 done #ProjectOrion @client",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h activity",
      "",
      "--- log #internal @office ---",
      "11:00 tea",
      "12:00 done",
    }))

    t.eq(analysis.kind, "analysis")
    t.eq(analysis.diagnostics, {})
    t.eq(#analysis.blocks, 3)
    t.eq(#analysis.log_blocks, 2)

    local first = analysis.log_blocks[1]
    t.eq(first.start_row, 1)
    t.eq(first.body_start_row, 2)
    t.eq(first.end_row, 9)
    t.eq(first.header_tag, "ProjectOrion")
    t.eq(first.header_location, "office")
    t.eq(first.header_quantize_minutes, 30)
    t.eq(first.header_duration_format, "hm")
    t.eq(first.quantize_minutes, 30)
    t.eq(first.duration_format, "hm")
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
      },
      {
        row = 4,
        minutes = 510,
        text = "call",
        explicit_tag = nil,
        explicit_location = "home",
        tag = "ProjectOrion",
        location = "home",
      },
      {
        row = 5,
        minutes = 540,
        text = "coffee",
        explicit_tag = "ooo",
        explicit_location = nil,
        tag = "ooo",
        location = "home",
      },
      {
        row = 6,
        minutes = 570,
        text = "prep",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "ooo",
        location = "home",
      },
      {
        row = 7,
        minutes = 600,
        text = "done",
        explicit_tag = "ProjectOrion",
        explicit_location = "client",
        tag = "ProjectOrion",
        location = "client",
      },
    })

    local second = analysis.log_blocks[2]
    t.eq(second.header_tag, "internal")
    t.eq(second.header_location, "office")
    t.eq(second.header_quantize_minutes, nil)
    t.eq(second.quantize_minutes, 15)
    t.eq(second.header_duration_format, nil)
    t.eq(second.duration_format, "dec")
    t.eq(second.entries, {
      {
        row = 13,
        minutes = 660,
        text = "tea",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "internal",
        location = "office",
      },
      {
        row = 14,
        minutes = 720,
        text = "done",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "internal",
        location = "office",
      },
    })

    t.eq(analyze.get_active_log(analysis), analysis.log_blocks[2])
    t.eq(analyze.get_log_at_row(analysis, 1), analysis.log_blocks[1])
    t.eq(analyze.get_log_at_row(analysis, 13), analysis.log_blocks[2])
    t.eq(analyze.get_log_at_row(analysis, 9), nil)
  end)

  t.test("analyze carries logged state without making it sticky", function()
    local analysis = analyze.analyze(document.parse({
      "--- log #ProjectOrion @office ---",
      "08:00 plan !S[]",
      "09:00 call @home",
      "10:00 done !S[]",
    }))

    t.eq(analysis.log_blocks[1].entries, {
      {
        row = 2,
        minutes = 480,
        text = "plan",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "ProjectOrion",
        location = "office",
        logged = { s = {} },
      },
      {
        row = 3,
        minutes = 540,
        text = "call",
        explicit_tag = nil,
        explicit_location = "home",
        tag = "ProjectOrion",
        location = "home",
      },
      {
        row = 4,
        minutes = 600,
        text = "done",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "ProjectOrion",
        location = "home",
        logged = { s = {} },
      },
    })
  end)

  t.test("analyze reports header, invalid entry, and unordered diagnostics", function()
    local analysis = analyze.analyze(document.parse({
      "--- summary q=15 d=dec ---",
      "1.00h activity",
      "--- log #sales @office q=60 ---",
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

    t.eq(analysis.log_blocks[1].header_quantize_minutes, 60)
    t.eq(analysis.log_blocks[1].quantize_minutes, 60)
  end)

  t.test("analyze rejects quantize values tonumber would accept but are not integers", function()
    -- The digit run beyond the day cap would otherwise overflow into a float bucket (1e20).
    for _, value in ipairs({ "inf", "0x10", "1e2", "5.0", "+5", "1441", "99999999999999999999" }) do
      local analysis = analyze.analyze(document.parse({
        "--- log q=" .. value .. " ---",
        "08:00 work",
        "09:00 done",
      }))

      t.eq(analysis.diagnostics, {
        {
          code = "invalid_log_header_option",
          category = "structural",
          severity = "error",
          row = 1,
          message = "log header option q must be a positive integer of minutes (at most 1440)",
        },
      })
    end

    -- The day itself is the cap: q=1440 stays valid.
    local ok = analyze.analyze(document.parse({ "--- log q=1440 ---", "08:00 work", "09:00 done" }))
    t.eq(ok.diagnostics, {})
    t.eq(ok.log_blocks[1].quantize_minutes, 1440)
  end)

  t.test("analyze reports invalid log header metadata and options", function()
    local analysis = analyze.analyze(document.parse({
      "--- log #ProjectOrion #sales @office @home q=0 d=clock nope unknown=bar ---",
      "08:00 plan",
      "09:00 done",
    }))

    t.eq(analysis.diagnostics, {
      {
        code = "invalid_log_header_metadata",
        category = "structural",
        severity = "error",
        row = 1,
        message = "multiple log header tags are not allowed",
      },
      {
        code = "invalid_log_header_metadata",
        category = "structural",
        severity = "error",
        row = 1,
        message = "multiple log header locations are not allowed",
      },
      {
        code = "invalid_log_header_option",
        category = "structural",
        severity = "error",
        row = 1,
        message = "log header option q must be a positive integer of minutes (at most 1440)",
      },
      {
        code = "invalid_log_header_option",
        category = "structural",
        severity = "error",
        row = 1,
        message = "log header option d must be dec or hm",
      },
      {
        code = "invalid_log_header_option",
        category = "structural",
        severity = "error",
        row = 1,
        message = "unknown log header option: unknown",
      },
      {
        code = "invalid_log_header_token",
        category = "structural",
        severity = "error",
        row = 1,
        message = "log header tokens must be #tag, @location, utc±H[:MM], or key=value: nope",
      },
    })

    t.eq(analysis.log_blocks[1].header_quantize_minutes, nil)
    t.eq(analysis.log_blocks[1].quantize_minutes, 15)
    t.eq(analysis.log_blocks[1].header_duration_format, nil)
    t.eq(analysis.log_blocks[1].duration_format, "dec")
  end)

  t.test("analyze does not flag a two-digit-hour hhmm summary row", function()
    -- An hhmm summary row whose duration is >= 10h (e.g. "16:00 (+0m) workday")
    -- parses as a timestamped entry, but it lives in a generated summary block
    -- and must not be reported as malformed.
    local analysis = analyze.analyze(document.parse({
      "--- log q=60 d=hm ---",
      "06:00 deep work",
      "22:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "16:00 (+0m) deep work",
      "",
      "--- totals ---",
      "16:00 (+0m) workday",
    }))

    t.eq(analysis.diagnostics, {})
  end)

  t.test("analyze reports duplicate header metadata when clear tokens are mixed in", function()
    local analysis = analyze.analyze(document.parse({
      "--- log #- #ClientA ---",
      "08:00 plan",
      "09:00 done",
      "--- log #ClientA #- ---",
      "10:00 plan",
      "11:00 done",
      "--- log @- @home ---",
      "12:00 plan",
      "13:00 done",
      "--- log @home @- ---",
      "14:00 plan",
      "15:00 done",
    }))

    t.eq(analysis.diagnostics, {
      {
        code = "invalid_log_header_metadata",
        category = "structural",
        severity = "error",
        row = 1,
        message = "multiple log header tags are not allowed",
      },
      {
        code = "invalid_log_header_metadata",
        category = "structural",
        severity = "error",
        row = 4,
        message = "multiple log header tags are not allowed",
      },
      {
        code = "invalid_log_header_metadata",
        category = "structural",
        severity = "error",
        row = 7,
        message = "multiple log header locations are not allowed",
      },
      {
        code = "invalid_log_header_metadata",
        category = "structural",
        severity = "error",
        row = 10,
        message = "multiple log header locations are not allowed",
      },
    })
  end)

  t.test("analyze reports duplicate log header options", function()
    local analysis = analyze.analyze(document.parse({
      "--- log #ProjectOrion @office q=30 d=dec q=60 d=hm ---",
      "08:00 plan",
      "09:00 done",
    }))

    t.eq(analysis.diagnostics, {
      {
        code = "invalid_log_header_option",
        category = "structural",
        severity = "error",
        row = 1,
        message = "duplicate log header option: q",
      },
      {
        code = "invalid_log_header_option",
        category = "structural",
        severity = "error",
        row = 1,
        message = "duplicate log header option: d",
      },
    })

    t.eq(analysis.log_blocks[1].header_quantize_minutes, 30)
    t.eq(analysis.log_blocks[1].quantize_minutes, 30)
    t.eq(analysis.log_blocks[1].header_duration_format, "dec")
    t.eq(analysis.log_blocks[1].duration_format, "dec")
  end)

  t.test("analyze reports invalid options on later log headers", function()
    local analysis = analyze.analyze(document.parse({
      "--- log #ProjectOrion @office ---",
      "08:00 plan",
      "09:00 done",
      "--- log #internal @home q=0 d=clock nope unknown=bar ---",
      "10:00 tea",
      "11:00 done",
    }))

    t.eq(analysis.diagnostics, {
      {
        code = "invalid_log_header_option",
        category = "structural",
        severity = "error",
        row = 4,
        message = "log header option q must be a positive integer of minutes (at most 1440)",
      },
      {
        code = "invalid_log_header_option",
        category = "structural",
        severity = "error",
        row = 4,
        message = "log header option d must be dec or hm",
      },
      {
        code = "invalid_log_header_option",
        category = "structural",
        severity = "error",
        row = 4,
        message = "unknown log header option: unknown",
      },
      {
        code = "invalid_log_header_token",
        category = "structural",
        severity = "error",
        row = 4,
        message = "log header tokens must be #tag, @location, utc±H[:MM], or key=value: nope",
      },
    })

    t.eq(analysis.log_blocks[1].quantize_minutes, 15)
    t.eq(analysis.log_blocks[2].header_quantize_minutes, nil)
    t.eq(analysis.log_blocks[2].quantize_minutes, 15)
    t.eq(analysis.log_blocks[2].header_duration_format, nil)
    t.eq(analysis.log_blocks[2].duration_format, "dec")
  end)

  t.test("analyze keeps quantize and duration format local to each log", function()
    local analysis = analyze.analyze(document.parse({
      "--- log #ProjectOrion @office q=30 d=hm ---",
      "08:00 plan",
      "09:00 done",
      "--- log #internal @home q=60 d=dec ---",
      "10:00 tea",
      "11:00 done",
      "--- log #sales @client ---",
      "12:00 call",
      "13:00 done",
    }))

    t.eq(analysis.diagnostics, {})
    t.eq(analysis.log_blocks[1].header_quantize_minutes, 30)
    t.eq(analysis.log_blocks[1].quantize_minutes, 30)
    t.eq(analysis.log_blocks[1].header_duration_format, "hm")
    t.eq(analysis.log_blocks[1].duration_format, "hm")
    t.eq(analysis.log_blocks[2].header_quantize_minutes, 60)
    t.eq(analysis.log_blocks[2].quantize_minutes, 60)
    t.eq(analysis.log_blocks[2].header_duration_format, "dec")
    t.eq(analysis.log_blocks[2].duration_format, "dec")
    t.eq(analysis.log_blocks[3].header_quantize_minutes, nil)
    t.eq(analysis.log_blocks[3].quantize_minutes, 15)
    t.eq(analysis.log_blocks[3].header_duration_format, nil)
    t.eq(analysis.log_blocks[3].duration_format, "dec")
  end)

  t.test("analyze keeps sticky metadata nil until changed", function()
    local analysis = analyze.analyze(document.parse({
      "--- log ---",
      "08:00 plan",
      "08:30 call #sales",
      "09:00 travel @client",
      "09:15 done",
    }))

    t.eq(analysis.log_blocks[1].entries, {
      {
        row = 2,
        minutes = 480,
        text = "plan",
        explicit_tag = nil,
        explicit_location = nil,
        tag = nil,
        location = nil,
      },
      {
        row = 3,
        minutes = 510,
        text = "call",
        explicit_tag = "sales",
        explicit_location = nil,
        tag = "sales",
        location = nil,
      },
      {
        row = 4,
        minutes = 540,
        text = "travel",
        explicit_tag = nil,
        explicit_location = "client",
        tag = "sales",
        location = "client",
      },
      {
        row = 5,
        minutes = 555,
        text = "done",
        explicit_tag = nil,
        explicit_location = nil,
        tag = "sales",
        location = "client",
      },
    })
  end)

  t.test("analyze clears sticky tag and location when asked", function()
    local entries = analyze.analyze(document.parse({
      "--- log #ProjectOrion @office ---",
      "08:00 plan",
      "09:00 reset #- @-",
      "10:00 done",
    })).log_blocks[1].entries

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
    })
    t.eq(entries[3], {
      row = 4,
      minutes = 600,
      text = "done",
      explicit_tag = nil,
      explicit_location = nil,
      tag = nil,
      location = nil,
    })
  end)

  t.test("analyze treats clear-only headers as harmless nil metadata", function()
    local block = analyze.analyze(document.parse({
      "--- log #- @- ---",
      "08:00 plan",
      "09:00 client #ClientA @home",
      "10:00 reset #- @-",
      "11:00 done",
    })).log_blocks[1]

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
      },
      {
        row = 3,
        minutes = 540,
        text = "client",
        explicit_tag = "ClientA",
        explicit_location = "home",
        tag = "ClientA",
        location = "home",
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
      },
      {
        row = 5,
        minutes = 660,
        text = "done",
        explicit_tag = nil,
        explicit_location = nil,
        tag = nil,
        location = nil,
      },
    })
  end)

  t.test("analyze keeps ooo sticky until another tag replaces it", function()
    local entries = analyze.analyze(document.parse({
      "--- log #ProjectOrion @office ---",
      "08:00 break #ooo",
      "08:30 lunch",
      "09:00 work #ProjectOrion",
      "09:30 done",
    })).log_blocks[1].entries

    t.eq(entries[1], {
      row = 2,
      minutes = 480,
      text = "break",
      explicit_tag = "ooo",
      explicit_location = nil,
      tag = "ooo",
      location = "office",
    })
    t.eq(entries[2], {
      row = 3,
      minutes = 510,
      text = "lunch",
      explicit_tag = nil,
      explicit_location = nil,
      tag = "ooo",
      location = "office",
    })
    t.eq(entries[3], {
      row = 4,
      minutes = 540,
      text = "work",
      explicit_tag = "ProjectOrion",
      explicit_location = nil,
      tag = "ProjectOrion",
      location = "office",
    })
  end)

  t.test("analyze can return from ooo to untagged with tag clear", function()
    local entries = analyze.analyze(document.parse({
      "--- log ---",
      "08:00 break #ooo",
      "09:00 resume #-",
      "10:00 done",
    })).log_blocks[1].entries

    t.eq(entries[2], {
      row = 3,
      minutes = 540,
      text = "resume",
      explicit_tag = nil,
      explicit_tag_clear = true,
      explicit_location = nil,
      tag = nil,
      location = nil,
    })
    t.eq(entries[3], {
      row = 4,
      minutes = 600,
      text = "done",
      explicit_tag = nil,
      explicit_location = nil,
      tag = nil,
      location = nil,
    })
  end)

  t.test("analyze keeps sticky tag when only location changes", function()
    local entries = analyze.analyze(document.parse({
      "--- log #ProjectOrion @office ---",
      "08:00 plan",
      "09:00 travel @client",
      "10:00 done",
    })).log_blocks[1].entries

    t.eq(entries[2], {
      row = 3,
      minutes = 540,
      text = "travel",
      explicit_tag = nil,
      explicit_location = "client",
      tag = "ProjectOrion",
      location = "client",
    })
    t.eq(entries[3], {
      row = 4,
      minutes = 600,
      text = "done",
      explicit_tag = nil,
      explicit_location = nil,
      tag = "ProjectOrion",
      location = "client",
    })
  end)

  t.test("analyze can return from a location to no location with location clear", function()
    local entries = analyze.analyze(document.parse({
      "--- log ---",
      "08:00 travel @home",
      "09:00 arrive @-",
      "10:00 done",
    })).log_blocks[1].entries

    t.eq(entries[2], {
      row = 3,
      minutes = 540,
      text = "arrive",
      explicit_tag = nil,
      explicit_location = nil,
      explicit_location_clear = true,
      tag = nil,
      location = nil,
    })
    t.eq(entries[3], {
      row = 4,
      minutes = 600,
      text = "done",
      explicit_tag = nil,
      explicit_location = nil,
      tag = nil,
      location = nil,
    })
  end)

  t.test("analyze keeps sticky location when only tag changes", function()
    local entries = analyze.analyze(document.parse({
      "--- log #ProjectOrion @office ---",
      "08:00 plan",
      "09:00 internal #internal",
      "10:00 done",
    })).log_blocks[1].entries

    t.eq(entries[2], {
      row = 3,
      minutes = 540,
      text = "internal",
      explicit_tag = "internal",
      explicit_location = nil,
      tag = "internal",
      location = "office",
    })
    t.eq(entries[3], {
      row = 4,
      minutes = 600,
      text = "done",
      explicit_tag = nil,
      explicit_location = nil,
      tag = "internal",
      location = "office",
    })
  end)

  t.test("analyze helpers expose structural and block diagnostics", function()
    local analysis = analyze.analyze(document.parse({
      "--- summary q=15 d=dec ---",
      "1.00h activity",
      "--- log ---",
      "09:00 later",
      "08:00 earlier",
      "08:30 broken @office @home",
      "10:00 done",
    }))

    t.eq(analyze.structural_error(analysis), INVALID_FIRST_HEADER_MESSAGE)
    t.eq(analyze.find_block_diagnostic(analysis, analysis.log_blocks[1]), {
      code = "invalid_entry",
      category = "block",
      severity = "error",
      row = 6,
      message = "multiple trailing locations are not allowed",
    })
  end)

  t.test("analyze accepts 24:00 as the final closing entry", function()
    local analysis = analyze.analyze(document.parse({
      "--- log ---",
      "22:30 writing report",
      "24:00",
    }))

    t.eq(analysis.diagnostics, {})
    t.eq(analyze.find_block_diagnostic(analysis, analysis.log_blocks[1]), nil)
    t.eq(analysis.log_blocks[1].entry_items[2].minutes, 1440)
  end)

  t.test("analyze reports a 24:00 entry that is not the final entry", function()
    local analysis = analyze.analyze(document.parse({
      "--- log ---",
      "08:00 plan",
      "24:00 overnight",
      "24:00 done",
    }))

    local diagnostic = {
      code = "midnight_not_final",
      category = "block",
      severity = "error",
      row = 3,
      message = "24:00 must be the final entry in a log block",
    }

    t.eq(analysis.diagnostics, { diagnostic })
    t.eq(analyze.find_block_diagnostic(analysis, analysis.log_blocks[1]), diagnostic)
  end)

  t.test("analyze refuses a utc offset introduced after offset-free entries", function()
    local analysis = analyze.analyze(document.parse({
      "--- log ---",
      "08:00 a",
      "09:00 b utc-5",
      "10:00 c",
    }))

    local diagnostic = {
      code = "mixed_offset",
      category = "block",
      severity = "error",
      row = 3,
      message = "a utc offset here follows offset-free entries; put the offset on the log "
        .. "header (or remove it) so the whole log is timezone-consistent",
    }

    -- A block diagnostic, so it refuses commands and stops the summary, like an unordered log.
    t.eq(analysis.diagnostics, { diagnostic })
    t.eq(analyze.find_block_diagnostic(analysis, analysis.log_blocks[1]), diagnostic)
  end)

  t.test("analyze accepts a consistently naive or timezoned log", function()
    -- Fully naive: no offsets anywhere.
    t.eq(
      analyze.analyze(document.parse({
        "--- log ---",
        "08:00 a",
        "09:00 b",
        "10:00 c",
      })).diagnostics,
      {}
    )

    -- The first entry establishes the offset, so there is no offset-free prefix.
    t.eq(
      analyze.analyze(document.parse({
        "--- log ---",
        "08:00 a utc-5",
        "09:00 b",
        "10:00 c",
      })).diagnostics,
      {}
    )

    -- A header baseline keeps every entry timezone-aware even as the offset changes mid-log.
    t.eq(
      analyze.analyze(document.parse({
        "--- log utc+2 ---",
        "08:00 a",
        "09:00 b utc-4",
        "10:00 c",
      })).diagnostics,
      {}
    )
  end)

  t.test("analyze inherits a header utc offset and switches it on an explicit token", function()
    local analysis = analyze.analyze(document.parse({
      "--- log @office utc+2 ---",
      "08:00 standup",
      "11:00 resume utc-4",
      "12:00 done",
    }))
    local block = analysis.log_blocks[1]

    t.eq(block.header_offset, 120)
    t.eq(block.entries[1].offset, 120) -- inherits the header base
    t.eq(block.entries[2].offset, -240) -- an explicit token switches it
    t.eq(block.entries[2].explicit_offset, -240)
    t.eq(block.entries[3].offset, -240) -- sticky from the switch onward
    t.eq(block.entries[3].explicit_offset, nil)
    t.eq(analysis.diagnostics, {})
  end)

  t.test("analyze checks ordering in effective UTC time, not the raw local clock", function()
    -- 14:00@+2 = 12:00Z then 11:00@-4 = 15:00Z: the raw clock goes backwards but
    -- effective time moves forward, so a westward move is not a false reversal.
    local ok = analyze.analyze(document.parse({
      "--- log utc+2 ---",
      "14:00 leave",
      "11:00 resume utc-4",
      "17:00 done",
    }))
    t.eq(ok.diagnostics, {})

    -- The inverse: the raw clock increases but effective time goes backwards, which
    -- is a genuine real-time reversal and is flagged.
    local bad = analyze.analyze(document.parse({
      "--- log utc-4 ---",
      "11:00 here",
      "12:00 there utc+2",
    }))
    t.eq(#bad.diagnostics, 1)
    t.eq(bad.diagnostics[1].code, "unordered_timestamps")
  end)

  t.test("analyze keeps the 24:00 boundary check in raw local time", function()
    -- The midnight-not-final rule is calendar, not real-time: a raw 24:00 that is
    -- not the final entry is flagged regardless of any offset carried on it.
    local analysis = analyze.analyze(document.parse({
      "--- log utc+2 ---",
      "08:00 plan",
      "24:00 close",
      "24:00 done",
    }))
    t.eq(#analysis.diagnostics, 1)
    t.eq(analysis.diagnostics[1].code, "midnight_not_final")
  end)

  t.test("analyze flags a blank entry that carries reporting metadata", function()
    -- A blank entry (bare timestamp) is uncounted and may carry no tag/location/marker/alias/nudge.
    for _, line in ipairs({ "11:00 #x", "11:00 @o", "11:00 !S[]", "11:00 round+1" }) do
      local bad = analyze.analyze(document.parse({ "--- log ---", "08:00 a", line, "12:00 done" }))
      t.eq(bad.diagnostics[1] and bad.diagnostics[1].code, "blank_entry_metadata")
    end
    -- A plain blank, and a blank carrying only a utc offset (a clock change), are fine.
    t.eq(
      #analyze.analyze(document.parse({ "--- log ---", "08:00 a", "11:00", "12:00 done" })).diagnostics,
      0
    )
  end)

  t.test("analyze reports a duplicate header utc offset", function()
    local analysis = analyze.analyze(document.parse({
      "--- log utc+2 utc-4 ---",
      "08:00 plan",
      "09:00 done",
    }))
    t.eq(analysis.diagnostics, {
      {
        code = "invalid_log_header_metadata",
        category = "structural",
        severity = "error",
        row = 1,
        message = "multiple log header utc offsets are not allowed",
      },
    })
  end)
end
