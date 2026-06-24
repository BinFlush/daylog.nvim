return function(t)
  -- Contract test for the parser-driven highlighter (lua/daylog/highlight.lua).
  -- Highlighting is derived from the same parse the plugin reads a file with, so
  -- this guards that every canonical token classifies as the expected group. When
  -- a new token is added to the parser, add it here too.
  local highlight = require("daylog.highlight")

  local current_spans = {}
  local current_lines = {}

  local function load(lines)
    current_lines = lines
    current_spans = highlight.spans(lines)
  end

  -- The highlight group at a 1-based line/column (matching the old synID-based
  -- harness): the highest-priority span covering that byte, or "" when none does.
  -- Narrower token spans carry a higher priority than the whole-line base they sit
  -- on, so a tag inside a header wins at its own cells.
  local function group_at(lnum, col)
    local line = lnum - 1
    local byte = col - 1
    local best, best_priority
    for _, span in ipairs(current_spans) do
      if span.line == line and byte >= span.col_start and byte < span.col_end then
        if not best or span.priority >= best_priority then
          best = span.group
          best_priority = span.priority
        end
      end
    end
    return best or ""
  end

  local function col_of(lnum, needle)
    local found = current_lines[lnum]:find(needle, 1, true)
    assert(found, string.format("token %q not found on line %d", needle, lnum))
    return found
  end

  t.test("the highlighter classifies canonical tokens", function()
    load({
      "--- log #ClientA @office q=30 ---",
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

    -- Daylog header and its contained metadata/option tokens.
    t.eq(group_at(1, 1), "DaylogHeader")
    t.eq(group_at(1, col_of(1, "#ClientA")), "DaylogTag")
    t.eq(group_at(1, col_of(1, "@office")), "DaylogLocation")
    t.eq(group_at(1, col_of(1, "q=30")), "DaylogOption")

    -- Entry timestamp and trailing sticky metadata.
    t.eq(group_at(2, 1), "DaylogTimestamp")
    t.eq(group_at(2, col_of(2, "#ClientA")), "DaylogTag")
    t.eq(group_at(2, col_of(2, "@office")), "DaylogLocation")

    -- #ooo is highlighted distinctly from a plain tag.
    t.eq(group_at(3, col_of(3, "#ooo")), "DaylogOoo")

    -- Clear tokens read as ordinary tag/location metadata.
    t.eq(group_at(4, col_of(4, "#-")), "DaylogTag")
    t.eq(group_at(4, col_of(4, "@-")), "DaylogLocation")

    -- Logged marker.
    t.eq(group_at(5, col_of(5, "!L")), "DaylogLogged")

    -- Generated section header and quantized summary row. The row sits inside the
    -- summary section, ended by the blank line below.
    t.eq(group_at(6, 1), "DaylogBlockHeader")
    t.eq(group_at(7, 1), "DaylogDuration")
    t.eq(group_at(7, col_of(7, "(+2m)")), "DaylogQuantError")

    -- Free-form note line (after the summary section's terminating blank).
    t.eq(group_at(9, 1), "DaylogNote")

    -- A '#' that is not part of the trailing metadata run is plain text, never a
    -- tag, mirroring the parser's trailing-only metadata rule.
    t.eq(group_at(10, 1), "DaylogTimestamp")
    t.ok(group_at(10, col_of(10, "#Q1")) ~= "DaylogTag", "mid-text #Q1 must not highlight as a tag")

    -- 24:00 is a valid end-of-day boundary and still highlights as a timestamp.
    t.eq(group_at(11, 1), "DaylogTimestamp")

    -- Out-of-range times mirror the parser's rejection: 99:99 is not a timestamp.
    t.ok(
      group_at(12, 1) ~= "DaylogTimestamp",
      "out-of-range 99:99 must not highlight as a timestamp"
    )

    -- A time glued to non-whitespace is not an entry for the parser, so it must
    -- not highlight as a timestamp either.
    t.ok(group_at(13, 1) ~= "DaylogTimestamp", "12:34xyz must not highlight as a timestamp")
  end)

  t.test(
    "trailing metadata tolerates trailing whitespace, any order, and rejects text after",
    function()
      load({
        "08:00 task #tag ",
        "09:00 task @home #tag  ",
        "10:00 task #tag note",
      })

      -- A trailing space after metadata still highlights; the parser ignores it.
      t.eq(group_at(1, col_of(1, "#tag")), "DaylogTag")

      -- Tag and location in either order, with trailing spaces, both highlight.
      t.eq(group_at(2, col_of(2, "@home")), "DaylogLocation")
      t.eq(group_at(2, col_of(2, "#tag")), "DaylogTag")

      -- Metadata followed by ordinary text is plain text, mirroring the parser.
      t.ok(
        group_at(3, col_of(3, "#tag")) ~= "DaylogTag",
        "a tag before trailing text must not highlight"
      )
    end
  )

  t.test("a trailing run with a repeated kind highlights nothing, like the parser", function()
    load({
      "08:00 task #a #b",
      "09:00 task @a @b",
      "10:00 task #a !L #b",
      "11:00 task !L @b #a",
    })

    -- Two tags: the parser rejects the entry, so neither tag highlights.
    t.ok(group_at(1, col_of(1, "#a")) ~= "DaylogTag", "first of two tags must not highlight")
    t.ok(group_at(1, col_of(1, "#b")) ~= "DaylogTag", "second of two tags must not highlight")

    -- Two locations: likewise neither highlights.
    t.ok(
      group_at(2, col_of(2, "@a")) ~= "DaylogLocation",
      "first of two locations must not highlight"
    )
    t.ok(
      group_at(2, col_of(2, "@b")) ~= "DaylogLocation",
      "second of two locations must not highlight"
    )

    -- A repeated kind anywhere in the run invalidates the whole run.
    t.ok(group_at(3, col_of(3, "#a")) ~= "DaylogTag", "a repeated tag around !L must not highlight")

    -- One of each, in any order, is valid and all three highlight.
    t.eq(group_at(4, col_of(4, "!L")), "DaylogLogged")
    t.eq(group_at(4, col_of(4, "@b")), "DaylogLocation")
    t.eq(group_at(4, col_of(4, "#a")), "DaylogTag")
  end)

  t.test("a header with a repeated tag or location is not a log header", function()
    load({
      "--- log #a #b ---",
      "--- log @a @b ---",
      "--- log #a @b q=30 ---",
      "--- log @b #a ---",
    })

    -- Duplicate tag: the whole header falls back to a generic block header and the
    -- metadata is not highlighted, mirroring the parser rejecting the header.
    t.eq(group_at(1, 1), "DaylogBlockHeader")
    t.ok(group_at(1, col_of(1, "#a")) ~= "DaylogTag", "a duplicate header tag must not highlight")

    -- Duplicate location: likewise.
    t.eq(group_at(2, 1), "DaylogBlockHeader")
    t.ok(
      group_at(2, col_of(2, "@a")) ~= "DaylogLocation",
      "a duplicate header location must not highlight"
    )

    -- One tag and one location (any order, intermixed with options) stays valid.
    t.eq(group_at(3, 1), "DaylogHeader")
    t.eq(group_at(3, col_of(3, "#a")), "DaylogTag")
    t.eq(group_at(3, col_of(3, "@b")), "DaylogLocation")
    t.eq(group_at(3, col_of(3, "q=30")), "DaylogOption")
    t.eq(group_at(4, 1), "DaylogHeader")
    t.eq(group_at(4, col_of(4, "#a")), "DaylogTag")
    t.eq(group_at(4, col_of(4, "@b")), "DaylogLocation")
  end)

  t.test("only valid header options highlight; the parser's rejects fall back", function()
    load({
      "--- log q=30 ---", -- 1 valid quantize
      "--- log d=dec ---", -- 2 valid duration
      "--- log d=hm ---", -- 3 valid duration
      "--- log q=01 ---", -- 4 leading zero, value > 0 (parser accepts)
      "--- log #a @b q=5 d=hm ---", -- 5 all four, any order
      "--- log q=abc ---", -- 6 non-numeric value
      "--- log q=0 ---", -- 7 not positive
      "--- log q=1.5 ---", -- 8 not an integer
      "--- log d=foo ---", -- 9 value not dec/hm
      "--- log foo=bar ---", -- 10 unknown option
      "--- log q=15 q=30 ---", -- 11 duplicate option
      "--- log hello ---", -- 12 junk token
    })

    -- Valid options highlight as options inside a log header.
    t.eq(group_at(1, 1), "DaylogHeader")
    t.eq(group_at(1, col_of(1, "q=30")), "DaylogOption")
    t.eq(group_at(2, col_of(2, "d=dec")), "DaylogOption")
    t.eq(group_at(3, col_of(3, "d=hm")), "DaylogOption")
    t.eq(group_at(4, col_of(4, "q=01")), "DaylogOption")
    t.eq(group_at(5, 1), "DaylogHeader")
    t.eq(group_at(5, col_of(5, "#a")), "DaylogTag")
    t.eq(group_at(5, col_of(5, "@b")), "DaylogLocation")
    t.eq(group_at(5, col_of(5, "q=5")), "DaylogOption")
    t.eq(group_at(5, col_of(5, "d=hm")), "DaylogOption")

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
      t.eq(group_at(lnum, 1), "DaylogBlockHeader")
      t.ok(
        group_at(lnum, col_of(lnum, token)) ~= "DaylogOption",
        string.format("%q on line %d must not highlight as an option", token, lnum)
      )
    end
  end)

  t.test("a line with an invalid timestamp does not highlight trailing metadata", function()
    load({
      "25:00 task #tag", -- out-of-range time: not an entry for the parser
      "12:34xyz #tag", -- time glued to text: not an entry either
    })

    -- The whole line is a free-form note, so the trailing #tag is not metadata.
    t.ok(group_at(1, 1) ~= "DaylogTimestamp", "25:00 is not a timestamp")
    t.ok(
      group_at(1, col_of(1, "#tag")) ~= "DaylogTag",
      "#tag on an invalid entry must not highlight"
    )
    t.ok(
      group_at(2, col_of(2, "#tag")) ~= "DaylogTag",
      "#tag after a glued time must not highlight"
    )
  end)

  t.test("a summary-shaped line outside a summary section reads as a note", function()
    -- Without a generated summary section above them, these lines are ambiguous with
    -- notes (the parser classifies them as notes), so they are highlighted as notes
    -- -- a comment can never masquerade as a real summary row. They only highlight as
    -- durations inside a section (see the block-context test below).
    load({
      "0:30 (+4m) planning",
      "16:00 (-20m) workday",
      "1:30 planning",
      "08:00 planning",
    })

    -- A duration/(+Nm)-shaped line, with no section, is a plain note.
    t.eq(group_at(1, 1), "DaylogNote")
    t.ok(
      group_at(1, col_of(1, "(+4m)")) ~= "DaylogQuantError",
      "(+4m) inside a note is not a rounding marker"
    )
    t.eq(group_at(2, 1), "DaylogNote")
    t.eq(group_at(3, 1), "DaylogNote")

    -- A zero-padded HH:MM entry still reads as a timestamp.
    t.eq(group_at(4, 1), "DaylogTimestamp")
  end)

  t.test("a summary-shaped note below the summary stays a note", function()
    load({
      "--- log #A ---",
      "08:00 a #A",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) a",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
      "",
      "3.00h (+0m) billed to client X",
    })

    -- The real summary and totals rows (inside their sections) are durations.
    t.eq(group_at(6, 1), "DaylogDuration")
    t.eq(group_at(9, 1), "DaylogDuration")

    -- The trailing comment, after the summary, is a note despite its shape, so it
    -- can't be mistaken for a real summary item.
    t.eq(group_at(11, 1), "DaylogNote")
    t.ok(
      group_at(11, col_of(11, "(+0m)")) ~= "DaylogQuantError",
      "the comment's (+0m) is not a rounding marker"
    )
  end)

  t.test("two-digit-hour hhmm summary rows highlight as durations via block context", function()
    load({
      "--- log d=hm ---",
      "08:00 deep work",
      "",
      "--- summary q=15 d=dec ---",
      "16:00 deep work #ClientA",
      "2:00 admin",
      "",
      "--- totals ---",
      "16:00 workday",
    })

    -- An entry in the log body still reads as a timestamp.
    t.eq(group_at(2, 1), "DaylogTimestamp")

    -- Generated section headers stay block headers.
    t.eq(group_at(4, 1), "DaylogBlockHeader")
    t.eq(group_at(8, 1), "DaylogBlockHeader")

    -- Inside a summary section a two-digit-hour hhmm row is a duration, not a
    -- timestamp -- the case the line matches alone cannot resolve.
    t.eq(group_at(5, 1), "DaylogDuration")
    t.eq(group_at(9, 1), "DaylogDuration")

    -- Single-digit-hour rows and trailing metadata still highlight inside it.
    t.eq(group_at(6, 1), "DaylogDuration")
    t.eq(group_at(5, col_of(5, "#ClientA")), "DaylogTag")
  end)

  t.test("a labeled multi-day report section highlights its rows", function()
    -- :DaylogWeek / :DaylogDays produce labeled headers the old syntax file did
    -- not recognize; the parser-driven highlighter does, so report rows highlight.
    load({
      "--- day summary 2026-05-18 q=30 ---",
      "2.00h (+0m) planning #ClientA",
      "",
      "--- day totals 2026-05-18 ---",
      "8.00h (+0m) workday",
      "",
      "--- week summary 2026-W21 ---",
      "16:00 (+0m) workday",
    })

    -- Labeled report headers are block headers.
    t.eq(group_at(1, 1), "DaylogBlockHeader")
    t.eq(group_at(4, 1), "DaylogBlockHeader")
    t.eq(group_at(7, 1), "DaylogBlockHeader")

    -- Their rows are summary durations with rounding markers and trailing metadata.
    t.eq(group_at(2, 1), "DaylogDuration")
    t.eq(group_at(2, col_of(2, "(+0m)")), "DaylogQuantError")
    t.eq(group_at(2, col_of(2, "#ClientA")), "DaylogTag")
    t.eq(group_at(5, 1), "DaylogDuration")
    t.eq(group_at(8, 1), "DaylogDuration")
  end)

  t.test("utc offset tokens highlight as a muted offset group", function()
    load({
      "--- log @office utc+2 ---",
      "11:00 resume utc-4",
      "12:00 talk utc-x",
    })

    -- On the header and in an entry's trailing run, a valid utc token is its own
    -- muted group, distinct from tag/location.
    t.eq(group_at(1, col_of(1, "utc+2")), "DaylogOffset")
    t.eq(group_at(2, col_of(2, "utc-4")), "DaylogOffset")

    -- A malformed utc token is plain activity text, never an offset (it fails the
    -- same parse the reader uses).
    t.ok(
      group_at(3, col_of(3, "utc-x")) ~= "DaylogOffset",
      "a malformed utc token must not highlight as an offset"
    )
  end)

  t.test("a round nudge highlights distinctly and keeps the trailing run intact", function()
    load({
      "--- log #ClientA q=15 ---",
      "08:00 plan #ClientA round+1 !L",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (-10m) plan round+1",
      "",
      "--- totals ---",
      "1.00h (-10m) workday round+1",
    })

    -- The marker is its own group on an entry, and -- crucially -- it does not break
    -- the highlighting of the #tag and !L on either side of it in the trailing run.
    t.eq(group_at(2, col_of(2, "round+1")), "DaylogNudge")
    t.eq(group_at(2, col_of(2, "#ClientA")), "DaylogTag")
    t.eq(group_at(2, col_of(2, "!L")), "DaylogLogged")

    -- It also highlights where it is propagated onto summary rows and the total.
    t.eq(group_at(5, col_of(5, "round+1")), "DaylogNudge")
    t.eq(group_at(8, col_of(8, "round+1")), "DaylogNudge")

    -- The metadata groups are bright, not muted: none links to Comment.
    t.ok(highlight.GROUPS.DaylogNudge ~= "Comment", "nudge must not be a comment")
    t.ok(highlight.GROUPS.DaylogOffset ~= "Comment", "utc offset must not be a comment")
    t.ok(highlight.GROUPS.DaylogTag ~= "Comment", "tag must not be a comment")
    t.ok(highlight.GROUPS.DaylogLocation ~= "Comment", "location must not be a comment")

    -- A bare 'round' word in activity text is not a nudge.
    load({ "08:00 wrap up the round" })
    t.ok(group_at(1, col_of(1, "round")) ~= "DaylogNudge", "a bare 'round' is not a nudge")
  end)

  t.test("an aliased entry highlights the => label and its trailing metadata", function()
    load({ "--- log ---", "09:00 fix login => BUG-123 Login #ClientA !L30" })

    -- The => label is the alias; the metadata after it still classifies as metadata.
    t.eq(group_at(2, col_of(2, "=>")), "DaylogAlias")
    t.eq(group_at(2, col_of(2, "BUG-123")), "DaylogAlias")
    t.eq(group_at(2, col_of(2, "#ClientA")), "DaylogTag")
    t.eq(group_at(2, col_of(2, "!L30")), "DaylogLogged")

    -- The description before the arrow is not part of the alias.
    t.ok(group_at(2, col_of(2, "fix")) ~= "DaylogAlias", "the description is not the alias")
  end)
end
