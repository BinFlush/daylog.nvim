return function(t)
  local picker = require("worklog.sources.picker")

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

  t.test("should_query fires only for a non-empty, changed prompt", function()
    t.eq(picker.should_query("foo", nil), true)
    t.eq(picker.should_query("foo", "bar"), true)
    t.eq(picker.should_query("", nil), false)
    t.eq(picker.should_query("foo", "foo"), false)
  end)
end
