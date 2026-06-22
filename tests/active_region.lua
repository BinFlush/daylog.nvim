return function(t)
  local highlight = require("daylog.highlight")
  t.test("active_region: nil when there is no log", function()
    t.eq(highlight.active_region({ "just a note", "another line" }), nil)
  end)
  t.test("active_region: a single log reports log_count 1", function()
    local r = highlight.active_region({ "--- log ---", "08:00 a", "09:00 done" })
    t.eq(r.log_count, 1)
    t.eq(r.start_row, 1)
    t.eq(r.end_row, 3)
  end)
  t.test("active_region: two logs span the second to EOF", function()
    local lines = {
      "--- log ---",
      "08:00 a",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) a",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
      "",
      "--- log ---",
      "10:00 b",
      "11:00 done",
    }
    local r = highlight.active_region(lines)
    t.eq(r.log_count, 2)
    t.eq(r.start_row, 11)
    t.eq(r.end_row, #lines)
  end)
end
