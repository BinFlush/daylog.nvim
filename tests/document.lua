return function(t)
  local document = require("worklog.document")

  t.test("document parse preserves line kinds and rows", function()
    local doc = document.parse({
      "--- worklog default=#ProjectOrion ---",
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
        raw = "--- worklog default=#ProjectOrion ---",
        option_tokens = {
          {
            key = "default",
            value = "#ProjectOrion",
            raw = "default=#ProjectOrion",
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
        explicit_label = nil,
        excluded = false,
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
    t.eq(document.parse_line("08:21 negotiate with goose #sales"), {
      kind = "entry",
      row = 1,
      raw = "08:21 negotiate with goose #sales",
      minutes = 501,
      text = "negotiate with goose",
      explicit_label = "sales",
      excluded = false,
    })
  end)

  t.test("document parse keeps worklog header options", function()
    t.eq(document.parse_line("--- worklog default=#ProjectOrion quantize=30 nope ---"), {
      kind = "worklog_header",
      row = 1,
      raw = "--- worklog default=#ProjectOrion quantize=30 nope ---",
      option_tokens = {
        {
          key = "default",
          value = "#ProjectOrion",
          raw = "default=#ProjectOrion",
        },
        {
          key = "quantize",
          value = "30",
          raw = "quantize=30",
        },
      },
      invalid_tokens = { "nope" },
    })

    t.eq(document.parse_line("--- worklog quantize=foo unknown=bar default=sales ---"), {
      kind = "worklog_header",
      row = 1,
      raw = "--- worklog quantize=foo unknown=bar default=sales ---",
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
        {
          key = "default",
          value = "sales",
          raw = "default=sales",
        },
      },
      invalid_tokens = {},
    })
  end)

  t.test("document parse keeps explicit labels only", function()
    local doc = document.parse({
      "--- worklog ---",
      "08:21 negotiate with goose #sales",
      "08:52 coffee with ghost #ooo",
      "09:00 done",
    })

    t.eq(doc.nodes[2], {
      kind = "entry",
      row = 2,
      raw = "08:21 negotiate with goose #sales",
      minutes = 501,
      text = "negotiate with goose",
      explicit_label = "sales",
      excluded = false,
    })
    t.eq(doc.nodes[3], {
      kind = "entry",
      row = 3,
      raw = "08:52 coffee with ghost #ooo",
      minutes = 532,
      text = "coffee with ghost",
      explicit_label = "ooo",
      excluded = true,
    })
    t.eq(doc.nodes[4], {
      kind = "entry",
      row = 4,
      raw = "09:00 done",
      minutes = 540,
      text = "done",
      explicit_label = nil,
      excluded = false,
    })
  end)

  t.test("document parse marks malformed time-like lines as invalid entries", function()
    local doc = document.parse({
      "08:00 plan #sales #meeting",
      "24:00 no",
      "08:00x",
    })

    t.eq(doc.nodes, {
      {
        kind = "invalid_entry",
        row = 1,
        raw = "08:00 plan #sales #meeting",
        message = "multiple trailing labels are not allowed",
      },
      {
        kind = "invalid_entry",
        row = 2,
        raw = "24:00 no",
        message = "invalid time",
      },
      {
        kind = "invalid_entry",
        row = 3,
        raw = "08:00x",
        message = "expected whitespace after the time",
      },
    })
  end)
end
