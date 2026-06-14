return function(t)
  local entry = require("worklog.entry")
  local document = require("worklog.document")
  local syntax = require("worklog.syntax")

  -- The load-bearing guard: sanitized text dropped after a timestamp must parse as
  -- a plain entry whose trailing tokens did NOT become metadata.
  local function parses_clean(text)
    local node = document.parse_line("08:00 " .. text)
    return node.kind == syntax.NODE_KIND.ENTRY
      and node.explicit_tag == nil
      and node.explicit_tag_clear == nil
      and node.explicit_location == nil
      and node.explicit_location_clear == nil
      and node.logged == nil
  end

  local cases = {
    { input = "1234 Investigate #flaky", expected = "1234 Investigate (#flaky)" },
    { input = "42 Triage @home", expected = "42 Triage (@home)" },
    { input = "7 Cleanup #- @-", expected = "7 Cleanup (#-) (@-)" },
    { input = "9 Done !L", expected = "9 Done (!L)" },
  }

  for _, case in ipairs(cases) do
    t.test("sanitize neutralizes trailing metadata: " .. case.input, function()
      local out = entry.sanitize_text(case.input)
      t.eq(out, case.expected)
      t.ok(parses_clean(out), "sanitized text must not parse as trailing metadata")
    end)
  end

  t.test("sanitize leaves a mid-text token untouched", function()
    local out = entry.sanitize_text("5 Fix #flaky tests")
    t.eq(out, "5 Fix #flaky tests")
    t.ok(parses_clean(out))
  end)

  t.test("sanitize collapses whitespace", function()
    t.eq(entry.sanitize_text("  1234   Fix   login  "), "1234 Fix login")
  end)

  t.test("sanitize wraps an all-metadata title", function()
    local out = entry.sanitize_text("#1234")
    t.eq(out, "(#1234)")
    t.ok(parses_clean(out))
  end)

  t.test("sanitize returns empty text unchanged", function()
    t.eq(entry.sanitize_text("   "), "")
  end)
end
