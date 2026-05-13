return function(t)
  local entry = require("worklog.entry")

  t.test("entry parse uses default labels when present", function()
    local parsed = entry.parse("08:04 bake strudel", "ProjectOrion")
    t.eq(parsed.minutes, 484)
    t.eq(parsed.text, "bake strudel")
    t.eq(parsed.label, "ProjectOrion")
    t.eq(parsed.excluded, false)
  end)

  t.test("entry parse keeps explicit and ooo labels", function()
    local parsed = entry.parse("08:04 bake strudel #sales", "ProjectOrion")
    t.eq(parsed.label, "sales")
    t.eq(parsed.excluded, false)

    parsed = entry.parse("08:04 coffee #ooo", "ProjectOrion")
    t.eq(parsed.label, "ooo")
    t.eq(parsed.excluded, true)
  end)

  t.test("entry parse keeps inline hashtags in text", function()
    local parsed = entry.parse("08:04 fix #123 issue #sales", "ProjectOrion")
    t.eq(parsed.text, "fix #123 issue")
    t.eq(parsed.label, "sales")
  end)

  t.test("entry parse returns nil for non-entry lines and errors for malformed entries", function()
    t.eq(entry.parse("note"), nil)

    local parsed, err = entry.parse("08:04x", "ProjectOrion")
    t.eq(parsed, false)
    t.eq(err, "expected whitespace after the time")

    parsed, err = entry.parse("08:04 bake strudel #sales #meeting", "ProjectOrion")
    t.eq(parsed, false)
    t.eq(err, "multiple trailing labels are not allowed")
  end)

  t.test("entry format suppresses default labels and keeps explicit ones", function()
    t.eq(entry.format({ minutes = 480, text = "first", label = "ProjectOrion", excluded = false }, "ProjectOrion"), "08:00 first")
    t.eq(entry.format({ minutes = 480, text = "second", label = "sales", excluded = false }, "ProjectOrion"), "08:00 second #sales")
    t.eq(entry.format({ minutes = 480, text = "break", label = "ooo", excluded = true }, "ProjectOrion"), "08:00 break #ooo")
  end)
end
