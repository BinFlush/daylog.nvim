-- Direct tests for the shared diagnostic messaging + collection, previously exercised only indirectly.
return function(t)
  local diagnostics = require("daylog.diagnostics")
  local syntax = require("daylog.syntax")
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")

  t.test("message renders each diagnostic code and does not double-prefix", function()
    t.eq(
      diagnostics.message({
        code = syntax.DIAGNOSTIC.INVALID_ENTRY,
        row = 3,
        message = "invalid time",
      }),
      "daylog: invalid entry at line 3: invalid time"
    )
    t.eq(
      diagnostics.message({ code = syntax.DIAGNOSTIC.UNORDERED_TIMESTAMPS, row = 2, row2 = 3 }),
      "daylog: unordered timestamps near lines 2 and 3; fix manually or run :Daylog order"
    )
    -- An already-"daylog:"-prefixed message is passed through unchanged.
    t.eq(
      diagnostics.message({ code = "x", message = "daylog: already prefixed" }),
      "daylog: already prefixed"
    )
    -- A bare message gets the prefix.
    t.eq(diagnostics.message({ code = "x", message = "plain problem" }), "daylog: plain problem")
  end)

  t.test("collect flags entries with no log header, and is empty for a clean log", function()
    local orphan = analyze.analyze(document.parse({ "08:00 plan", "09:00 done" }))
    local warnings = diagnostics.collect(orphan)
    t.eq(#warnings, 1)
    t.eq(warnings[1].message, diagnostics.NO_LOG_ERROR)

    local clean = analyze.analyze(document.parse({ "--- log ---", "08:00 plan", "09:00 done" }))
    t.eq(#diagnostics.collect(clean), 0)
  end)
end
