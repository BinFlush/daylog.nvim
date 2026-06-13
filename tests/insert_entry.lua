return function(t)
  local insert_entry = require("worklog.usecases.insert_entry")

  t.test("insert_entry inserts a full HH:MM <text> line with cursor and insert mode", function()
    local result = insert_entry.run({
      "--- worklog ---",
      "08:00 first",
      "09:00 done",
    }, 1, "08:30", "1234 Fix login")

    t.eq(result, {
      edits = {
        {
          start_index = 2,
          end_index = 2,
          lines = { "08:30 1234 Fix login" },
        },
      },
      cursor = { 3, #"08:30 1234 Fix login" },
      startinsert = true,
    })
  end)

  t.test(
    "insert_entry inherits sticky metadata without adding tokens or rewriting the follower",
    function()
      local result = insert_entry.run({
        "--- worklog #ClientA @office ---",
        "08:00 a",
        "10:00 b",
        "12:00 c",
      }, 1, "11:00", "9 ticket")

      -- The inserted line carries no #ClientA/@office token (it inherits them) and
      -- the follower "12:00 c" is left untouched.
      t.eq(result, {
        edits = {
          {
            start_index = 3,
            end_index = 3,
            lines = { "11:00 9 ticket" },
          },
        },
        cursor = { 4, #"11:00 9 ticket" },
        startinsert = true,
      })
    end
  )

  t.test("insert_entry orders after equal timestamps", function()
    local result = insert_entry.run({
      "--- worklog ---",
      "08:00 first",
      "08:00 second",
      "09:00 done",
    }, 1, "08:00", "8 sync")

    t.eq(result.edits, {
      {
        start_index = 3,
        end_index = 3,
        lines = { "08:00 8 sync" },
      },
    })
  end)

  t.test("insert_entry rejects an invalid time", function()
    local result, err = insert_entry.run({
      "--- worklog ---",
      "08:00 first",
      "09:00 done",
    }, 1, "25:00", "x")

    t.eq(result, nil)
    t.eq(err, "worklog: invalid current time: invalid time")
  end)

  t.test("insert_entry rejects a cursor outside any worklog", function()
    local result, err = insert_entry.run({
      "08:00 raw",
      "09:00 done",
    }, 1, "10:00", "x")

    t.eq(result, nil)
    t.ok(err ~= nil)
  end)
end
