return function(t)
  local document = require("daylog.document")
  local syntax = require("daylog.syntax")

  t.test("document parse preserves line kinds and rows", function()
    local doc = document.parse({
      "--- log #ProjectOrion @office q=30 ---",
      "08:00 plan",
      "note about planning",
      "",
      "--- summary q=15 d=dec ---",
    })

    t.eq(doc.kind, "document")
    t.eq(doc.row_count, 5)
    t.eq(doc.nodes, {
      {
        kind = "log_header",
        row = 1,
        raw = "--- log #ProjectOrion @office q=30 ---",
        metadata_tokens = {
          {
            kind = "tag",
            value = "ProjectOrion",
            raw = "#ProjectOrion",
          },
          {
            kind = "location",
            value = "office",
            raw = "@office",
          },
        },
        option_tokens = {
          {
            key = "q",
            value = "30",
            raw = "q=30",
          },
        },
        invalid_tokens = {},
      },
      {
        kind = "entry",
        row = 2,
        raw = "08:00 plan",
        minutes = 480,
        text = "plan",
        explicit_tag = nil,
        explicit_location = nil,
      },
      {
        kind = "note_line",
        row = 3,
        raw = "note about planning",
        text = "note about planning",
      },
      {
        kind = "blank_line",
        row = 4,
        raw = "",
      },
      {
        kind = "block_header",
        row = 5,
        raw = "--- summary q=15 d=dec ---",
        text = "summary q=15 d=dec",
      },
    })
  end)

  t.test("document parse requires log to be its own word in a header", function()
    t.eq(document.parse_line("--- log ---").kind, "log_header")
    t.eq(document.parse_line("--- log #ClientA ---").kind, "log_header")
    t.eq(document.parse_line("--- log---").kind, "log_header")
    -- Not log headers, and not summary-section headers either, so they are not
    -- structural boundaries: an unrecognized `--- x ---` parses as a note line.
    t.eq(document.parse_line("--- logs ---").kind, "note_line")
    t.eq(document.parse_line("--- log#sales ---").kind, "note_line")
    t.eq(document.parse_line("--- logs to review ---").kind, "note_line")
    t.eq(document.parse_line("--- notes ---").kind, "note_line")
    -- A generated summary-section header IS recognized and stays a boundary.
    t.eq(document.parse_line("--- tags ---").kind, "block_header")
    t.eq(document.parse_line("--- summary q=15 d=dec ---").kind, "block_header")
  end)

  t.test("a section word in second position is a boundary only after a report prefix", function()
    -- Report headers stay recognized...
    t.eq(document.parse_line("--- day summary 2026-05-04 q=15 ---").kind, "block_header")
    t.eq(document.parse_line("--- range totals week 19 ---").kind, "block_header")
    -- ...but prose containing a section word is a note, never a structural boundary.
    t.eq(document.parse_line("--- meeting summary ---").kind, "note_line")
    t.eq(document.parse_line("--- quarterly totals ---").kind, "note_line")

    -- The load-bearing consequence: such prose inside a log cannot fragment it.
    local analyze = require("daylog.analyze")
    local analysis = analyze.analyze(document.parse({
      "--- log ---",
      "08:00 work",
      "--- meeting summary ---",
      "09:00 more",
      "10:00 done",
    }))
    t.eq(#analysis.diagnostics, 0)
    t.eq(#analysis.log_blocks[1].entries, 3)
  end)

  t.test("document parse_line parses a single line directly", function()
    t.eq(document.parse_line("08:21 negotiate with goose #sales @client"), {
      kind = "entry",
      row = 1,
      raw = "08:21 negotiate with goose #sales @client",
      minutes = 501,
      text = "negotiate with goose",
      explicit_tag = "sales",
      explicit_location = "client",
    })
  end)

  t.test("document parse recognizes trailing !S in flexible metadata order", function()
    t.eq(document.parse_line("08:21 negotiate with goose !S #sales @client"), {
      kind = "entry",
      row = 1,
      raw = "08:21 negotiate with goose !S #sales @client",
      minutes = 501,
      text = "negotiate with goose",
      explicit_tag = "sales",
      explicit_location = "client",
      logged = { s = true },
    })

    t.eq(document.parse_line("08:21 negotiate with goose @client !S #sales"), {
      kind = "entry",
      row = 1,
      raw = "08:21 negotiate with goose @client !S #sales",
      minutes = 501,
      text = "negotiate with goose",
      explicit_tag = "sales",
      explicit_location = "client",
      logged = { s = true },
    })
  end)

  t.test("document parse keeps log header metadata and options", function()
    t.eq(document.parse_line("--- log #ProjectOrion @office q=30 nope ---"), {
      kind = "log_header",
      row = 1,
      raw = "--- log #ProjectOrion @office q=30 nope ---",
      metadata_tokens = {
        {
          kind = "tag",
          value = "ProjectOrion",
          raw = "#ProjectOrion",
        },
        {
          kind = "location",
          value = "office",
          raw = "@office",
        },
      },
      option_tokens = {
        {
          key = "q",
          value = "30",
          raw = "q=30",
        },
      },
      invalid_tokens = { "nope" },
    })

    t.eq(document.parse_line("--- log q=foo unknown=bar #internal @home ---"), {
      kind = "log_header",
      row = 1,
      raw = "--- log q=foo unknown=bar #internal @home ---",
      metadata_tokens = {
        {
          kind = "tag",
          value = "internal",
          raw = "#internal",
        },
        {
          kind = "location",
          value = "home",
          raw = "@home",
        },
      },
      option_tokens = {
        {
          key = "q",
          value = "foo",
          raw = "q=foo",
        },
        {
          key = "unknown",
          value = "bar",
          raw = "unknown=bar",
        },
      },
      invalid_tokens = {},
    })
  end)

  t.test("document parse keeps explicit entry metadata only", function()
    local doc = document.parse({
      "--- log ---",
      "08:21 negotiate with goose #sales",
      "08:52 coffee with ghost #ooo @home",
      "09:00 done",
    })

    t.eq(doc.nodes[2], {
      kind = "entry",
      row = 2,
      raw = "08:21 negotiate with goose #sales",
      minutes = 501,
      text = "negotiate with goose",
      explicit_tag = "sales",
      explicit_location = nil,
    })
    t.eq(doc.nodes[3], {
      kind = "entry",
      row = 3,
      raw = "08:52 coffee with ghost #ooo @home",
      minutes = 532,
      text = "coffee with ghost",
      explicit_tag = "ooo",
      explicit_location = "home",
    })
    t.eq(doc.nodes[4], {
      kind = "entry",
      row = 4,
      raw = "09:00 done",
      minutes = 540,
      text = "done",
      explicit_tag = nil,
      explicit_location = nil,
    })
  end)

  t.test("document parse keeps inline hashtags in text", function()
    t.eq(document.parse_line("08:04 fix #123 issue #sales @office"), {
      kind = "entry",
      row = 1,
      raw = "08:04 fix #123 issue #sales @office",
      minutes = 484,
      text = "fix #123 issue",
      explicit_tag = "sales",
      explicit_location = "office",
    })
  end)

  t.test("document parse keeps inline !S in text unless it is trailing metadata", function()
    t.eq(document.parse_line("08:04 discuss !S marker syntax"), {
      kind = "entry",
      row = 1,
      raw = "08:04 discuss !S marker syntax",
      minutes = 484,
      text = "discuss !S marker syntax",
      explicit_tag = nil,
      explicit_location = nil,
    })
  end)

  t.test("document parse recognizes clear tokens in headers and entries", function()
    t.eq(document.parse_line("--- log #- @- q=30 ---"), {
      kind = "log_header",
      row = 1,
      raw = "--- log #- @- q=30 ---",
      metadata_tokens = {
        {
          kind = "tag",
          value = nil,
          clear = true,
          raw = "#-",
        },
        {
          kind = "location",
          value = nil,
          clear = true,
          raw = "@-",
        },
      },
      option_tokens = {
        {
          key = "q",
          value = "30",
          raw = "q=30",
        },
      },
      invalid_tokens = {},
    })

    t.eq(document.parse_line("08:04 reset #- @-"), {
      kind = "entry",
      row = 1,
      raw = "08:04 reset #- @-",
      minutes = 484,
      text = "reset",
      explicit_tag = nil,
      explicit_tag_clear = true,
      explicit_location = nil,
      explicit_location_clear = true,
    })
  end)

  t.test("document parse rejects duplicate trailing !S and keeps !S invalid in headers", function()
    t.eq(document.parse_line("08:04 plan !S #sales !S"), {
      kind = "invalid_entry",
      row = 1,
      raw = "08:04 plan !S #sales !S",
      message = "duplicate trailing !S markers are not allowed",
    })

    t.eq(document.parse_line("--- log !S ---"), {
      kind = "log_header",
      row = 1,
      raw = "--- log !S ---",
      metadata_tokens = {},
      option_tokens = {},
      invalid_tokens = { "!S" },
    })

    -- A bare and a frozen !S are still two markers; the duplicate guard rejects them.
    t.eq(
      document.parse_line("08:04 plan !S !S60").message,
      "duplicate trailing !S markers are not allowed"
    )
  end)

  t.test("document parses a frozen !S value and classifies it as a logged token", function()
    local node = document.parse_line("08:04 plan !S60")
    t.eq(node.kind, "entry")
    t.eq(node.logged, { s = 60 })

    local kind = document.classify_control_token("!S60")
    t.eq(kind, "logged")
    t.eq(document.classify_control_token("!Slamas"), nil)
  end)

  t.test("document parse marks malformed time-like lines as invalid entries", function()
    local doc = document.parse({
      "08:00 plan #sales #meeting",
      "08:00 plan @office @home",
      "24:30 no",
      "08:00x",
    })

    t.eq(doc.nodes, {
      {
        kind = "invalid_entry",
        row = 1,
        raw = "08:00 plan #sales #meeting",
        message = "multiple trailing tags are not allowed",
      },
      {
        kind = "invalid_entry",
        row = 2,
        raw = "08:00 plan @office @home",
        message = "multiple trailing locations are not allowed",
      },
      {
        kind = "invalid_entry",
        row = 3,
        raw = "24:30 no",
        message = "invalid time",
      },
      {
        kind = "invalid_entry",
        row = 4,
        raw = "08:00x",
        message = "expected whitespace after the time",
      },
    })
  end)

  t.test("document parse accepts 24:00 as an end-of-day boundary", function()
    t.eq(document.parse_line("24:00"), {
      kind = "entry",
      row = 1,
      raw = "24:00",
      minutes = 1440,
      text = "",
      explicit_tag = nil,
      explicit_location = nil,
    })
  end)

  t.test("document parse rejects times past 24:00", function()
    t.eq(document.parse_line("24:01"), {
      kind = "invalid_entry",
      row = 1,
      raw = "24:01",
      message = "invalid time",
    })

    t.eq(document.parse_line("25:00"), {
      kind = "invalid_entry",
      row = 1,
      raw = "25:00",
      message = "invalid time",
    })
  end)

  t.test("document parses a summary-shaped timestamp row as a note, not an entry", function()
    -- A d=hm summary row ("16:00 (+0m) workday") is byte-for-byte an entry timestamp
    -- plus a (+Nm) marker; the marker makes it a note so it can never be miscounted as
    -- an entry if it leaks into a log body.
    local doc = document.parse({ "16:00 (+0m) workday", "16:00 standup" })
    t.eq(doc.nodes[1].kind, "note_line")
    t.eq(doc.nodes[2].kind, "entry")
  end)

  t.test("syntax parses utc offsets to signed minutes and round-trips them", function()
    t.eq(syntax.parse_utc_offset("utc+2"), 120)
    t.eq(syntax.parse_utc_offset("utc-4"), -240)
    t.eq(syntax.parse_utc_offset("utc+0"), 0)
    t.eq(syntax.parse_utc_offset("utc+5:30"), 330)
    t.eq(syntax.parse_utc_offset("utc-3:45"), -225)

    -- The sign is mandatory and the value must be a real offset; anything else is
    -- not an offset (so it stays activity text rather than being silently misread).
    t.eq(syntax.parse_utc_offset("utc"), nil)
    t.eq(syntax.parse_utc_offset("utc-x"), nil)
    t.eq(syntax.parse_utc_offset("utc+2:60"), nil)
    t.eq(syntax.parse_utc_offset("utc+99"), nil)
    t.eq(syntax.parse_utc_offset("utcby"), nil)

    -- The canonical token: ":MM" appears only when nonzero, and 0 is "utc+0".
    t.eq(syntax.utc_offset_token(0), "utc+0")
    t.eq(syntax.utc_offset_token(120), "utc+2")
    t.eq(syntax.utc_offset_token(-240), "utc-4")
    t.eq(syntax.utc_offset_token(330), "utc+5:30")
    t.eq(syntax.utc_offset_token(-225), "utc-3:45")
  end)

  t.test("document parses a trailing utc offset and peels a preceding tag", function()
    t.eq(document.parse_line("11:00 resume #sales utc-4"), {
      kind = "entry",
      row = 1,
      raw = "11:00 resume #sales utc-4",
      minutes = 660,
      text = "resume",
      explicit_tag = "sales",
      explicit_location = nil,
      explicit_offset = -240,
    })

    -- Order within the trailing run is free, like #tag/@location/!S.
    t.eq(document.parse_line("08:00 standup utc+2 @office !S").explicit_offset, 120)
    t.eq(document.parse_line("08:00 standup @office utc+2 !S").explicit_offset, 120)
  end)

  t.test("document leaves a malformed utc token as plain activity text (fail-safe)", function()
    for _, line in ipairs({
      "08:00 sync about utc",
      "08:00 talk utc-x",
      "08:00 talk utc+2:60",
      "08:00 talk utc+99",
    }) do
      local node = document.parse_line(line)
      t.eq(node.kind, "entry")
      t.eq(node.explicit_offset, nil)
      t.eq(node.text, line:match("^%d%d:%d%d%s+(.+)$"))
    end
  end)

  t.test("document rejects a duplicate trailing utc offset", function()
    t.eq(document.parse_line("08:00 plan utc+2 utc-4"), {
      kind = "invalid_entry",
      row = 1,
      raw = "08:00 plan utc+2 utc-4",
      message = "multiple trailing utc offsets are not allowed",
    })
  end)

  t.test("document routes a header utc offset into metadata tokens", function()
    t.eq(document.parse_line("--- log @office utc+2 q=30 ---"), {
      kind = "log_header",
      row = 1,
      raw = "--- log @office utc+2 q=30 ---",
      metadata_tokens = {
        { kind = "location", value = "office", raw = "@office" },
        { kind = "offset", value = 120, raw = "utc+2" },
      },
      option_tokens = {
        { key = "q", value = "30", raw = "q=30" },
      },
      invalid_tokens = {},
    })

    -- A malformed header offset stays an invalid token, so the header is demoted.
    t.eq(document.parse_line("--- log utc+99 ---").invalid_tokens, { "utc+99" })
  end)

  t.test("syntax parses and renders round nudges (sign required)", function()
    t.eq(syntax.parse_round_nudge("round+1"), 1)
    t.eq(syntax.parse_round_nudge("round-2"), -2)
    t.eq(syntax.parse_round_nudge("round+0"), 0)
    t.eq(syntax.parse_round_nudge("round"), nil)
    t.eq(syntax.parse_round_nudge("round+"), nil)
    t.eq(syntax.parse_round_nudge("round+x"), nil)
    t.eq(syntax.parse_round_nudge("rounding"), nil)
    t.eq(syntax.round_nudge_token(1), "round+1")
    t.eq(syntax.round_nudge_token(-2), "round-2")
  end)

  t.test("document parses a trailing round nudge and peels a preceding tag", function()
    t.eq(document.parse_line("08:00 plan #sales round+1"), {
      kind = "entry",
      row = 1,
      raw = "08:00 plan #sales round+1",
      minutes = 480,
      text = "plan",
      explicit_tag = "sales",
      explicit_location = nil,
      nudge = 1,
    })

    -- Order-free within the trailing run, alongside the other tokens.
    t.eq(document.parse_line("08:00 plan round-2 @office !S").nudge, -2)
  end)

  t.test("document leaves a non-nudge round token as text and rejects duplicates", function()
    local node = document.parse_line("08:00 take another round")
    t.eq(node.kind, "entry")
    t.eq(node.nudge, nil)
    t.eq(node.text, "take another round")

    t.eq(document.parse_line("08:00 plan round+1 round-1"), {
      kind = "invalid_entry",
      row = 1,
      raw = "08:00 plan round+1 round-1",
      message = "multiple trailing round markers are not allowed",
    })
  end)

  t.test("document does not treat a header round token as metadata", function()
    -- round±N is entry-only (non-sticky); in a header it is just an invalid token.
    t.eq(document.parse_line("--- log round+1 ---").invalid_tokens, { "round+1" })
  end)

  t.test("document parse splits a => alias off an entry, before its trailing metadata", function()
    local node = document.parse_line("09:00 fix login => BUG-123 Fix it #ProjectOrion")
    t.eq(node.kind, syntax.NODE_KIND.ENTRY)
    t.eq(node.text, "fix login")
    t.eq(node.explicit_tag, "ProjectOrion")
    t.eq(node.alias, "BUG-123 Fix it")
  end)

  t.test("document alias_span covers the => label, excluding trailing metadata", function()
    local line = "09:00 fix => BUG-123 Login #ClientA"
    local span = document.alias_span(line)
    t.eq(line:sub(span.col_start + 1, span.col_end), "=> BUG-123 Login")
    -- A line with no alias has no span.
    t.eq(document.alias_span("09:00 fix login"), nil)
    -- An arrow with no description before it (only the timestamp) is not an alias, matching
    -- parse_entry, which reads `09:00 => foo` as the description "=> foo" with no alias.
    t.eq(document.alias_span("09:00 => foo"), nil)
  end)

  t.test("syntax.is_summary_row requires the marker's sign", function()
    -- Generated rows always carry a signed `(±Nm)` marker (render uses %+d), so the predicate
    -- requires the sign. A hand-written note shaped like an unsigned `(Nm)` is not a row, so it
    -- is preserved rather than swept when the summary span is located.
    t.ok(syntax.is_summary_row("3.00h (+0m) workday"))
    t.ok(syntax.is_summary_row("9:54 (-13m) design2 !S"))
    t.ok(not syntax.is_summary_row("lunch (5m) break"))
  end)
end
