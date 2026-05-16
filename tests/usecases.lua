return function(t)
  local append_copy = require("worklog.usecases.append_copy")
  local append_summary = require("worklog.usecases.append_summary")
  local check = require("worklog.usecases.check")
  local insert_now = require("worklog.usecases.insert_now")
  local order_worklogs = require("worklog.usecases.order_worklogs")
  local repeat_current = require("worklog.usecases.repeat_current")

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
    t.eq(err, "worklog: first line must be a worklog header such as --- worklog --- or --- worklog #ClientA @office quantize=30 ---")
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

  t.test("repeat_current usecase rejects invalid injected current time", function()
    local result, err = repeat_current.run({
      "--- worklog ---",
      "08:00 planning",
      "09:00 done",
    }, 2, "25:00")

    t.eq(result, nil)
    t.eq(err, "worklog: invalid current time: invalid time")
  end)

  t.test("order_worklogs usecase returns replace edits for representable sticky rewrites", function()
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
  end)

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
