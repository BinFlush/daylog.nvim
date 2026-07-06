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
          lines = { "", "", "--- log #ClientA @office q=30 d=hm ---" },
        },
      },
      cursor = { 4, 0 },
    })
  end)

  t.test("new_log tops the separator up to the canonical two blanks", function()
    -- One trailing blank already there -> add one; two already there -> add none.
    t.eq(new_log.run({ "notes", "" }, { tag = "ClientA" }), {
      edits = {
        {
          start_index = 2,
          end_index = 2,
          lines = { "", "--- log #ClientA ---" },
        },
      },
      cursor = { 4, 0 },
    })
    t.eq(new_log.run({ "notes", "", "" }, { tag = "ClientA" }).edits[1].lines, {
      "--- log #ClientA ---",
    })
  end)

  t.test("copy and new leave a canonical seam the next refresh does not rewrite", function()
    local refresh_summaries = require("daylog.usecases.refresh_summaries")
    local base = { "--- log q=15 ---", "08:00 a", "09:00 done" }
    local buf = support.apply_edits(base, refresh_summaries.run(base).edits)

    -- :Daylog copy appends a fully canonical log+summary: zero refresh churn.
    local copied = append_copy.run(buf, 1)
    local after_copy = support.apply_edits(buf, copied.edits)
    t.eq(#refresh_summaries.run(after_copy).edits, 0)
    t.eq(after_copy[copied.cursor[1]], "--- log q=15 ---") -- the cursor lands on the new header

    -- :Daylog new appends header-after-two-blanks; the only refresh edit is creating the
    -- new (empty) log's summary, never a rewrite of the previous zone's seam.
    local created = new_log.run(buf, {})
    local after_new = support.apply_edits(buf, created.edits)
    t.eq(after_new[#buf + 1], "")
    t.eq(after_new[#buf + 2], "")
    t.eq(after_new[#buf + 3], "--- log ---")
    for _, edit in ipairs(refresh_summaries.run(after_new).edits) do
      t.ok(edit.start_index >= #buf + 2, "no refresh edit touches the previous zone")
    end
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
            "2.00h (+0m) workday",
          },
        },
      },
      cursor = { 7, 0 },
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
      cursor = { 8, 0 },
    })
  end)

  t.test("append_copy preserves !S and canonicalizes it after metadata", function()
    local result = append_copy.run({
      "--- log #ClientA @office ---",
      "08:00 plan !S @client",
      "09:00 done",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = {
            "",
            "",
            "--- log #ClientA @office ---",
            "08:00 plan @client !S",
            "09:00 done",
            "",
            "",
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) plan !S",
            "",
            "--- tags ---",
            "1.00h (+0m) #ClientA",
            "",
            "--- locations ---",
            "1.00h (+0m) @client",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
      },
      cursor = { 6, 0 },
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
      cursor = { 6, 0 },
    })
  end)

  t.test("append_copy moves the cursor onto the new log header", function()
    local input = { "--- log ---", "08:00 plan", "09:00 done" }
    local result = append_copy.run(input)

    -- The cursor lands on the copy's header, after the two separator blanks.
    local offset = result.cursor[1] - #input
    t.eq(offset, 3)
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

  t.test("repeat_current usecase does not propagate !S", function()
    local result = repeat_current.run({
      "--- log #ClientA @office ---",
      "08:00 planning !S",
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
    -- The cross-day :Daylog repeat path uses entry_at_row; a cursor on a summary
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

  t.test("order_logs usecase preserves !S", function()
    local result = order_logs.run({
      "--- log #sales ---",
      "09:00 done",
      "08:00 plan !S",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 1,
          end_index = 3,
          lines = {
            "08:00 plan !S",
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
          start_index = 3,
          end_index = 6,
          lines = {
            "",
            "",
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) implementation !S",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 implementation !S60" },
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
          start_index = 3,
          end_index = 6,
          lines = {
            "",
            "",
            "--- summary q=30 d=dec ---",
            "1.00h (+0m) implementation !S",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 implementation !S60" },
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
          start_index = 5,
          end_index = 9,
          lines = {
            "",
            "",
            "--- summary q=15 d=dec ---",
            "2.00h (+0m) implementation !S",
            "1.00h (+0m) meeting",
            "",
            "--- totals ---",
            "3.00h (+0m) workday",
          },
        },
        {
          start_index = 3,
          end_index = 4,
          lines = { "10:00 implementation !S120" },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 implementation !S120" },
        },
      },
    })
  end)

  t.test("log never marks a blank entry, at any level (it inherits sticky tag/location)", function()
    -- A blank entry inherits the header's @home / #Proj, so a naive tag/location group would sweep it
    -- in and stamp a marker on it -- which then trips the blank_entry_metadata diagnostic. Logging any
    -- of the four rows must leave the blank (10:00) untouched and produce no diagnostics.
    local refresh_summaries = require("daylog.usecases.refresh_summaries")
    local analyze = require("daylog.analyze")
    local document = require("daylog.document")
    local base =
      { "--- log @home #Proj q=15 ---", "08:00 work", "10:00", "11:00 more", "12:00 done" }
    local rendered = support.apply_edits(base, refresh_summaries.run(base).edits)

    local function log_row(needle)
      local row
      for i, line in ipairs(rendered) do
        if line:find(needle, 1, true) then
          row = i
        end
      end
      local result = log_current.run(rendered, row)
      local applied = support.apply_edits(rendered, result.edits)
      local blank_marked = false
      for _, line in ipairs(applied) do
        if line:match("^10:00%s*!") then
          blank_marked = true
        end
      end
      return blank_marked, #analyze.analyze(document.parse(applied)).diagnostics
    end

    for _, needle in ipairs({ "@home", "#Proj", "workday", ") work" }) do
      local blank_marked, diagnostics = log_row(needle)
      t.eq(blank_marked, false)
      t.eq(diagnostics, 0)
    end
  end)

  t.test("log on a committed cell's drift remainder names the real remedy", function()
    -- The cell is fully marked (!S60) but its real time grew to 67m; the 15m remainder row
    -- has no unlogged source entries, so logging it must explain itself -- "regenerate the
    -- summary" (the stale message) reproduces the very same row.
    local refresh_summaries = require("daylog.usecases.refresh_summaries")
    local base = { "--- log ---", "00:00 logged item !S60", "01:07 other task", "01:09 done" }
    local buf = support.apply_edits(base, refresh_summaries.run(base).edits)
    local row
    for i, line in ipairs(buf) do
      if line:find(") logged item", 1, true) and not line:find("!S", 1, true) then
        row = i
      end
    end

    local _, err = log_current.run(buf, row)
    t.ok(err:find("unlog the !S row", 1, true) ~= nil, err)
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
          start_index = 4,
          end_index = 7,
          lines = {
            "",
            "",
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) implementation !S",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 implementation !S60" },
        },
      },
    })
  end)

  t.test("log_current canonicalizes metadata order around the appended !S", function()
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
          start_index = 3,
          end_index = 6,
          lines = {
            "",
            "",
            "--- summary q=15 d=dec ---",
            "1.00h (+0m) plan !S",
            "",
            "--- tags ---",
            "1.00h (+0m) #ClientA",
            "",
            "--- locations ---",
            "1.00h (+0m) @office",
            "",
            "--- totals ---",
            "1.00h (+0m) workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 plan #ClientA @office !S60" },
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
    t.eq(err, "daylog: put the cursor on a summary, tag, location, or workday row to log it")
  end)

  t.test("log_current logs a tag-total row at the tag level", function()
    local result = log_current.run({
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

    t.ok(result ~= nil, "a tag total row is loggable")
    local marked = false
    for _, edit in ipairs(result.edits) do
      for _, line in ipairs(edit.lines) do
        if line:find("!T60", 1, true) then
          marked = true
        end
      end
    end
    t.ok(marked, "the tag's contributing entry is frozen at !T60")
  end)

  t.test("log_current unmarks a logged tag row", function()
    local result = log_current.run({
      "--- log #ClientA ---",
      "08:00 implementation !T60",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
      "",
      "--- tags ---",
      "1.00h (+0m) #ClientA !T",
    }, 9)

    t.ok(result ~= nil, "a logged tag row is loggable")
    local still_marked = false
    for _, edit in ipairs(result.edits) do
      for _, line in ipairs(edit.lines) do
        if line:match("^%d%d:%d%d") and line:find("!T") then
          still_marked = true
        end
      end
    end
    t.ok(not still_marked, "the tag marker is removed from the entry")
  end)

  t.test("log_current logs a location-total row at the location level", function()
    local result = log_current.run({
      "--- log @office ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
      "",
      "--- locations ---",
      "1.00h (+0m) @office",
    }, 9)

    t.ok(result ~= nil, "a location total row is loggable")
    local marked = false
    for _, edit in ipairs(result.edits) do
      for _, line in ipairs(edit.lines) do
        if line:find("!L60", 1, true) then
          marked = true
        end
      end
    end
    t.ok(marked, "the location's contributing entry is frozen at !L60")
  end)

  t.test("log_current logs the workday total row at the workday level", function()
    local result = log_current.run({
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

    t.ok(result ~= nil, "the workday total row is loggable")
    local marked = false
    for _, edit in ipairs(result.edits) do
      for _, line in ipairs(edit.lines) do
        if line:find("!W60", 1, true) then
          marked = true
        end
      end
    end
    t.ok(marked, "every non-#ooo entry is frozen at !W60")
  end)

  t.test("log_current unmarks a logged workday total row", function()
    local result = log_current.run({
      "--- log ---",
      "08:00 implementation !W60",
      "09:00 done !W60",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
      "",
      "--- totals ---",
      "1.00h (+0m) workday !W",
    }, 9)

    t.ok(result ~= nil, "a logged workday total row is loggable")
    local still_marked = false
    for _, edit in ipairs(result.edits) do
      for _, line in ipairs(edit.lines) do
        if line:match("^%d%d:%d%d") and line:find("!W") then
          still_marked = true
        end
      end
    end
    t.ok(not still_marked, "the workday marker is removed from every entry")
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
      "08:00 implementation !S",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation !S",
    }, 6)

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 6,
          lines = {
            "",
            "",
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
    t.eq(err, "daylog: unordered timestamps near lines 2 and 3; fix manually or run :Daylog order")
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
      t.eq(err, "daylog: put the cursor on a summary, tag, location, or workday row to log it")
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
    t.eq(err, "daylog: put the cursor on a summary, tag, location, or workday row to log it")
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
    t.eq(err, "daylog: put the cursor on a summary, tag, location, or workday row to log it")
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
    -- first line is not a log header. This proves :Daylog log cannot be
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
            start_index = 4,
            end_index = 17,
            lines = {
              "",
              "",
              "--- summary q=15 d=dec ---",
              "2.00h (+0m) planning !S",
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
            },
          },
          {
            start_index = 1,
            end_index = 2,
            lines = { "08:00 planning !S120" },
          },
        },
      })
    end
  )

  t.test(
    "log_current regression: quantized summary group with note line and partial logging",
    function()
      -- Reported bug: :Daylog log updated the source entry but left the
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
            start_index = 8,
            end_index = 23,
            lines = {
              "",
              "",
              "--- summary q=15 d=dec ---",
              "2.00h (-8m) versions",
              "0.75h (-1m) Q1 features !S",
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
            },
          },
          {
            start_index = 6,
            end_index = 7,
            lines = { "10:17 Q1 features !S45" },
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
        "10:17 Q1 features !S45",
        "11:01 versions",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "2.00h (-8m) versions",
        "0.75h (-1m) Q1 features !S",
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

  t.test("carryover close_edit refuses an already-closed log", function()
    -- A 24:00 (or blank) final entry means nothing is running; a second close would
    -- duplicate the boundary even if the caller's running-entry gate were bypassed.
    local _, err = carryover.close_edit({ "--- log ---", "08:00 work", "24:00" })
    t.eq(err, "daylog: the log is already closed")
    local _, err2 = carryover.close_edit({ "--- log ---", "08:00 work", "18:00" })
    t.eq(err2, "daylog: the log is already closed")
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
