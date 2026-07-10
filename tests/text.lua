-- Direct tests for the shared text predicates (used across buffer/week/current_time/daybook_io), which
-- were only exercised incidentally before.
return function(t)
  local text = require("daylog.text")

  t.test("is_empty treats nil, empty, and whitespace-only as empty", function()
    t.eq(text.is_empty(nil), true)
    t.eq(text.is_empty({}), true)
    t.eq(text.is_empty({ "", "   ", "\t" }), true)
    t.eq(text.is_empty({ "", "x" }), false)
    t.eq(text.is_empty({ "  a  " }), false)
  end)

  t.test("normalize collapses internal whitespace and trims the ends", function()
    t.eq(text.normalize("  a   b\tc  "), "a b c")
    t.eq(text.normalize("plain"), "plain")
    t.eq(text.normalize("   "), "")
    t.eq(text.normalize(""), "")
  end)
end
