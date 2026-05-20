return function(t)
  local entry = require("worklog.entry")

  t.test("entry parse uses sticky metadata when present", function()
    local parsed = entry.parse("08:04 bake strudel", "ProjectOrion", "office")
    t.eq(parsed.minutes, 484)
    t.eq(parsed.text, "bake strudel")
    t.eq(parsed.tag, "ProjectOrion")
    t.eq(parsed.location, "office")
    t.eq(parsed.workday_excluded, false)
  end)

  t.test("entry parse keeps explicit tag, location, and ooo tag", function()
    local parsed = entry.parse("08:04 bake strudel #sales @client", "ProjectOrion", "office")
    t.eq(parsed.tag, "sales")
    t.eq(parsed.location, "client")
    t.eq(parsed.workday_excluded, false)

    parsed = entry.parse("08:04 coffee #ooo", "ProjectOrion", "office")
    t.eq(parsed.tag, "ooo")
    t.eq(parsed.location, "office")
    t.eq(parsed.workday_excluded, true)
  end)

  t.test("entry parse keeps explicit clear tokens", function()
    local parsed = entry.parse("08:04 reset #- @-", "ProjectOrion", "office")
    t.eq(parsed.tag, nil)
    t.eq(parsed.location, nil)
    t.eq(parsed.explicit_tag_clear, true)
    t.eq(parsed.explicit_location_clear, true)
    t.eq(parsed.workday_excluded, false)
  end)

  t.test("entry parse keeps trailing !L without making it sticky", function()
    local parsed = entry.parse("08:04 bake strudel !L #sales @client", "ProjectOrion", "office")
    t.eq(parsed.tag, "sales")
    t.eq(parsed.location, "client")
    t.eq(parsed.logged, true)

    parsed = entry.parse("08:04 bake strudel", "ProjectOrion", "office")
    t.eq(parsed.logged, false)
  end)

  t.test("entry parse keeps inline hashtags in text", function()
    local parsed = entry.parse("08:04 fix #123 issue #sales @office", "ProjectOrion", "home")
    t.eq(parsed.text, "fix #123 issue")
    t.eq(parsed.tag, "sales")
    t.eq(parsed.location, "office")
  end)

  t.test("entry parse returns nil for non-entry lines and errors for malformed entries", function()
    t.eq(entry.parse("note"), nil)

    local parsed, err = entry.parse("08:04x", "ProjectOrion", "office")
    t.eq(parsed, false)
    t.eq(err, "expected whitespace after the time")

    parsed, err = entry.parse("08:04 bake strudel #sales #meeting", "ProjectOrion", "office")
    t.eq(parsed, false)
    t.eq(err, "multiple trailing tags are not allowed")
  end)

  t.test("entry format suppresses unchanged sticky metadata and keeps explicit changes", function()
    t.eq(
      entry.format({
        minutes = 480,
        text = "first",
        tag = "ProjectOrion",
        location = "office",
        workday_excluded = false,
      }, "ProjectOrion", "office"),
      "08:00 first"
    )
    t.eq(
      entry.format({
        minutes = 480,
        text = "second",
        tag = "ProjectOrion",
        location = "client",
        workday_excluded = false,
      }, "ProjectOrion", "office"),
      "08:00 second @client"
    )
    t.eq(
      entry.format({
        minutes = 480,
        text = "third",
        tag = "sales",
        location = "client",
        workday_excluded = false,
      }, "ProjectOrion", "office"),
      "08:00 third #sales @client"
    )
    t.eq(
      entry.format(
        { minutes = 480, text = "break", tag = "ooo", location = "office", workday_excluded = true },
        "ProjectOrion",
        "office"
      ),
      "08:00 break #ooo"
    )
    t.eq(
      entry.format({
        minutes = 480,
        text = "third",
        tag = "sales",
        location = "client",
        workday_excluded = false,
        logged = true,
      }, "ProjectOrion", "office"),
      "08:00 third #sales @client !L"
    )
    t.eq(
      entry.format({
        minutes = 480,
        text = "reset",
        tag = nil,
        location = nil,
        workday_excluded = false,
        logged = true,
      }, "ProjectOrion", "office"),
      "08:00 reset #- @- !L"
    )
  end)
end
