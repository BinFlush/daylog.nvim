return function(t)
  local picker = require("blotter.sources.picker")

  t.test("merge unions cached and server items, cached first", function()
    local initial = { { id = "1", title = "A" }, { id = "2", title = "B" } }
    local extra = { { id = "3", title = "C" } }
    local out = picker.merge(initial, extra)
    t.eq(#out, 3)
    t.eq(out[1].id, "1")
    t.eq(out[2].id, "2")
    t.eq(out[3].id, "3")
  end)

  t.test("merge dedups by id, keeping the cached copy", function()
    local initial = { { id = "1", title = "cached" } }
    local extra = { { id = "1", title = "server" }, { id = "2", title = "new" } }
    local out = picker.merge(initial, extra)
    t.eq(#out, 2)
    t.eq(out[1].title, "cached")
    t.eq(out[2].id, "2")
  end)

  t.test("merge dedups across numeric and string id forms", function()
    local out = picker.merge({ { id = 1, title = "num" } }, { { id = "1", title = "str" } })
    t.eq(#out, 1)
    t.eq(out[1].title, "num")
  end)

  t.test("merge tolerates nil and empty inputs", function()
    t.eq(picker.merge(nil, nil), {})
    t.eq(picker.merge({}, {}), {})
    local only_extra = picker.merge(nil, { { id = "9", title = "Z" } })
    t.eq(#only_extra, 1)
    t.eq(only_extra[1].id, "9")
  end)

  t.test("align pads every column but the last to its widest cell", function()
    t.eq(
      picker.align({
        { "#5", "[Bug/Active]", "Fix login" },
        { "#1234", "[Task/New]", "Refactor" },
      }),
      {
        "#5     [Bug/Active]  Fix login",
        "#1234  [Task/New]    Refactor",
      }
    )
  end)

  t.test("align trims a trailing empty last cell and tolerates one column", function()
    t.eq(picker.align({ { "#5", "" }, { "#1234", "" } }), { "#5", "#1234" })
    t.eq(picker.align({ { "only" } }), { "only" })
    t.eq(picker.align({}), {})
  end)

  t.test("should_query fires only for a non-empty, changed prompt", function()
    t.eq(picker.should_query("foo", nil), true)
    t.eq(picker.should_query("foo", "bar"), true)
    t.eq(picker.should_query("", nil), false)
    t.eq(picker.should_query("foo", "foo"), false)
  end)

  t.test("should_query honors a minimum query length", function()
    t.eq(picker.should_query("ab", nil, 3), false)
    t.eq(picker.should_query("abc", nil, 3), true)
    t.eq(picker.should_query("abc", "abc", 3), false)
    t.eq(picker.should_query("", nil, 3), false)
    t.eq(picker.should_query("a", nil, 1), true)
    -- A missing or sub-1 minimum clamps to 1: any non-empty, changed prompt.
    t.eq(picker.should_query("a", nil, nil), true)
    t.eq(picker.should_query("a", nil, 0), true)
    t.eq(picker.should_query("", nil, 0), false)
  end)
end
