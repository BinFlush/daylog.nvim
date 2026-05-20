return function(t)
  local append_copy = require("worklog.usecases.append_copy")
  local append_quantized_summary = require("worklog.usecases.append_quantized_summary")
  local append_summary = require("worklog.usecases.append_summary")
  local check = require("worklog.usecases.check")
  local insert_now = require("worklog.usecases.insert_now")
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
end
