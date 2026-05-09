return function(t)
  local parse = require("worklog.parse")

  t.test("parse unlabeled line uses file default label", function()
    local entry = parse.parse_time_line("08:04 bake strudel", "ProjectOrion")
    t.eq(entry.minutes, 484)
    t.eq(entry.text, "bake strudel")
    t.eq(entry.label, "ProjectOrion")
    t.eq(entry.excluded, false)
  end)

  t.test("parse explicit trailing label", function()
    local entry = parse.parse_time_line("08:04 bake strudel #sales", "ProjectOrion")
    t.eq(entry.minutes, 484)
    t.eq(entry.text, "bake strudel")
    t.eq(entry.label, "sales")
    t.eq(entry.excluded, false)
  end)

  t.test("parse ooo as exclusive label", function()
    local entry = parse.parse_time_line("08:04 coffee #ooo", "ProjectOrion")
    t.eq(entry.minutes, 484)
    t.eq(entry.text, "coffee")
    t.eq(entry.label, "ooo")
    t.eq(entry.excluded, true)
  end)

  t.test("parse keeps inline hashtags inside text", function()
    local entry = parse.parse_time_line("08:04 fix #123 issue #sales", "ProjectOrion")
    t.eq(entry.minutes, 484)
    t.eq(entry.text, "fix #123 issue")
    t.eq(entry.label, "sales")
    t.eq(entry.excluded, false)
  end)

  t.test("parse bare timestamp uses default label", function()
    local entry = parse.parse_time_line("08:04", "ProjectOrion")
    t.eq(entry.minutes, 484)
    t.eq(entry.text, "")
    t.eq(entry.label, "ProjectOrion")
    t.eq(entry.excluded, false)
  end)

  t.test("parse bare timestamp without default leaves label empty", function()
    local entry = parse.parse_time_line("08:04")
    t.eq(entry.minutes, 484)
    t.eq(entry.text, "")
    t.eq(entry.label, nil)
    t.eq(entry.excluded, false)
  end)

  t.test("reject malformed suffix", function()
    local entry, err = parse.parse_time_line("08:04x", "ProjectOrion")
    t.eq(entry, false)
    t.eq(err, "expected whitespace after the time")
  end)

  t.test("reject invalid hours and minutes", function()
    local entry, err = parse.parse_time_line("24:00 nope", "ProjectOrion")
    t.eq(entry, false)
    t.eq(err, "invalid time")

    entry, err = parse.parse_time_line("23:60 nope", "ProjectOrion")
    t.eq(entry, false)
    t.eq(err, "invalid time")
  end)

  t.test("reject multiple trailing labels", function()
    local entry, err = parse.parse_time_line("08:04 bake strudel #sales #meeting", "ProjectOrion")
    t.eq(entry, false)
    t.eq(err, "multiple trailing labels are not allowed")
  end)

  t.test("parse lines ignores non semantic lines but reports invalid entries", function()
    local entries = parse.parse_lines({
      "08:00 first",
      "note",
      "08:30 second #ooo",
      "bad time 99:99",
      "09:00",
    }, "ProjectOrion")

    t.eq(entries, {
      {
        minutes = 480,
        text = "first",
        label = "ProjectOrion",
        excluded = false,
      },
      {
        minutes = 510,
        text = "second",
        label = "ooo",
        excluded = true,
      },
      {
        minutes = 540,
        text = "",
        label = "ProjectOrion",
        excluded = false,
      },
    })

    entries, err = parse.parse_lines({
      "08:00 first",
      "08:30 second #sales #meeting",
    }, "ProjectOrion")
    t.eq(entries, nil)
    t.eq(err.row, 2)
    t.eq(err.message, "multiple trailing labels are not allowed")
  end)

  t.test("parse lines allow unlabeled entries without default", function()
    local entries = parse.parse_lines({
      "08:00 first",
      "08:30 second #sales",
      "09:00 done",
    })

    t.eq(entries, {
      {
        minutes = 480,
        text = "first",
        label = nil,
        excluded = false,
      },
      {
        minutes = 510,
        text = "second",
        label = "sales",
        excluded = false,
      },
      {
        minutes = 540,
        text = "done",
        label = nil,
        excluded = false,
      },
    })
  end)
end
