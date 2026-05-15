return function(t)
  local append_copy = require("worklog.usecases.append_copy")
  local append_summary = require("worklog.usecases.append_summary")
  local body = require("worklog.body")
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
            "0.50h plan @office",
            "0.50h call #sales @client",
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
            "1.00h activity",
            "1.00h workday",
          },
        },
      },
    })
  end)

  t.test("append_copy usecase propagates normalization failure", function()
    local old_normalized_lines = body.normalized_lines
    body.normalized_lines = function()
      return nil, "worklog: synthetic normalized failure"
    end

    local result, err = append_copy.run({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "09:00 done",
    })

    body.normalized_lines = old_normalized_lines

    t.eq(result, nil)
    t.eq(err, "worklog: synthetic normalized failure")
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

  t.test("repeat_current usecase fails when repeating would clear a sticky tag", function()
    local result, err = repeat_current.run({
      "--- worklog @office ---",
      "08:00 planning",
      "10:00 internal meeting #internal",
      "11:00 done",
    }, 2, "10:30")

    t.eq(result, nil)
    t.eq(err, "worklog: cannot repeat an untagged entry after sticky tag has been set")
  end)

  t.test("repeat_current usecase fails when repeating would clear a sticky location", function()
    local result, err = repeat_current.run({
      "--- worklog #ClientA ---",
      "08:00 planning",
      "10:00 implementation @home",
      "11:00 done",
    }, 2, "10:30")

    t.eq(result, nil)
    t.eq(err, "worklog: cannot repeat an entry without location after sticky location has been set")
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

  t.test("order_worklogs usecase fails when sorting would clear a sticky tag", function()
    local result, err = order_worklogs.run({
      "--- worklog ---",
      "09:00 done",
      "08:00 plan #sales",
    })

    t.eq(result, nil)
    t.eq(err, "worklog: cannot reorder entry at line 2 because sticky tag cannot be cleared implicitly")
  end)

  t.test("order_worklogs usecase fails when sorting would clear a sticky location", function()
    local result, err = order_worklogs.run({
      "--- worklog #sales ---",
      "09:00 done",
      "08:00 plan @client",
    })

    t.eq(result, nil)
    t.eq(err, "worklog: cannot reorder entry at line 2 because sticky location cannot be cleared implicitly")
  end)
end
