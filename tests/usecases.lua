return function(t)
  local append_copy = require("worklog.usecases.append_copy")
  local append_quantized_summary = require("worklog.usecases.append_quantized_summary")
  local append_summary = require("worklog.usecases.append_summary")
  local check = require("worklog.usecases.check")
  local insert_now = require("worklog.usecases.insert_now")
  local log_current = require("worklog.usecases.log_current")
  local new_worklog = require("worklog.usecases.new_worklog")
  local order_worklogs = require("worklog.usecases.order_worklogs")
  local repeat_current = require("worklog.usecases.repeat_current")
  local INVALID_FIRST_HEADER_MESSAGE = "worklog: first line must be a worklog header such as "
    .. "--- worklog --- or --- worklog #ClientA @office quantize=30 ---"

  t.test("new_worklog usecase creates the initial header in an empty buffer", function()
    local result = new_worklog.run({ "" })

    t.eq(result, {
      edits = {
        {
          start_index = 0,
          end_index = 1,
          lines = { "--- worklog ---" },
        },
      },
      cursor = { 1, 0 },
    })
  end)

  t.test("new_worklog usecase appends a header with defaults", function()
    local result = new_worklog.run({ "notes" }, {
      tag = "ClientA",
      location = "office",
      quantize_minutes = 30,
      duration_format = "hhmm",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 1,
          end_index = 1,
          lines = { "", "--- worklog #ClientA @office quantize=30 duration=hhmm ---" },
        },
      },
      cursor = { 3, 0 },
    })
  end)

  t.test("new_worklog usecase reuses a trailing blank line when appending", function()
    local result = new_worklog.run({ "notes", "" }, {
      tag = "ClientA",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 2,
          end_index = 2,
          lines = { "--- worklog #ClientA ---" },
        },
      },
      cursor = { 3, 0 },
    })
  end)

  t.test("insert_now usecase returns an edit script and cursor action", function()
    local result = insert_now.run({
      "--- worklog ---",
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
      "--- worklog ---",
      "08:00 first",
      "09:00 done",
    }, 1, "25:00")

    t.eq(result, nil)
    t.eq(err, "worklog: invalid current time: invalid time")
  end)

  t.test("append_summary usecase returns appended summary lines", function()
    local result = append_summary.run({
      "--- worklog @office ---",
      "08:00 plan",
      "08:30 call #sales @client",
      "09:00 done",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 4,
          end_index = 4,
          lines = {
            "",
            "--- summary exact ---",
            "0.50h plan",
            "0.50h call",
            "",
            "--- tags exact ---",
            "0.50h (untagged)",
            "0.50h #sales",
            "",
            "--- locations exact ---",
            "0.50h @office",
            "0.50h @client",
            "",
            "--- totals exact ---",
            "1.00h workday",
          },
        },
      },
    })
  end)

  t.test("append_summary omits placeholder-only metadata sections and activity total", function()
    local result = append_summary.run({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = {
            "",
            "--- summary exact ---",
            "1.00h plan",
            "",
            "--- totals exact ---",
            "1.00h workday",
          },
        },
      },
    })
  end)

  t.test("append_summary uses the worklog duration format", function()
    local result = append_summary.run({
      "--- worklog duration=hhmm ---",
      "08:00 plan",
      "09:30 done",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = {
            "",
            "--- summary exact ---",
            "1:30 plan",
            "",
            "--- totals exact ---",
            "1:30 workday",
          },
        },
      },
    })
  end)

  t.test("append_quantized_summary uses the worklog duration format", function()
    local result = append_quantized_summary.run({
      "--- worklog quantize=30 duration=hhmm ---",
      "08:00 plan",
      "08:34 done",
    })

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = {
            "",
            "--- summary quantized ---",
            "0:30 (+4m) plan",
            "",
            "--- totals quantized ---",
            "0:30 (+4m) workday",
          },
        },
      },
    })
  end)

  t.test("check usecase returns ok for a valid worklog", function()
    local result = check.run({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
    })

    t.eq(result, {
      message = "worklog: ok",
    })
  end)

  t.test("check usecase returns the structural error first", function()
    local result, err = check.run({
      "--- summary exact ---",
      "1.00h workday",
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
    })

    t.eq(result, nil)
    t.eq(err, INVALID_FIRST_HEADER_MESSAGE)
  end)

  t.test("check usecase returns invalid entry errors", function()
    local result, err = check.run({
      "--- worklog ---",
      "08:00 plan #sales #meeting",
      "09:00 done",
    })

    t.eq(result, nil)
    t.eq(err, "worklog: invalid worklog entry at line 2: multiple trailing tags are not allowed")
  end)

  t.test("check usecase returns unordered timestamp errors", function()
    local result, err = check.run({
      "--- worklog ---",
      "09:00 later",
      "08:00 earlier",
      "10:00 done",
    })

    t.eq(result, nil)
    t.eq(err, "worklog: unordered timestamps near lines 2 and 3; fix manually or run :WorklogOrder")
  end)

  t.test("append_copy preserves clear tokens needed to keep meaning", function()
    local result = append_copy.run({
      "--- worklog ---",
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
            "--- worklog ---",
            "08:00 break #ooo @home",
            "09:00 resume #- @-",
            "10:00 done",
          },
        },
      },
    })
  end)

  t.test("append_copy preserves !L and canonicalizes it after metadata", function()
    local result = append_copy.run({
      "--- worklog #ClientA @office ---",
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
            "--- worklog #ClientA @office ---",
            "08:00 plan @client !L",
            "09:00 done",
          },
        },
      },
    })
  end)

  t.test("append_copy preserves explicit duration format on the header", function()
    local result = append_copy.run({
      "--- worklog #sales @client duration=hhmm ---",
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
            "--- worklog #sales @client duration=hhmm ---",
            "11:00 tea",
            "12:00",
          },
        },
      },
    })
  end)

  t.test("repeat_current usecase re-emits only the tag change", function()
    local result = repeat_current.run({
      "--- worklog #ClientA @office ---",
      "08:00 planning",
      "10:00 internal meeting #internal",
      "11:00 done",
    }, 2, "10:30")

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = { "10:30 planning #ClientA" },
        },
      },
    })
  end)

  t.test("repeat_current usecase re-emits only the location change", function()
    local result = repeat_current.run({
      "--- worklog #ClientA @office ---",
      "08:00 planning",
      "10:00 implementation @home",
      "11:00 done",
    }, 2, "10:30")

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = { "10:30 planning @office" },
        },
      },
    })
  end)

  t.test("repeat_current usecase emits a tag clear when needed", function()
    local result = repeat_current.run({
      "--- worklog @office ---",
      "08:00 planning",
      "10:00 internal meeting #internal",
      "11:00 done",
    }, 2, "10:30")

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = { "10:30 planning #-" },
        },
      },
    })
  end)

  t.test("repeat_current usecase emits a location clear when needed", function()
    local result = repeat_current.run({
      "--- worklog #ClientA ---",
      "08:00 planning",
      "10:00 implementation @home",
      "11:00 done",
    }, 2, "10:30")

    t.eq(result, {
      edits = {
        {
          start_index = 3,
          end_index = 3,
          lines = { "10:30 planning @-" },
        },
      },
    })
  end)

  t.test("repeat_current usecase does not propagate !L", function()
    local result = repeat_current.run({
      "--- worklog #ClientA @office ---",
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
      "--- worklog ---",
      "08:00 planning",
      "09:00 done",
    }, 2, "25:00")

    t.eq(result, nil)
    t.eq(err, "worklog: invalid current time: invalid time")
  end)

  t.test(
    "order_worklogs usecase returns replace edits for representable sticky rewrites",
    function()
      local result = order_worklogs.run({
        "--- worklog #ProjectOrion @office ---",
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
      })
    end
  )

  t.test("order_worklogs usecase emits a tag clear when sorting needs it", function()
    local result = order_worklogs.run({
      "--- worklog ---",
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
    })
  end)

  t.test("order_worklogs usecase preserves !L", function()
    local result = order_worklogs.run({
      "--- worklog #sales ---",
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

  t.test("order_worklogs usecase emits a location clear when sorting needs it", function()
    local result = order_worklogs.run({
      "--- worklog #sales ---",
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
    })
  end)

  t.test("log_current marks the source entry behind an exact summary row", function()
    local result = log_current.run({
      "--- worklog ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h implementation",
    }, 6)

    t.eq(result, {
      edits = {
        {
          start_index = 4,
          end_index = 6,
          lines = {
            "--- summary exact ---",
            "1.00h implementation !L",
            "",
            "--- logged exact ---",
            "1.00h logged",
            "",
            "--- totals exact ---",
            "1.00h workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 implementation !L" },
        },
      },
    })
  end)

  t.test("log_current marks the source entry behind a quantized summary row", function()
    local result = log_current.run({
      "--- worklog quantize=30 ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary quantized ---",
      "1.00h (+0m) implementation",
    }, 6)

    t.eq(result, {
      edits = {
        {
          start_index = 4,
          end_index = 6,
          lines = {
            "--- summary quantized ---",
            "1.00h (+0m) implementation !L",
            "",
            "--- logged quantized ---",
            "1.00h (+0m) logged",
            "",
            "--- totals quantized ---",
            "1.00h (+0m) workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 implementation !L" },
        },
      },
    })
  end)

  t.test("log_current marks every source entry contributing to one summary row", function()
    local result = log_current.run({
      "--- worklog ---",
      "08:00 implementation",
      "09:00 meeting",
      "10:00 implementation",
      "11:00 done",
      "",
      "--- summary exact ---",
      "2.00h implementation",
      "1.00h meeting",
    }, 8)

    t.eq(result, {
      edits = {
        {
          start_index = 6,
          end_index = 9,
          lines = {
            "--- summary exact ---",
            "2.00h implementation !L",
            "1.00h meeting",
            "",
            "--- logged exact ---",
            "2.00h logged",
            "1.00h unlogged",
            "",
            "--- totals exact ---",
            "3.00h workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 implementation !L" },
        },
        {
          start_index = 3,
          end_index = 4,
          lines = { "10:00 implementation !L" },
        },
      },
    })
  end)

  t.test("log_current leaves notes under entries untouched", function()
    local result = log_current.run({
      "--- worklog ---",
      "08:00 implementation",
      "note text",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h implementation",
    }, 7)

    t.eq(result, {
      edits = {
        {
          start_index = 5,
          end_index = 7,
          lines = {
            "--- summary exact ---",
            "1.00h implementation !L",
            "",
            "--- logged exact ---",
            "1.00h logged",
            "",
            "--- totals exact ---",
            "1.00h workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 implementation !L" },
        },
      },
    })
  end)

  t.test("log_current canonicalizes metadata order around the appended !L", function()
    local result = log_current.run({
      "--- worklog ---",
      "08:00 plan #ClientA @office",
      "09:00 done #- @-",
      "",
      "--- summary exact ---",
      "1.00h plan",
    }, 6)

    t.eq(result, {
      edits = {
        {
          start_index = 4,
          end_index = 6,
          lines = {
            "--- summary exact ---",
            "1.00h plan !L",
            "",
            "--- tags exact ---",
            "1.00h #ClientA",
            "",
            "--- locations exact ---",
            "1.00h @office",
            "",
            "--- logged exact ---",
            "1.00h logged",
            "",
            "--- totals exact ---",
            "1.00h workday",
          },
        },
        {
          start_index = 1,
          end_index = 2,
          lines = { "08:00 plan #ClientA @office !L" },
        },
      },
    })
  end)

  t.test("log_current refuses when the cursor is inside the worklog body", function()
    local result, err = log_current.run({
      "--- worklog ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h implementation",
    }, 2)

    t.eq(result, nil)
    t.eq(err, "worklog: summary row does not match the active worklog; regenerate the summary")
  end)

  t.test("log_current refuses tag-total rows inside the summary block", function()
    local result, err = log_current.run({
      "--- worklog #ClientA ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h implementation",
      "",
      "--- tags exact ---",
      "1.00h #ClientA",
    }, 9)

    t.eq(result, nil)
    t.eq(err, "worklog: summary row does not match the active worklog; regenerate the summary")
  end)

  t.test("log_current refuses total rows", function()
    local result, err = log_current.run({
      "--- worklog ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h implementation",
      "",
      "--- totals exact ---",
      "1.00h workday",
    }, 9)

    t.eq(result, nil)
    t.eq(err, "worklog: summary row does not match the active worklog; regenerate the summary")
  end)

  t.test("log_current refuses already logged summary rows", function()
    local result, err = log_current.run({
      "--- worklog ---",
      "08:00 implementation !L",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h implementation !L",
    }, 6)

    t.eq(result, nil)
    t.eq(err, "worklog: summary row is already logged")
  end)

  t.test("log_current refuses #ooo summary rows", function()
    local result, err = log_current.run({
      "--- worklog ---",
      "08:00 break #ooo",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h break",
    }, 6)

    t.eq(result, nil)
    t.eq(err, "worklog: refusing to mark out-of-office time as logged")
  end)

  t.test("log_current refuses stale summary rows that no longer match the source", function()
    local result, err = log_current.run({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h implementation",
    }, 6)

    t.eq(result, nil)
    t.eq(err, "worklog: summary row does not match the active worklog; regenerate the summary")
  end)

  t.test("log_current refuses when the active worklog has diagnostics", function()
    local result, err = log_current.run({
      "--- worklog ---",
      "09:00 done",
      "08:00 plan",
      "",
      "--- summary exact ---",
      "1.00h plan",
    }, 6)

    t.eq(result, nil)
    t.eq(err, "worklog: unordered timestamps near lines 2 and 3; fix manually or run :WorklogOrder")
  end)

  t.test(
    "log_current refuses summary blocks owned by a non-active worklog even when content would match",
    function()
      -- The cursor row's text matches what the active worklog's recomputed
      -- summary would render, so the content match alone could not save us;
      -- only the ownership check (block.start_row < active.start_row) keeps
      -- the plugin from logging row 9 in the active worklog.
      local result, err = log_current.run({
        "--- worklog ---",
        "08:00 implementation",
        "09:00 done",
        "",
        "--- summary exact ---",
        "1.00h implementation",
        "",
        "--- worklog ---",
        "10:00 implementation",
        "11:00 done",
      }, 6)

      t.eq(result, nil)
      t.eq(err, "worklog: summary row does not match the active worklog; regenerate the summary")
    end
  )

  t.test("log_current refuses summary-like text in an unrelated generic block", function()
    local result, err = log_current.run({
      "--- worklog ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- notes ---",
      "1.00h implementation",
    }, 6)

    t.eq(result, nil)
    t.eq(err, "worklog: summary row does not match the active worklog; regenerate the summary")
  end)

  t.test("log_current refuses labeled summary-like headers after the active worklog", function()
    -- Headers like `--- summary exact 2026-W21 ---` are produced for weekly
    -- and range reports in scratch buffers; if pasted into source they must
    -- not be treated as the active worklog's summary section.
    local result, err = log_current.run({
      "--- worklog ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary exact 2026-W21 ---",
      "1.00h implementation",
    }, 6)

    t.eq(result, nil)
    t.eq(err, "worklog: summary row does not match the active worklog; regenerate the summary")
  end)

  t.test(
    "log_current refuses summary-shaped block headers placed before the active worklog",
    function()
      local result, err = log_current.run({
        "--- summary exact ---",
        "1.00h implementation",
        "",
        "--- worklog ---",
        "08:00 implementation",
        "09:00 done",
      }, 2)

      -- The leading block is rejected by the structural parser because the
      -- first line is not a worklog header. This proves :WorklogLog cannot be
      -- coerced into logging the active worklog through a pre-active "summary"
      -- block.
      t.eq(result, nil)
      t.eq(
        err,
        "worklog: first line must be a worklog header such as "
          .. "--- worklog --- or --- worklog #ClientA @office quantize=30 ---"
      )
    end
  )

  t.test(
    "log_current replaces the full existing summary group including all subsections",
    function()
      -- Buffer already has tags, locations, and totals sections. After logging,
      -- all sections are replaced atomically with the freshly rendered group
      -- that now includes a logged section.
      local result = log_current.run({
        "--- worklog #ClientA @office ---",
        "08:00 planning",
        "10:00 review",
        "11:00 done",
        "",
        "--- summary exact ---",
        "2.00h planning",
        "1.00h review",
        "",
        "--- tags exact ---",
        "3.00h #ClientA",
        "",
        "--- locations exact ---",
        "3.00h @office",
        "",
        "--- totals exact ---",
        "3.00h workday",
      }, 7)

      t.eq(result, {
        edits = {
          {
            start_index = 5,
            end_index = 17,
            lines = {
              "--- summary exact ---",
              "2.00h planning !L",
              "1.00h review",
              "",
              "--- tags exact ---",
              "3.00h #ClientA",
              "",
              "--- locations exact ---",
              "3.00h @office",
              "",
              "--- logged exact ---",
              "2.00h logged",
              "1.00h unlogged",
              "",
              "--- totals exact ---",
              "3.00h workday",
            },
          },
          {
            start_index = 1,
            end_index = 2,
            lines = { "08:00 planning !L" },
          },
        },
      })
    end
  )

  t.test(
    "log_current regression: quantized summary group with note line and partial logging",
    function()
      -- Reported bug: :WorklogLog updated the source entry but left the
      -- rendered summary stale. After the fix the full group — including the
      -- newly required logged section — is replaced in one atomic edit.
      local lines = {
        "--- worklog #someproject @office ---",
        "08:00 versions",
        "09:00 stand",
        "09:20 versions",
        "10:12 folksy",
        "    what is he talking about    ",
        "10:17 Q1 features",
        "11:01 versions",
        "",
        "--- summary quantized ---",
        "2.00h (-8m) versions",
        "0.75h (-1m) Q1 features",
        "0.25h (+5m) stand",
        "0.00h (+5m) folksy",
        "",
        "--- tags quantized ---",
        "3.00h (+1m) #someproject",
        "",
        "--- locations quantized ---",
        "3.00h (+1m) @office",
        "",
        "--- totals quantized ---",
        "3.00h (+1m) workday",
      }

      local result = log_current.run(lines, 12)

      t.eq(result, {
        edits = {
          {
            start_index = 9,
            end_index = 23,
            lines = {
              "--- summary quantized ---",
              "2.00h (-8m) versions",
              "0.75h (-1m) Q1 features !L",
              "0.25h (+5m) stand",
              "0.00h (+5m) folksy",
              "",
              "--- tags quantized ---",
              "3.00h (+1m) #someproject",
              "",
              "--- locations quantized ---",
              "3.00h (+1m) @office",
              "",
              "--- logged quantized ---",
              "0.75h (-1m) logged",
              "2.25h (+2m) unlogged",
              "",
              "--- totals quantized ---",
              "3.00h (+1m) workday",
            },
          },
          {
            start_index = 6,
            end_index = 7,
            lines = { "10:17 Q1 features !L" },
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
        "--- worklog #someproject @office ---",
        "08:00 versions",
        "09:00 stand",
        "09:20 versions",
        "10:12 folksy",
        "    what is he talking about    ",
        "10:17 Q1 features !L",
        "11:01 versions",
        "",
        "--- summary quantized ---",
        "2.00h (-8m) versions",
        "0.75h (-1m) Q1 features !L",
        "0.25h (+5m) stand",
        "0.00h (+5m) folksy",
        "",
        "--- tags quantized ---",
        "3.00h (+1m) #someproject",
        "",
        "--- locations quantized ---",
        "3.00h (+1m) @office",
        "",
        "--- logged quantized ---",
        "0.75h (-1m) logged",
        "2.25h (+2m) unlogged",
        "",
        "--- totals quantized ---",
        "3.00h (+1m) workday",
      })
    end
  )
end
