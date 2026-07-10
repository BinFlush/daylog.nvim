return function(t)
  local insert_entry = require("daylog.usecases.insert_entry")

  t.test("insert_entry inserts a full HH:MM <text> line with cursor and insert mode", function()
    local result = insert_entry.run({
      "--- log ---",
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
        "--- log #ClientA @office ---",
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
      "--- log ---",
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
      "--- log ---",
      "08:00 first",
      "09:00 done",
    }, 1, "25:00", "x")

    t.eq(result, nil)
    t.eq(err, "daylog: invalid current time: invalid time")
  end)

  t.test("insert_entry rejects a cursor outside any log", function()
    local result, err = insert_entry.run({
      "08:00 raw",
      "09:00 done",
    }, 1, "10:00", "x")

    t.eq(result, nil)
    t.ok(err ~= nil)
  end)

  t.test("insert_entry sanitizes text so a title cannot inject trailing metadata", function()
    local result = insert_entry.run({
      "--- log ---",
      "08:00 first",
      "09:00 done",
    }, 1, "08:30", "5 Investigate #flaky")

    t.eq(result.edits, {
      {
        start_index = 2,
        end_index = 2,
        lines = { "08:30 5 Investigate (#flaky)" },
      },
    })
  end)

  t.test("insert_entry lands the cursor before a drifted utc token so typing keeps the offset", function()
    -- Header utc+2 with the live offset drifted to utc+1 (60): entry.format trails a "utc+1" token, so
    -- the cursor must sit before it (startinsert = "cursor") -- otherwise continued typing reparses the
    -- token into the description and silently drops the entry's offset.
    local result = insert_entry.run({
      "--- log utc+2 ---",
      "08:00 earlier",
      "10:00 later",
    }, 2, "09:00", "meeting", 60)

    local insert_line
    for _, e in ipairs(result.edits) do
      for _, l in ipairs(e.lines) do
        if l:find("meeting", 1, true) then
          insert_line = l
        end
      end
    end
    t.eq(insert_line, "09:00 meeting utc+1")
    t.eq(result.startinsert, "cursor")
    -- Cursor after "meeting", before " utc+1".
    t.eq(result.cursor[2], #"09:00 meeting")
    t.eq(insert_line:sub(result.cursor[2] + 1), " utc+1")
  end)
end
