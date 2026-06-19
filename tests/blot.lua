return function(t)
  local blot = require("blotter.blot")

  t.test("blot parse uses sticky metadata when present", function()
    local parsed = blot.parse("08:04 bake strudel", "ProjectOrion", "office")
    t.eq(parsed.minutes, 484)
    t.eq(parsed.text, "bake strudel")
    t.eq(parsed.tag, "ProjectOrion")
    t.eq(parsed.location, "office")
    t.eq(parsed.workday_excluded, false)
  end)

  t.test("blot parse keeps explicit tag, location, and ooo tag", function()
    local parsed = blot.parse("08:04 bake strudel #sales @client", "ProjectOrion", "office")
    t.eq(parsed.tag, "sales")
    t.eq(parsed.location, "client")
    t.eq(parsed.workday_excluded, false)

    parsed = blot.parse("08:04 coffee #ooo", "ProjectOrion", "office")
    t.eq(parsed.tag, "ooo")
    t.eq(parsed.location, "office")
    t.eq(parsed.workday_excluded, true)
  end)

  t.test("blot parse keeps explicit clear tokens", function()
    local parsed = blot.parse("08:04 reset #- @-", "ProjectOrion", "office")
    t.eq(parsed.tag, nil)
    t.eq(parsed.location, nil)
    t.eq(parsed.explicit_tag_clear, true)
    t.eq(parsed.explicit_location_clear, true)
    t.eq(parsed.workday_excluded, false)
  end)

  t.test("blot parse keeps trailing !L without making it sticky", function()
    local parsed = blot.parse("08:04 bake strudel !L #sales @client", "ProjectOrion", "office")
    t.eq(parsed.tag, "sales")
    t.eq(parsed.location, "client")
    t.eq(parsed.logged, true)

    parsed = blot.parse("08:04 bake strudel", "ProjectOrion", "office")
    t.eq(parsed.logged, false)
  end)

  t.test("blot parse keeps inline hashtags in text", function()
    local parsed = blot.parse("08:04 fix #123 issue #sales @office", "ProjectOrion", "home")
    t.eq(parsed.text, "fix #123 issue")
    t.eq(parsed.tag, "sales")
    t.eq(parsed.location, "office")
  end)

  t.test("blot parse returns nil for non-blot lines and errors for malformed blots", function()
    t.eq(blot.parse("note"), nil)

    local parsed, err = blot.parse("08:04x", "ProjectOrion", "office")
    t.eq(parsed, false)
    t.eq(err, "expected whitespace after the time")

    parsed, err = blot.parse("08:04 bake strudel #sales #meeting", "ProjectOrion", "office")
    t.eq(parsed, false)
    t.eq(err, "multiple trailing tags are not allowed")
  end)

  t.test("blot format suppresses unchanged sticky metadata and keeps explicit changes", function()
    t.eq(
      blot.format({
        minutes = 480,
        text = "first",
        tag = "ProjectOrion",
        location = "office",
        workday_excluded = false,
      }, "ProjectOrion", "office"),
      "08:00 first"
    )
    t.eq(
      blot.format({
        minutes = 480,
        text = "second",
        tag = "ProjectOrion",
        location = "client",
        workday_excluded = false,
      }, "ProjectOrion", "office"),
      "08:00 second @client"
    )
    t.eq(
      blot.format({
        minutes = 480,
        text = "third",
        tag = "sales",
        location = "client",
        workday_excluded = false,
      }, "ProjectOrion", "office"),
      "08:00 third #sales @client"
    )
    t.eq(
      blot.format(
        { minutes = 480, text = "break", tag = "ooo", location = "office", workday_excluded = true },
        "ProjectOrion",
        "office"
      ),
      "08:00 break #ooo"
    )
    t.eq(
      blot.format({
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
      blot.format({
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

  t.test("blot parse resolves the sticky utc offset", function()
    local inherited = blot.parse("08:00 standup", "ClientA", "office", 120)
    t.eq(inherited.offset, 120)
    t.eq(inherited.explicit_offset, nil)

    local explicit = blot.parse("11:00 resume utc-4", "ClientA", "office", 120)
    t.eq(explicit.offset, -240)
    t.eq(explicit.explicit_offset, -240)
  end)

  t.test("blot format emits the utc offset only when it changes, with no clear", function()
    -- First set, from no offset.
    t.eq(blot.format({ minutes = 480, text = "a", offset = 120 }, nil, nil, nil), "08:00 a utc+2")
    -- Unchanged from the current offset: nothing emitted.
    t.eq(blot.format({ minutes = 480, text = "a", offset = 120 }, nil, nil, 120), "08:00 a")
    -- Changed: re-emitted.
    t.eq(blot.format({ minutes = 660, text = "b", offset = -240 }, nil, nil, 120), "11:00 b utc-4")
    -- utc+0 is a concrete value (UTC), emitted on change like any other offset.
    t.eq(blot.format({ minutes = 480, text = "c", offset = 0 }, nil, nil, 120), "08:00 c utc+0")
    -- A nil offset (no offsets in play) never emits a (nonexistent) clear token.
    t.eq(blot.format({ minutes = 480, text = "d", offset = nil }, nil, nil, nil), "08:00 d")
  end)

  t.test("blot format orders trailing metadata as #tag @location utc and then !L", function()
    t.eq(
      blot.format({
        minutes = 480,
        text = "x",
        tag = "sales",
        location = "client",
        offset = 120,
        logged = true,
      }, "ProjectOrion", "office", nil),
      "08:00 x #sales @client utc+2 !L"
    )
  end)

  t.test("blot sanitize_text neutralizes a trailing utc offset", function()
    t.eq(blot.sanitize_text("ship release utc+2"), "ship release (utc+2)")
    -- A non-trailing utc word is left alone (only the trailing run is wrapped).
    t.eq(blot.sanitize_text("utc migration notes"), "utc migration notes")
  end)

  t.test("blot format emits a round nudge when nonzero, after the offset", function()
    t.eq(
      blot.format({ minutes = 480, text = "plan", nudge = 1 }, nil, nil, nil),
      "08:00 plan round+1"
    )
    t.eq(
      blot.format({ minutes = 480, text = "plan", nudge = -2 }, nil, nil, nil),
      "08:00 plan round-2"
    )
    -- A zero or absent nudge emits nothing (non-sticky, like !L).
    t.eq(blot.format({ minutes = 480, text = "plan", nudge = 0 }, nil, nil, nil), "08:00 plan")
    t.eq(blot.format({ minutes = 480, text = "plan" }, nil, nil, nil), "08:00 plan")

    -- Trailing order: #tag @location utc±H round±N !L.
    t.eq(
      blot.format({
        minutes = 480,
        text = "x",
        tag = "sales",
        location = "client",
        offset = 120,
        nudge = 1,
        logged = true,
      }, "ProjectOrion", "office", nil),
      "08:00 x #sales @client utc+2 round+1 !L"
    )
  end)

  t.test("blot parse reads a round nudge; sanitize neutralizes a trailing one", function()
    t.eq(blot.parse("08:00 plan round+2", "ClientA", "office").nudge, 2)
    t.eq(blot.sanitize_text("ship it round+1"), "ship it (round+1)")
    t.eq(blot.sanitize_text("another round of edits"), "another round of edits")
  end)
end
