return function(t)
  local document = require("worklog.document")

  t.test("document parse preserves line kinds and rows", function()
    local doc = document.parse({
      "--- worklog #ProjectOrion @office quantize=30 ---",
      "08:00 plan",
      "note about planning",
      "",
      "--- summary exact ---",
    })

    t.eq(doc.kind, "document")
    t.eq(doc.row_count, 5)
    t.eq(doc.nodes, {
      {
        kind = "worklog_header",
        row = 1,
        raw = "--- worklog #ProjectOrion @office quantize=30 ---",
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
            key = "quantize",
            value = "30",
            raw = "quantize=30",
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
        raw = "--- summary exact ---",
        text = "summary exact",
      },
    })
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

  t.test("document parse recognizes trailing !L in flexible metadata order", function()
    t.eq(document.parse_line("08:21 negotiate with goose !L #sales @client"), {
      kind = "entry",
      row = 1,
      raw = "08:21 negotiate with goose !L #sales @client",
      minutes = 501,
      text = "negotiate with goose",
      explicit_tag = "sales",
      explicit_location = "client",
      logged = true,
    })

    t.eq(document.parse_line("08:21 negotiate with goose @client !L #sales"), {
      kind = "entry",
      row = 1,
      raw = "08:21 negotiate with goose @client !L #sales",
      minutes = 501,
      text = "negotiate with goose",
      explicit_tag = "sales",
      explicit_location = "client",
      logged = true,
    })
  end)

  t.test("document parse keeps worklog header metadata and options", function()
    t.eq(document.parse_line("--- worklog #ProjectOrion @office quantize=30 nope ---"), {
      kind = "worklog_header",
      row = 1,
      raw = "--- worklog #ProjectOrion @office quantize=30 nope ---",
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
          key = "quantize",
          value = "30",
          raw = "quantize=30",
        },
      },
      invalid_tokens = { "nope" },
    })

    t.eq(document.parse_line("--- worklog quantize=foo unknown=bar #internal @home ---"), {
      kind = "worklog_header",
      row = 1,
      raw = "--- worklog quantize=foo unknown=bar #internal @home ---",
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
          key = "quantize",
          value = "foo",
          raw = "quantize=foo",
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
      "--- worklog ---",
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

  t.test("document parse keeps inline !L in text unless it is trailing metadata", function()
    t.eq(document.parse_line("08:04 discuss !L marker syntax"), {
      kind = "entry",
      row = 1,
      raw = "08:04 discuss !L marker syntax",
      minutes = 484,
      text = "discuss !L marker syntax",
      explicit_tag = nil,
      explicit_location = nil,
    })
  end)

  t.test("document parse recognizes clear tokens in headers and entries", function()
    t.eq(document.parse_line("--- worklog #- @- quantize=30 ---"), {
      kind = "worklog_header",
      row = 1,
      raw = "--- worklog #- @- quantize=30 ---",
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
          key = "quantize",
          value = "30",
          raw = "quantize=30",
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

  t.test("document parse rejects duplicate trailing !L and keeps !L invalid in headers", function()
    t.eq(document.parse_line("08:04 plan !L #sales !L"), {
      kind = "invalid_entry",
      row = 1,
      raw = "08:04 plan !L #sales !L",
      message = "duplicate trailing !L markers are not allowed",
    })

    t.eq(document.parse_line("--- worklog !L ---"), {
      kind = "worklog_header",
      row = 1,
      raw = "--- worklog !L ---",
      metadata_tokens = {},
      option_tokens = {},
      invalid_tokens = { "!L" },
    })
  end)

  t.test("document parse marks malformed time-like lines as invalid entries", function()
    local doc = document.parse({
      "08:00 plan #sales #meeting",
      "08:00 plan @office @home",
      "24:00 no",
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
        raw = "24:00 no",
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
end
