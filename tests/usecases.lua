return function(t)
  local append_copy = require("daylog.usecases.append_copy")
  local carryover = require("daylog.usecases.carryover")
  local insert_now = require("daylog.usecases.insert_now")
  local log_current = require("daylog.usecases.log_current")
  local new_log = require("daylog.usecases.new_log")
  local order_logs = require("daylog.usecases.order_logs")
  local repeat_current = require("daylog.usecases.repeat_current")
  local support = require("daylog.usecases.support")

  t.test("new_log usecase creates the initial header in an empty buffer", function()
    local result = new_log.run({ "" })

    t.eq(result, {
      edits = {
        {
          start_index = 0,
          end_index = 1,
          lines = { "--- log ---" },
        },
      },
      cursor = { 1, 0 },
    })
  end)

  t.test("new_log usecase appends a header with defaults", function()
    local result = new_log.run({ "notes" }, {
      tag = "ClientA",
      location = "office",
      quantize_minutes = 30,
      duration_format = "hm",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 1,
          end_index = 1,
          lines = { "", "--- log #ClientA @office q=30 d=hm ---" },
        },
      },
      cursor = { 3, 0 },
    })
  end)

  t.test("new_log usecase reuses a trailing blank line when appending", function()
    local result = new_log.run({ "notes", "" }, {
      tag = "ClientA",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 2,
          end_index = 2,
          lines = { "--- log #ClientA ---" },
        },
      },
      cursor = { 3, 0 },
    })
  end)

  t.test("insert_now usecase returns an edit script and cursor action", function()
    local result = insert_now.run({
      "--- log ---",
      "08:00 first",
      "09:00 done",
    }, 1, "08:30")

    t.eq(result, {
      edits = {
        {
          start_index = 2,
          end_index = 2,
          lines = { "08:30 " },
        },
      },
      cursor = { 3, 6 },
      startinsert = true,
    })
  end)

  t.test("insert_now usecase rejects invalid injected current time", function()
    local result, err = insert_now.run({
      "--- log ---",
      "08:00 first",
      "09:00 done",
    }, 1, "25:00")

    t.eq(result, nil)
    t.eq(err, "daylog: invalid current time: invalid time")
  end)

  t.test("insert_now appends a new entry before trailing blank lines", function()
    local result = insert_now.run({
      "--- log ---",
      "08:00 first",
      "09:00 done",
      "",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) first",
    }, 2, "10:00")

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = { "10:00 " },
        },
      },
      cursor = { 4, 6 },
      startinsert = true,
    })
  end)

  t.test("insert_now appends after a trailing note but before blank lines", function()
    local result = insert_now.run({
      "--- log ---",
      "08:00 first",
      "09:00 done",
      "  note about done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) first",
    }, 2, "10:00")

    t.eq(result.edits[1].start_index, 4)
  end)

  t.test("insert_now still appends after the last entry with no trailing gap", function()
    local result = insert_now.run({
      "--- log ---",
      "08:00 first",
      "09:00 done",
    }, 1, "10:00")

    t.eq(result.edits[1].start_index, 3)
  end)

  t.test("append_copy preserves clear tokens needed to keep meaning", function()
    local result = append_copy.run({
      "--- log ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 4,
          end_index = 4,
          lines = {
            "",
            "--- log ---",
            "08:00 break #ooo @home",
            "09:00 resume #- @-",
            "10:00 done",
            "",
            "",
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) break",
            "1.00h (+0m) resume",
            "",
            "--- tags ---",
            "1.00h (+0m) #ooo",
            "1.00h (+0m) (untagged)",
            "",
            "--- locations ---",
            "1.00h (+0m) @home",
            "1.00h (+0m) (no location)",
            "",
            "--- totals ---",
            "2.00h (+0m) activity",
            "1.00h (+0m) workday",
          },
        },
      },
      cursor = { 6, 0 },
    })
  end)

  t.test("append_copy includes a stray --- notes --- section as part of the log body", function()
    -- A header-shaped body note (`--- notes ---`) is demoted to a note line, so it belongs
    -- to the log; the copy includes it rather than splitting the log at it.
    local result = append_copy.run({
      "--- log ---",
      "08:00 plan",
      "10:00 done",
      "--- notes ---",
      "free text",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 5,
          end_index = 5,
          lines = {
            "",
            "--- log ---",
            "08:00 plan",
            "10:00 done",
            "--- notes ---",
            "free text",
            "",
            "",
            "--- summary q=15 d=dec ---",
            "2.00h (+0m) plan",
            "",
            "--- totals ---",
            "2.00h (+0m) workday",
          },
        },
      },
      cursor = { 7, 0 },
    })
  end)

  t.test("append_copy preserves !L and canonicalizes it after metadata", function()
    local result = append_copy.run({
      "--- log #ClientA @office ---",
      "08:00 plan !L @client",
      "09:00 done",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = {
            "",
            "--- log #ClientA @office ---",
            "08:00 plan @client !L",
            "09:00 done",
            "",
            "",
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) plan !L",
            "",
            "--- tags ---",
            "1.00h (+0m) #ClientA",
            "",
            "--- locations ---",
            "1.00h (+0m) @client",
            "",
            "--- logged ---",
            "1.00h (+0m) logged",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
      },
      cursor = { 5, 0 },
    })
  end)

  t.test("append_copy preserves explicit duration format on the header", function()
    local result = append_copy.run({
      "--- log #sales @client d=hm ---",
      "11:00 tea",
      "12:00",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = {
            "",
            "--- log #sales @client d=hm ---",
            "11:00 tea",
            "12:00",
            "",
            "",
            "--- summary q=15 d=hm ---",
            "1:00 (+0m) tea",
            "",
            "--- tags ---",
            "1:00 (+0m) #sales",
            "",
            "--- locations ---",
            "1:00 (+0m) @client",
            "",
            "--- totals ---",
            "1:00 (+0m) workday",
          },
        },
      },
      cursor = { 5, 0 },
    })
  end)

  t.test("append_copy moves the cursor onto the new log header", function()
    local input = { "--- log ---", "08:00 plan", "09:00 done" }
    local result = append_copy.run(input)

    -- The cursor lands on the second appended line -- the copy's header.
    local offset = result.cursor[1] - #input
    t.eq(offset, 2)
    t.ok(result.edits[1].lines[offset]:find("^%-%-%- log"), "the cursor is on the new log header")
  end)

  t.test("repeat_current re-emits the tag change and preserves the following entry", function()
    local result = repeat_current.run({
      "--- log #ClientA @office ---",
      "08:00 planning",
      "10:00 internal meeting #internal",
      "11:00 done",
    }, 2, "10:30")

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 4,
          lines = { "10:30 planning #ClientA", "11:00 done #internal" },
        },
      },
    })
  end)

  t.test("repeat_current re-emits the location change and preserves the following entry", function()
    local result = repeat_current.run({
      "--- log #ClientA @office ---",
      "08:00 planning",
      "10:00 implementation @home",
      "11:00 done",
    }, 2, "10:30")

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 4,
          lines = { "10:30 planning @office", "11:00 done @home" },
        },
      },
    })
  end)

  t.test("repeat_current emits a tag clear and preserves the following entry", function()
    local result = repeat_current.run({
      "--- log @office ---",
      "08:00 planning",
      "10:00 internal meeting #internal",
      "11:00 done",
    }, 2, "10:30")

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 4,
          lines = { "10:30 planning #-", "11:00 done #internal" },
        },
      },
    })
  end)

  t.test("repeat_current emits a location clear and preserves the following entry", function()
    local result = repeat_current.run({
      "--- log #ClientA ---",
      "08:00 planning",
      "10:00 implementation @home",
      "11:00 done",
    }, 2, "10:30")

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 4,
          lines = { "10:30 planning @-", "11:00 done @home" },
        },
      },
    })
  end)

  t.test("repeat_current preserves a rewritten follower's round nudge", function()
    local result = repeat_current.run({
      "--- log @office ---",
      "08:00 planning",
      "10:00 internal meeting #internal",
      "11:00 done round+1",
    }, 2, "10:30")

    -- Inserting "10:30 planning #-" before "11:00 done" rewrites the follower to pin
    -- its inherited #internal; its round+1 balance marker must survive the re-emit.
    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 4,
          lines = { "10:30 planning #-", "11:00 done #internal round+1" },
        },
      },
    })
  end)

  t.test("repeat_current usecase does not propagate !L", function()
    local result = repeat_current.run({
      "--- log #ClientA @office ---",
      "08:00 planning !L",
      "09:00 done",
    }, 2, "08:30")

    t.eq(result, {
      edits = {
        {
          start_index = 2,
          end_index = 2,
          lines = { "08:30 planning" },
        },
      },
    })
  end)

  t.test("repeat_current usecase rejects invalid injected current time", function()
    local result, err = repeat_current.run({
      "--- log ---",
      "08:00 planning",
      "09:00 done",
    }, 2, "25:00")

    t.eq(result, nil)
    t.eq(err, "daylog: invalid current time: invalid time")
  end)

  t.test("repeat_current repeats the activity behind a main summary row", function()
    -- Cursor on the "planning" summary row (line 7) repeats it into the log,
    -- exactly as if the cursor were on its source entry. The sticky location has
    -- since moved to @home, so the replay re-emits @office to preserve meaning.
    local result = repeat_current.run({
      "--- log #ClientA @office ---",
      "08:00 planning",
      "10:00 implementation @home",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) planning",
      "1.00h (+0m) implementation",
      "",
      "--- tags ---",
      "3.00h (+0m) #ClientA",
      "",
      "--- locations ---",
      "2.00h (+0m) @office",
      "1.00h (+0m) @home",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    }, 7, "11:30")

    t.eq(result, {
      edits = {
        {
          start_index = 4,
          end_index = 4,
          lines = { "11:30 planning @office" },
        },
      },
    })
  end)

  t.test("repeat_current repeats the latest source entry behind a summary row", function()
    -- "implementation" is logged at @home then later at @office; repeating the
    -- summary row must replay the latest occurrence (@office), which matches the
    -- sticky location at insert time and so needs no @location token.
    local result = repeat_current.run({
      "--- log ---",
      "08:00 implementation @home",
      "09:00 meeting",
      "10:00 implementation @office",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) implementation",
      "1.00h (+0m) meeting",
      "",
      "--- locations ---",
      "2.00h (+0m) @home",
      "1.00h (+0m) @office",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    }, 8, "11:30")

    t.eq(result, {
      edits = {
        {
          start_index = 5,
          end_index = 5,
          lines = { "11:30 implementation" },
        },
      },
    })
  end)

  t.test("repeat_current refuses a non-main summary row", function()
    local result, err = repeat_current.run({
      "--- log #ClientA @office ---",
      "08:00 planning",
      "10:00 implementation @home",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) planning",
      "1.00h (+0m) implementation",
      "",
      "--- tags ---",
      "3.00h (+0m) #ClientA",
      "",
      "--- locations ---",
      "2.00h (+0m) @office",
      "1.00h (+0m) @home",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    }, 11, "11:30")

    t.eq(result, nil)
    t.eq(err, "daylog: only a main summary row can be repeated")
  end)

  t.test("repeat_current refuses a stale summary row", function()
    -- The region is locatable (the header, the "plan" row and the totals still
    -- match), but the cursor row has drifted from source, so it is refused rather
    -- than repeating the wrong activity.
    local result, err = repeat_current.run({
      "--- log ---",
      "08:00 plan",
      "09:00 build",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "1.00h (+0m) implementation",
      "",
      "--- totals ---",
      "2.00h (+0m) workday",
    }, 8, "11:00")

    t.eq(result, nil)
    t.eq(err, "daylog: summary row does not match the active log; regenerate the summary")
  end)

  t.test("carryover.entry_at_row resolves a main summary row to its source entry", function()
    -- The cross-day :DaylogRepeat path uses entry_at_row; a cursor on a summary
    -- row maps back to the source entry so it works from the summary too.
    local activity = carryover.entry_at_row({
      "--- log #ClientA ---",
      "08:00 planning",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) planning",
      "",
      "--- tags ---",
      "1.00h (+0m) #ClientA",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    }, 6)

    t.eq(activity.text, "planning")
    t.eq(activity.tag, "ClientA")
  end)

  t.test("order_logs sorts an unambiguous out-of-order log", function()
    local result = order_logs.run({
      "--- log #ClientA ---",
      "09:00 review",
      "08:00 setup",
      "10:00 done",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 1,
          end_index = 4,
          lines = {
            "08:00 setup",
            "09:00 review",
            "10:00 done",
          },
        },
      },
    })
  end)

  t.test("order_logs sorts and warns about order-dependent metadata", function()
    local result = order_logs.run({
      "--- log #ProjectOrion @office ---",
      "08:30 later",
      "08:00 earlier #sales @client",
      "09:00 done #ProjectOrion @office",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 1,
          end_index = 4,
          lines = {
            "08:00 earlier #sales @client",
            "08:30 later #ProjectOrion @office",
            "09:00 done",
          },
        },
      },
      warnings = { "08:30 later" },
    })
  end)

  t.test("order_logs sorts, emitting a tag clear, and warns", function()
    local result = order_logs.run({
      "--- log ---",
      "09:00 done",
      "08:00 plan #sales",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 1,
          end_index = 3,
          lines = {
            "08:00 plan #sales",
            "09:00 done #-",
          },
        },
      },
      warnings = { "09:00 done" },
    })
  end)

  t.test("order_logs usecase preserves !L", function()
    local result = order_logs.run({
      "--- log #sales ---",
      "09:00 done",
      "08:00 plan !L",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 1,
          end_index = 3,
          lines = {
            "08:00 plan !L",
            "09:00 done",
          },
        },
      },
    })
  end)

  t.test("order_logs sorts, emitting a location clear, and warns", function()
    local result = order_logs.run({
      "--- log #sales ---",
      "09:00 done",
      "08:00 plan @client",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 1,
          end_index = 3,
          lines = {
            "08:00 plan @client",
            "09:00 done @-",
          },
        },
      },
      warnings = { "09:00 done" },
    })
  end)

  t.test("log_current marks the source entry behind an unrounded summary row", function()
    local result = log_current.run({
      "--- log ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
    }, 6)

    t.eq(result, {
      edits = {
        {
          start_index = 4,
          end_index = 6,
          lines = {
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) implementation !L",
            "",
            "--- logged ---",
            "1.00h (+0m) logged",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 implementation !L60" },
        },
      },
    })
  end)

  t.test("log_current marks the source entry behind a quantized summary row", function()
    local result = log_current.run({
      "--- log q=30 ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=30 d=dec ---",
      "1.00h (+0m) implementation",
    }, 6)

    t.eq(result, {
      edits = {
        {
          start_index = 4,
          end_index = 6,
          lines = {
            "--- summary q=30 d=dec ---",
            "1.00h (+0m) implementation !L",
            "",
            "--- logged ---",
            "1.00h (+0m) logged",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 implementation !L60" },
        },
      },
    })
  end)

  t.test("log_current marks every source entry contributing to one summary row", function()
    local result = log_current.run({
      "--- log ---",
      "08:00 implementation",
      "09:00 meeting",
      "10:00 implementation",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) implementation",
      "1.00h (+0m) meeting",
    }, 8)

    t.eq(result, {
      edits = {
        {
          start_index = 6,
          end_index = 9,
          lines = {
            "--- summary q=15 d=dec ---",
            "2.00h (+0m) implementation !L",
            "1.00h (+0m) meeting",
            "",
            "--- logged ---",
            "2.00h (+0m) logged",
            "1.00h (+0m) unlogged",
            "",
            "--- totals ---",
            "3.00h (+0m) workday",
          },
        },
        {
          start_index = 3,
          end_index = 4,
          lines = { "10:00 implementation !L120" },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 implementation !L120" },
        },
      },
    })
  end)

  t.test("log_current leaves notes under entries untouched", function()
    local result = log_current.run({
      "--- log ---",
      "08:00 implementation",
      "note text",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
    }, 7)

    t.eq(result, {
      edits = {
        {
          start_index = 5,
          end_index = 7,
          lines = {
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) implementation !L",
            "",
            "--- logged ---",
            "1.00h (+0m) logged",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 implementation !L60" },
        },
      },
    })
  end)

  t.test("log_current canonicalizes metadata order around the appended !L", function()
    local result = log_current.run({
      "--- log ---",
      "08:00 plan #ClientA @office",
      "09:00 done #- @-",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
    }, 6)

    t.eq(result, {
      edits = {
        {
          start_index = 4,
          end_index = 6,
          lines = {
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) plan !L",
            "",
            "--- tags ---",
            "1.00h (+0m) #ClientA",
            "",
            "--- locations ---",
            "1.00h (+0m) @office",
            "",
            "--- logged ---",
            "1.00h (+0m) logged",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 plan #ClientA @office !L60" },
        },
      },
    })
  end)

  t.test("log_current refuses when the cursor is inside the log body", function()
    local result, err = log_current.run({
      "--- log ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
    }, 2)

    t.eq(result, nil)
    t.eq(err, "daylog: summary row does not match the active log; regenerate the summary")
  end)

  t.test("log_current refuses tag-total rows inside the summary block", function()
    local result, err = log_current.run({
      "--- log #ClientA ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
      "",
      "--- tags ---",
      "1.00h (+0m) #ClientA",
    }, 9)

    t.eq(result, nil)
    t.eq(err, "daylog: summary row does not match the active log; regenerate the summary")
  end)

  t.test("log_current refuses total rows", function()
    local result, err = log_current.run({
      "--- log ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    }, 9)

    t.eq(result, nil)
    t.eq(err, "daylog: summary row does not match the active log; regenerate the summary")
  end)

  t.test("log_current refuses the summary section header line", function()
    local result, err = log_current.run({
      "--- log ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
    }, 5)

    t.eq(result, nil)
    t.eq(err, "daylog: summary row does not match the active log; regenerate the summary")
  end)

  t.test("log_current refuses a main row ambiguous with another summary line", function()
    -- An activity literally named "workday" renders a main row byte-identical to the
    -- workday total line; the row is genuinely ambiguous, so it is refused rather than
    -- logged (the shared resolver weighs every selectable row, not only main rows).
    local result, err = log_current.run({
      "--- log ---",
      "08:00 workday",
      "16:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "8.00h (+0m) workday",
      "",
      "--- totals ---",
      "8.00h (+0m) workday",
    }, 6)

    t.eq(result, nil)
    t.eq(err, "daylog: summary row matches multiple rows; regenerate the summary")
  end)

  t.test("log_current unmarks an already logged summary row", function()
    local result = log_current.run({
      "--- log ---",
      "08:00 implementation !L",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation !L",
    }, 6)

    t.eq(result, {
      edits = {
        {
          start_index = 4,
          end_index = 6,
          lines = {
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) implementation",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 implementation" },
        },
      },
    })
  end)

  t.test("log_current refuses #ooo summary rows", function()
    local result, err = log_current.run({
      "--- log ---",
      "08:00 break #ooo",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) break",
    }, 6)

    t.eq(result, nil)
    t.eq(err, "daylog: refusing to mark out-of-office time as logged")
  end)

  t.test("log_current refuses stale summary rows that no longer match the source", function()
    local result, err = log_current.run({
      "--- log ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
    }, 6)

    t.eq(result, nil)
    t.eq(err, "daylog: summary row does not match the active log; regenerate the summary")
  end)

  t.test("log_current refuses when the active log has diagnostics", function()
    local result, err = log_current.run({
      "--- log ---",
      "09:00 done",
      "08:00 plan",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
    }, 6)

    t.eq(result, nil)
    t.eq(err, "daylog: unordered timestamps near lines 2 and 3; fix manually or run :DaylogOrder")
  end)

  t.test(
    "log_current refuses summary blocks owned by a non-active log even when content would match",
    function()
      -- The cursor row's text matches what the active log's recomputed
      -- summary would render, so the content match alone could not save us;
      -- only the ownership check (block.start_row < active.start_row) keeps
      -- the plugin from logging row 9 in the active log.
      local result, err = log_current.run({
        "--- log ---",
        "08:00 implementation",
        "09:00 done",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) implementation",
        "",
        "--- log ---",
        "10:00 implementation",
        "11:00 done",
      }, 6)

      t.eq(result, nil)
      t.eq(err, "daylog: summary row does not match the active log; regenerate the summary")
    end
  )

  t.test("log_current refuses summary-like text in an unrelated generic block", function()
    local result, err = log_current.run({
      "--- log ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- notes ---",
      "1.00h (+0m) implementation",
    }, 6)

    t.eq(result, nil)
    t.eq(err, "daylog: summary row does not match the active log; regenerate the summary")
  end)

  t.test("log_current refuses labeled summary-like headers after the active log", function()
    -- Headers like `--- summary exact 2026-W21 ---` are produced for weekly
    -- and range reports in scratch buffers; if pasted into source they must
    -- not be treated as the active log's summary section.
    local result, err = log_current.run({
      "--- log ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary exact 2026-W21 ---",
      "1.00h (+0m) implementation",
    }, 6)

    t.eq(result, nil)
    t.eq(err, "daylog: summary row does not match the active log; regenerate the summary")
  end)

  t.test("log_current refuses summary-shaped block headers placed before the active log", function()
    local result, err = log_current.run({
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
      "",
      "--- log ---",
      "08:00 implementation",
      "09:00 done",
    }, 2)

    -- The leading block is rejected by the structural parser because the
    -- first line is not a log header. This proves :DaylogLog cannot be
    -- coerced into logging the active log through a pre-active "summary"
    -- block.
    t.eq(result, nil)
    t.eq(
      err,
      "daylog: first line must be a log header such as "
        .. "--- log --- or --- log #ClientA @office q=30 ---"
    )
  end)

  t.test(
    "log_current replaces the full existing summary group including all subsections",
    function()
      -- Buffer already has tags, locations, and totals sections. After logging,
      -- all sections are replaced atomically with the freshly rendered group
      -- that now includes a logged section.
      local result = log_current.run({
        "--- log #ClientA @office ---",
        "08:00 planning",
        "10:00 review",
        "11:00 done",
        "",
        "--- summary q=15 d=dec ---",
        "2.00h (+0m) planning",
        "1.00h (+0m) review",
        "",
        "--- tags ---",
        "3.00h (+0m) #ClientA",
        "",
        "--- locations ---",
        "3.00h (+0m) @office",
        "",
        "--- totals ---",
        "3.00h (+0m) workday",
      }, 7)

      t.eq(result, {
        edits = {
          {
            start_index = 5,
            end_index = 17,
            lines = {
              "--- summary q=15 d=dec ---",
              "2.00h (+0m) planning !L",
              "1.00h (+0m) review",
              "",
              "--- tags ---",
              "3.00h (+0m) #ClientA",
              "",
              "--- locations ---",
              "3.00h (+0m) @office",
              "",
              "--- logged ---",
              "2.00h (+0m) logged",
              "1.00h (+0m) unlogged",
              "",
              "--- totals ---",
              "3.00h (+0m) workday",
            },
          },
          {
            start_index = 1,
            end_index = 2,
            lines = { "08:00 planning !L120" },
          },
        },
      })
    end
  )

  t.test(
    "log_current regression: quantized summary group with note line and partial logging",
    function()
      -- Reported bug: :DaylogLog updated the source entry but left the
      -- rendered summary stale. After the fix the full group — including the
      -- newly required logged section — is replaced in one atomic edit.
      local lines = {
        "--- log #someproject @office ---",
        "08:00 versions",
        "09:00 stand",
        "09:20 versions",
        "10:12 folksy",
        "    what is he talking about    ",
        "10:17 Q1 features",
        "11:01 versions",
        "",
        "--- summary q=15 d=dec ---",
        "2.00h (-8m) versions",
        "0.75h (-1m) Q1 features",
        "0.25h (+5m) stand",
        "0.00h (+5m) folksy",
        "",
        "--- tags ---",
        "3.00h (+1m) #someproject",
        "",
        "--- locations ---",
        "3.00h (+1m) @office",
        "",
        "--- totals ---",
        "3.00h (+1m) workday",
      }

      local result = log_current.run(lines, 12)

      t.eq(result, {
        edits = {
          {
            start_index = 9,
            end_index = 23,
            lines = {
              "--- summary q=15 d=dec ---",
              "2.00h (-8m) versions",
              "0.75h (-1m) Q1 features !L",
              "0.25h (+5m) stand",
              "0.00h (+5m) folksy",
              "",
              "--- tags ---",
              "3.00h (+1m) #someproject",
              "",
              "--- locations ---",
              "3.00h (+1m) @office",
              "",
              "--- logged ---",
              "0.75h (-1m) logged",
              "2.25h (+2m) unlogged",
              "",
              "--- totals ---",
              "3.00h (+1m) workday",
            },
          },
          {
            start_index = 6,
            end_index = 7,
            lines = { "10:17 Q1 features !L45" },
          },
        },
      })

      -- Verify applying the edits in order produces the fully consistent buffer.
      local buf = {}
      for i, line in ipairs(lines) do
        buf[i] = line
      end

      for _, edit in ipairs(result.edits) do
        local new_buf = {}
        for i = 1, edit.start_index do
          new_buf[#new_buf + 1] = buf[i]
        end
        for _, line in ipairs(edit.lines) do
          new_buf[#new_buf + 1] = line
        end
        for i = edit.end_index + 1, #buf do
          new_buf[#new_buf + 1] = buf[i]
        end
        buf = new_buf
      end

      t.eq(buf, {
        "--- log #someproject @office ---",
        "08:00 versions",
        "09:00 stand",
        "09:20 versions",
        "10:12 folksy",
        "    what is he talking about    ",
        "10:17 Q1 features !L45",
        "11:01 versions",
        "",
        "--- summary q=15 d=dec ---",
        "2.00h (-8m) versions",
        "0.75h (-1m) Q1 features !L",
        "0.25h (+5m) stand",
        "0.00h (+5m) folksy",
        "",
        "--- tags ---",
        "3.00h (+1m) #someproject",
        "",
        "--- locations ---",
        "3.00h (+1m) @office",
        "",
        "--- logged ---",
        "0.75h (-1m) logged",
        "2.25h (+2m) unlogged",
        "",
        "--- totals ---",
        "3.00h (+1m) workday",
      })
    end
  )

  t.test("carryover last_running_entry returns the final running activity", function()
    local activity = carryover.last_running_entry({
      "--- log #ClientA @office ---",
      "08:00 planning",
      "22:30 writing report #internal @home",
    })

    t.eq(activity, {
      text = "writing report",
      explicit_tag = "internal",
      explicit_tag_clear = nil,
      explicit_location = "home",
      explicit_location_clear = nil,
      tag = "internal",
      location = "home",
      workday_excluded = false,
    })
  end)

  t.test("carryover last_running_entry is nil when the day already closed", function()
    t.eq(
      carryover.last_running_entry({
        "--- log #ClientA @office ---",
        "08:00 planning",
        "17:00",
      }),
      nil
    )
  end)

  t.test(
    "carryover last_running_entry is nil when the final entry is the 24:00 boundary",
    function()
      t.eq(
        carryover.last_running_entry({
          "--- log #ClientA @office ---",
          "08:00 planning",
          "24:00 wrapping up",
        }),
        nil
      )
    end
  )

  t.test("carryover entry_at_row returns the activity on the cursor row", function()
    local activity = carryover.entry_at_row({
      "--- log #ClientA @office ---",
      "08:00 planning",
      "10:00 review #internal",
    }, 2)

    t.eq(activity, {
      text = "planning",
      explicit_tag = nil,
      explicit_tag_clear = nil,
      explicit_location = nil,
      explicit_location_clear = nil,
      tag = "ClientA",
      location = "office",
      workday_excluded = false,
    })
  end)

  t.test("carryover seed_edit continues the activity at 00:00", function()
    local activity = carryover.last_running_entry({
      "--- log #ClientA @office ---",
      "22:30 writing report #internal",
    })

    local result = carryover.seed_edit({
      "--- log #ClientA @office ---",
    }, activity, 0)

    t.eq(result, {
      edits = {
        {
          start_index = 1,
          end_index = 1,
          lines = { "00:00 writing report #internal" },
        },
      },
    })
  end)

  t.test("carryover close_edit appends a bare 24:00 boundary", function()
    local result = carryover.close_edit({
      "--- log #ClientA @office ---",
      "08:00 planning",
      "22:30 writing report",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = { "24:00" },
        },
      },
    })
  end)

  t.test("new_log usecase stamps a base utc offset from defaults", function()
    local result = new_log.run({ "" }, { utc = 120 })
    t.eq(result.edits[1].lines, { "--- log utc+2 ---" })
  end)

  t.test("repeat_current carries the source entry's utc offset", function()
    -- Repeat the utc-4 entry at 09:00, which sits in the utc+2 stretch, so the
    -- carried offset re-emits as utc-4 on the new line.
    local result = repeat_current.run({
      "--- log utc+2 ---",
      "08:00 standup",
      "11:00 deploy utc-4",
      "12:00 done",
    }, 3, "09:00")

    t.eq(result, {
      edits = {
        {
          start_index = 2,
          end_index = 2,
          lines = { "09:00 deploy utc-4" },
        },
      },
    })
  end)

  t.test("repeat_current pins a following entry's offset when the insert changes it", function()
    -- Repeating the utc-4 trip at 08:30 (inside the utc+2 stretch) would otherwise
    -- make the following 09:00 sync silently inherit utc-4; the follower is pinned
    -- back to utc+2 so its effective offset is preserved.
    local result = repeat_current.run({
      "--- log utc+2 ---",
      "08:00 standup",
      "09:00 sync",
      "14:00 trip utc-4",
    }, 4, "08:30")

    t.eq(result, {
      edits = {
        {
          start_index = 2,
          end_index = 3,
          lines = { "08:30 trip utc-4", "09:00 sync utc+2" },
        },
      },
    })
  end)

  t.test("carryover continues an activity with its utc offset across midnight", function()
    local activity = carryover.last_running_entry({
      "--- log utc-4 ---",
      "22:30 writing report",
    })
    t.eq(activity.offset, -240)

    -- Seeded into a fresh next-day log with no base, the carried offset re-emits.
    local result = carryover.seed_edit({ "--- log ---" }, activity, 0)
    t.eq(result, {
      edits = {
        {
          start_index = 1,
          end_index = 1,
          lines = { "00:00 writing report utc-4" },
        },
      },
    })
  end)

  t.test("support.apply_edits applies highest-first edits off-buffer", function()
    -- Two disjoint replace edits (0-based), sorted highest-start-first: the higher edit
    -- grows the line count and, applied first, leaves the lower edit's indexes valid --
    -- the pure mirror of how the shell's nvim_buf_set_lines apply behaves.
    local lines = { "a", "b", "c", "d" }
    local edits = {
      { start_index = 3, end_index = 4, lines = { "D1", "D2" } },
      { start_index = 0, end_index = 1, lines = {} },
    }

    t.eq(support.apply_edits(lines, edits), { "b", "c", "D1", "D2" })
  end)
end
