return function(t)
  local entry = require("daylog.entry")

  t.test("entry parse uses sticky metadata when present", function()
    local parsed = entry.parse("08:04 bake strudel", "ProjectOrion", "office")
    t.eq(parsed.minutes, 484)
    t.eq(parsed.text, "bake strudel")
    t.eq(parsed.tag, "ProjectOrion")
    t.eq(parsed.location, "office")
  end)

  t.test("entry parse keeps explicit tag, location, and ooo tag", function()
    local parsed = entry.parse("08:04 bake strudel #sales @client", "ProjectOrion", "office")
    t.eq(parsed.tag, "sales")
    t.eq(parsed.location, "client")

    parsed = entry.parse("08:04 coffee #ooo", "ProjectOrion", "office")
    t.eq(parsed.tag, "ooo")
    t.eq(parsed.location, "office")
  end)

  t.test("entry parse keeps explicit clear tokens", function()
    local parsed = entry.parse("08:04 reset #- @-", "ProjectOrion", "office")
    t.eq(parsed.tag, nil)
    t.eq(parsed.location, nil)
    t.eq(parsed.explicit_tag_clear, true)
    t.eq(parsed.explicit_location_clear, true)
  end)

  t.test("entry parse keeps trailing !S without making it sticky", function()
    local parsed = entry.parse("08:04 bake strudel !S #sales @client", "ProjectOrion", "office")
    t.eq(parsed.tag, "sales")
    t.eq(parsed.location, "client")
    t.eq(parsed.logged, { s = {} })

    parsed = entry.parse("08:04 bake strudel", "ProjectOrion", "office")
    t.eq(parsed.logged, nil)
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
      }, "ProjectOrion", "office"),
      "08:00 first"
    )
    t.eq(
      entry.format({
        minutes = 480,
        text = "second",
        tag = "ProjectOrion",
        location = "client",
      }, "ProjectOrion", "office"),
      "08:00 second @client"
    )
    t.eq(
      entry.format({
        minutes = 480,
        text = "third",
        tag = "sales",
        location = "client",
      }, "ProjectOrion", "office"),
      "08:00 third #sales @client"
    )
    t.eq(
      entry.format(
        { minutes = 480, text = "break", tag = "ooo", location = "office" },
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
        logged = { s = {} },
      }, "ProjectOrion", "office"),
      "08:00 third #sales @client !S"
    )
    t.eq(
      entry.format({
        minutes = 480,
        text = "reset",
        tag = nil,
        location = nil,
        logged = { s = {} },
      }, "ProjectOrion", "office"),
      "08:00 reset #- @- !S"
    )
  end)

  t.test("entry parse resolves the sticky utc offset", function()
    local inherited = entry.parse("08:00 standup", "ClientA", "office", 120)
    t.eq(inherited.offset, 120)
    t.eq(inherited.explicit_offset, nil)

    local explicit = entry.parse("11:00 resume utc-4", "ClientA", "office", 120)
    t.eq(explicit.offset, -240)
    t.eq(explicit.explicit_offset, -240)
  end)

  t.test("entry format emits the utc offset only when it changes, with no clear", function()
    -- First set, from no offset.
    t.eq(entry.format({ minutes = 480, text = "a", offset = 120 }, nil, nil, nil), "08:00 a utc+2")
    -- Unchanged from the current offset: nothing emitted.
    t.eq(entry.format({ minutes = 480, text = "a", offset = 120 }, nil, nil, 120), "08:00 a")
    -- Changed: re-emitted.
    t.eq(entry.format({ minutes = 660, text = "b", offset = -240 }, nil, nil, 120), "11:00 b utc-4")
    -- utc+0 is a concrete value (UTC), emitted on change like any other offset.
    t.eq(entry.format({ minutes = 480, text = "c", offset = 0 }, nil, nil, 120), "08:00 c utc+0")
    -- A nil offset (no offsets in play) never emits a (nonexistent) clear token.
    t.eq(entry.format({ minutes = 480, text = "d", offset = nil }, nil, nil, nil), "08:00 d")
  end)

  t.test("entry format orders trailing metadata as #tag @location utc and then !S", function()
    t.eq(
      entry.format({
        minutes = 480,
        text = "x",
        tag = "sales",
        location = "client",
        offset = 120,
        logged = { s = {} },
      }, "ProjectOrion", "office", nil),
      "08:00 x #sales @client utc+2 !S"
    )
  end)

  t.test("entry sanitize_text neutralizes a trailing utc offset", function()
    t.eq(entry.sanitize_text("ship release utc+2"), "ship release (utc+2)")
    -- A non-trailing utc word is left alone (only the trailing run is wrapped).
    t.eq(entry.sanitize_text("utc migration notes"), "utc migration notes")
  end)

  t.test("entry format emits a round nudge when nonzero, after the offset", function()
    t.eq(
      entry.format({ minutes = 480, text = "plan", nudge = 1 }, nil, nil, nil),
      "08:00 plan round+1"
    )
    t.eq(
      entry.format({ minutes = 480, text = "plan", nudge = -2 }, nil, nil, nil),
      "08:00 plan round-2"
    )
    -- A zero or absent nudge emits nothing (non-sticky, like !S).
    t.eq(entry.format({ minutes = 480, text = "plan", nudge = 0 }, nil, nil, nil), "08:00 plan")
    t.eq(entry.format({ minutes = 480, text = "plan" }, nil, nil, nil), "08:00 plan")

    -- Trailing order: #tag @location utc±H round±N !S.
    t.eq(
      entry.format({
        minutes = 480,
        text = "x",
        tag = "sales",
        location = "client",
        offset = 120,
        nudge = 1,
        logged = { s = {} },
      }, "ProjectOrion", "office", nil),
      "08:00 x #sales @client utc+2 round+1 !S"
    )
  end)

  t.test("entry parse reads a round nudge; sanitize neutralizes a trailing one", function()
    t.eq(entry.parse("08:00 plan round+2", "ClientA", "office").nudge, 2)
    t.eq(entry.sanitize_text("ship it round+1"), "ship it (round+1)")
    t.eq(entry.sanitize_text("another round of edits"), "another round of edits")
  end)

  t.test("entry parse reads a frozen !S value; a bare !S has none", function()
    local parsed = entry.parse("08:00 plan !S60", "ClientA", "office")
    t.eq(parsed.logged, { s = { minutes = 60 } })

    parsed = entry.parse("08:00 plan !S", "ClientA", "office")
    t.eq(parsed.logged, { s = {} })
  end)

  t.test("entry format emits a frozen !S value, bare when absent", function()
    t.eq(
      entry.format(
        { minutes = 480, text = "plan", logged = { s = { minutes = 60 } } },
        nil,
        nil,
        nil
      ),
      "08:00 plan !S60"
    )
    t.eq(
      entry.format({ minutes = 480, text = "plan", logged = { s = {} } }, nil, nil, nil),
      "08:00 plan !S"
    )
    -- A logged table with no levels (what an unmark leaves) emits no marker.
    t.eq(entry.format({ minutes = 480, text = "plan", logged = {} }, nil, nil, nil), "08:00 plan")
  end)

  t.test("entry sanitize_text neutralizes a trailing frozen !S value", function()
    t.eq(entry.sanitize_text("ship it !S45"), "ship it (!S45)")
    -- A non-token word that merely starts with the letters is left alone.
    t.eq(entry.sanitize_text("look at !Slamas"), "look at !Slamas")
  end)

  t.test("entry parse reads a multi-word alias with trailing metadata", function()
    -- The metadata trails the line as usual and attaches to the entry; the alias is the
    -- ` => label` between the description and that metadata.
    local parsed = entry.parse("09:00 fix login => BUG-123 Fix the login #ProjectOrion !S30")
    t.eq(parsed.text, "fix login")
    t.eq(parsed.tag, "ProjectOrion")
    t.eq(parsed.logged, { s = { minutes = 30 } })
    t.eq(parsed.alias, "BUG-123 Fix the login")
  end)

  t.test("entry parse takes the alias from the last => separator", function()
    -- A description that itself contains ` => ` keeps everything up to the final one.
    local parsed = entry.parse("09:00 turn a => b => CANONICAL")
    t.eq(parsed.text, "turn a => b")
    t.eq(parsed.alias, "CANONICAL")
  end)

  t.test("entry format places the alias after the description, before the metadata", function()
    t.eq(
      entry.format({ minutes = 540, text = "fix login", tag = "ProjectOrion", alias = "BUG-123" }),
      "09:00 fix login => BUG-123 #ProjectOrion"
    )
    -- An empty alias emits nothing (a cleared mapping), keeping non-aliased lines stable.
    t.eq(entry.format({ minutes = 540, text = "fix login", alias = "" }), "09:00 fix login")
  end)

  t.test("entry sanitize_alias collapses whitespace and neutralizes trailing tokens", function()
    t.eq(entry.sanitize_alias("  BUG-123   Fix  "), "BUG-123 Fix")
    -- The alias is followed by metadata, so a trailing token-shaped word is parenthesized.
    t.eq(entry.sanitize_alias("BUG #urgent"), "BUG (#urgent)")
    -- It cannot contain its own separator either.
    t.eq(entry.sanitize_alias("BUG => prod"), "BUG (=>) prod")
    t.eq(entry.sanitize_alias(""), "")
  end)

  t.test("entry sanitize_text neutralizes an embedded alias separator", function()
    -- A pasted/source title must not silently become an alias.
    t.eq(entry.sanitize_text("turn a => b"), "turn a (=>) b")
  end)
end
