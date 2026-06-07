return function(t)
  -- Contract test for syntax/worklog.vim. It guards against the highlighter
  -- drifting from the grammar that document.lua parses: every canonical token
  -- below must classify as the expected syntax group. When a new token is added
  -- to the parser, add it here too.

  local function group_at(lnum, col)
    return vim.fn.synIDattr(vim.fn.synID(lnum, col, 1), "name")
  end

  local function col_of(lnum, needle)
    local found = vim.fn.getline(lnum):find(needle, 1, true)
    assert(found, string.format("token %q not found on line %d", needle, lnum))
    return found
  end

  local function load_worklog_syntax(lines)
    vim.cmd("syntax enable")
    t.reset(lines)
    vim.bo.filetype = "worklog"
    vim.bo.syntax = "worklog"
  end

  t.test("syntax/worklog.vim classifies canonical tokens", function()
    load_worklog_syntax({
      "--- worklog #ClientA @office q=30 ---",
      "08:00 planning #ClientA @office",
      "10:00 meeting #ooo",
      "12:00 resume #- @-",
      "14:00 done !L",
      "--- summary q=15 d=dec ---",
      "1.75h (+2m) planning",
      "",
      "a free-form note",
      "10:17 #Q1 features",
      "24:00 done",
      "99:99 nonsense",
      "12:34xyz",
    })

    -- Worklog header and its contained metadata/option tokens.
    t.eq(group_at(1, 1), "WorklogHeader")
    t.eq(group_at(1, col_of(1, "#ClientA")), "WorklogTag")
    t.eq(group_at(1, col_of(1, "@office")), "WorklogLocation")
    t.eq(group_at(1, col_of(1, "q=30")), "WorklogOption")

    -- Entry timestamp and trailing sticky metadata.
    t.eq(group_at(2, 1), "WorklogTimestamp")
    t.eq(group_at(2, col_of(2, "#ClientA")), "WorklogTag")
    t.eq(group_at(2, col_of(2, "@office")), "WorklogLocation")

    -- #ooo is highlighted distinctly from a plain tag.
    t.eq(group_at(3, col_of(3, "#ooo")), "WorklogOoo")

    -- Clear tokens read as ordinary tag/location metadata.
    t.eq(group_at(4, col_of(4, "#-")), "WorklogTag")
    t.eq(group_at(4, col_of(4, "@-")), "WorklogLocation")

    -- Logged marker.
    t.eq(group_at(5, col_of(5, "!L")), "WorklogLogged")

    -- Generated section header (non-worklog) and quantized summary row. The row
    -- sits inside the WorklogSummaryBlock region, ended by the blank line below.
    t.eq(group_at(6, 1), "WorklogBlockHeader")
    t.eq(group_at(7, 1), "WorklogDuration")
    t.eq(group_at(7, col_of(7, "(+2m)")), "WorklogQuantError")

    -- Free-form note line (outside the summary region).
    t.eq(group_at(9, 1), "WorklogNote")

    -- A '#' that is not part of the trailing metadata run is plain text, never a
    -- tag, mirroring the parser's trailing-only metadata rule.
    t.eq(group_at(10, 1), "WorklogTimestamp")
    t.ok(
      group_at(10, col_of(10, "#Q1")) ~= "WorklogTag",
      "mid-text #Q1 must not highlight as a tag"
    )

    -- 24:00 is a valid end-of-day boundary and still highlights as a timestamp.
    t.eq(group_at(11, 1), "WorklogTimestamp")

    -- Out-of-range times mirror the parser's rejection: 99:99 is not a
    -- timestamp, so it falls through to a free-form note.
    t.ok(
      group_at(12, 1) ~= "WorklogTimestamp",
      "out-of-range 99:99 must not highlight as a timestamp"
    )

    -- A time glued to non-whitespace is not an entry for the parser, so it must
    -- not highlight as a timestamp either.
    t.ok(group_at(13, 1) ~= "WorklogTimestamp", "12:34xyz must not highlight as a timestamp")
  end)

  t.test(
    "trailing metadata tolerates trailing whitespace, any order, and rejects text after",
    function()
      load_worklog_syntax({
        "08:00 task #tag ",
        "09:00 task @home #tag  ",
        "10:00 task #tag note",
      })

      -- A trailing space after metadata still highlights; the parser ignores it.
      t.eq(group_at(1, col_of(1, "#tag")), "WorklogTag")

      -- Tag and location in either order, with trailing spaces, both highlight.
      t.eq(group_at(2, col_of(2, "@home")), "WorklogLocation")
      t.eq(group_at(2, col_of(2, "#tag")), "WorklogTag")

      -- Metadata followed by ordinary text is plain text, mirroring the parser.
      t.ok(
        group_at(3, col_of(3, "#tag")) ~= "WorklogTag",
        "a tag before trailing text must not highlight"
      )
    end
  )

  t.test("a trailing run with a repeated kind highlights nothing, like the parser", function()
    load_worklog_syntax({
      "08:00 task #a #b",
      "09:00 task @a @b",
      "10:00 task #a !L #b",
      "11:00 task !L @b #a",
    })

    -- Two tags: the parser rejects the entry, so neither tag highlights.
    t.ok(group_at(1, col_of(1, "#a")) ~= "WorklogTag", "first of two tags must not highlight")
    t.ok(group_at(1, col_of(1, "#b")) ~= "WorklogTag", "second of two tags must not highlight")

    -- Two locations: likewise neither highlights.
    t.ok(
      group_at(2, col_of(2, "@a")) ~= "WorklogLocation",
      "first of two locations must not highlight"
    )
    t.ok(
      group_at(2, col_of(2, "@b")) ~= "WorklogLocation",
      "second of two locations must not highlight"
    )

    -- A repeated kind anywhere in the run invalidates the whole run.
    t.ok(
      group_at(3, col_of(3, "#a")) ~= "WorklogTag",
      "a repeated tag around !L must not highlight"
    )

    -- One of each, in any order, is valid and all three highlight.
    t.eq(group_at(4, col_of(4, "!L")), "WorklogLogged")
    t.eq(group_at(4, col_of(4, "@b")), "WorklogLocation")
    t.eq(group_at(4, col_of(4, "#a")), "WorklogTag")
  end)

  t.test("a header with a repeated tag or location is not a worklog header", function()
    load_worklog_syntax({
      "--- worklog #a #b ---",
      "--- worklog @a @b ---",
      "--- worklog #a @b q=30 ---",
      "--- worklog @b #a ---",
    })

    -- Duplicate tag: the whole header falls back to a generic block header and the
    -- metadata is not highlighted, mirroring the parser rejecting the header.
    t.eq(group_at(1, 1), "WorklogBlockHeader")
    t.ok(group_at(1, col_of(1, "#a")) ~= "WorklogTag", "a duplicate header tag must not highlight")

    -- Duplicate location: likewise.
    t.eq(group_at(2, 1), "WorklogBlockHeader")
    t.ok(
      group_at(2, col_of(2, "@a")) ~= "WorklogLocation",
      "a duplicate header location must not highlight"
    )

    -- One tag and one location (any order, intermixed with options) stays valid.
    t.eq(group_at(3, 1), "WorklogHeader")
    t.eq(group_at(3, col_of(3, "#a")), "WorklogTag")
    t.eq(group_at(3, col_of(3, "@b")), "WorklogLocation")
    t.eq(group_at(3, col_of(3, "q=30")), "WorklogOption")
    t.eq(group_at(4, 1), "WorklogHeader")
    t.eq(group_at(4, col_of(4, "#a")), "WorklogTag")
    t.eq(group_at(4, col_of(4, "@b")), "WorklogLocation")
  end)

  t.test("only valid header options highlight; the parser's rejects fall back", function()
    load_worklog_syntax({
      "--- worklog q=30 ---", -- 1 valid quantize
      "--- worklog d=dec ---", -- 2 valid duration
      "--- worklog d=hm ---", -- 3 valid duration
      "--- worklog q=01 ---", -- 4 leading zero, value > 0 (parser accepts)
      "--- worklog #a @b q=5 d=hm ---", -- 5 all four, any order
      "--- worklog q=abc ---", -- 6 non-numeric value
      "--- worklog q=0 ---", -- 7 not positive
      "--- worklog q=1.5 ---", -- 8 not an integer
      "--- worklog d=foo ---", -- 9 value not dec/hm
      "--- worklog foo=bar ---", -- 10 unknown option
      "--- worklog q=15 q=30 ---", -- 11 duplicate option
      "--- worklog hello ---", -- 12 junk token
    })

    -- Valid options highlight as options inside a worklog header.
    t.eq(group_at(1, 1), "WorklogHeader")
    t.eq(group_at(1, col_of(1, "q=30")), "WorklogOption")
    t.eq(group_at(2, col_of(2, "d=dec")), "WorklogOption")
    t.eq(group_at(3, col_of(3, "d=hm")), "WorklogOption")
    t.eq(group_at(4, col_of(4, "q=01")), "WorklogOption")
    t.eq(group_at(5, 1), "WorklogHeader")
    t.eq(group_at(5, col_of(5, "#a")), "WorklogTag")
    t.eq(group_at(5, col_of(5, "@b")), "WorklogLocation")
    t.eq(group_at(5, col_of(5, "q=5")), "WorklogOption")
    t.eq(group_at(5, col_of(5, "d=hm")), "WorklogOption")

    -- Anything the parser rejects makes the line a plain block header, and the
    -- offending token is not highlighted as an option.
    local rejects = {
      { 6, "q=abc" },
      { 7, "q=0" },
      { 8, "q=1.5" },
      { 9, "d=foo" },
      { 10, "foo=bar" },
      { 11, "q=15" },
      { 12, "hello" },
    }
    for _, case in ipairs(rejects) do
      local lnum, token = case[1], case[2]
      t.eq(group_at(lnum, 1), "WorklogBlockHeader")
      t.ok(
        group_at(lnum, col_of(lnum, token)) ~= "WorklogOption",
        string.format("%q on line %d must not highlight as an option", token, lnum)
      )
    end
  end)

  t.test("a line with an invalid timestamp does not highlight trailing metadata", function()
    load_worklog_syntax({
      "25:00 task #tag", -- out-of-range time: not an entry for the parser
      "12:34xyz #tag", -- time glued to text: not an entry either
    })

    -- The whole line is a free-form note, so the trailing #tag is not metadata.
    t.ok(group_at(1, 1) ~= "WorklogTimestamp", "25:00 is not a timestamp")
    t.ok(
      group_at(1, col_of(1, "#tag")) ~= "WorklogTag",
      "#tag on an invalid entry must not highlight"
    )
    t.ok(
      group_at(2, col_of(2, "#tag")) ~= "WorklogTag",
      "#tag after a glued time must not highlight"
    )
  end)

  t.test("hhmm summary rows highlight as durations, not timestamps or notes", function()
    load_worklog_syntax({
      "0:30 (+4m) planning",
      "16:00 (-20m) workday",
      "1:30 planning",
      "08:00 planning",
    })

    -- Quantized hhmm row: the duration highlights and the (+Nm) error is distinct.
    t.eq(group_at(1, 1), "WorklogDuration")
    t.eq(group_at(1, col_of(1, "(+4m)")), "WorklogQuantError")

    -- A two-digit-hour quantized row beats the timestamp match.
    t.eq(group_at(2, 1), "WorklogDuration")

    -- An exact single-digit-hour duration, which can never be an entry.
    t.eq(group_at(3, 1), "WorklogDuration")

    -- A zero-padded HH:MM entry still reads as a timestamp, not a duration.
    t.eq(group_at(4, 1), "WorklogTimestamp")
  end)

  t.test("two-digit-hour hhmm summary rows highlight as durations via block context", function()
    load_worklog_syntax({
      "--- worklog d=hm ---",
      "08:00 deep work",
      "",
      "--- summary q=15 d=dec ---",
      "16:00 deep work #ClientA",
      "2:00 admin",
      "",
      "--- totals ---",
      "16:00 workday",
    })

    -- An entry in the worklog body still reads as a timestamp.
    t.eq(group_at(2, 1), "WorklogTimestamp")

    -- Generated section headers stay block headers.
    t.eq(group_at(4, 1), "WorklogBlockHeader")
    t.eq(group_at(8, 1), "WorklogBlockHeader")

    -- Inside a summary section a two-digit-hour hhmm row is a duration, not a
    -- timestamp -- the case the line matches alone cannot resolve.
    t.eq(group_at(5, 1), "WorklogDuration")
    t.eq(group_at(9, 1), "WorklogDuration")

    -- Single-digit-hour rows and trailing metadata still highlight inside it.
    t.eq(group_at(6, 1), "WorklogDuration")
    t.eq(group_at(5, col_of(5, "#ClientA")), "WorklogTag")
  end)
end
