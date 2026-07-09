-- Pure tests for classifying a commit's `.day` changes: notes-only vs. active-log changes on
-- the commit day (today) vs. any other day (other-day), plus the needs-review flag.
return function(t)
  local audit = require("daylog.commit_audit")

  local COMMIT_DAY = "2026-05-18"
  local TODAY = "2026-05-18.day"
  local YESTERDAY = "2026-05-17.day"

  -- Classify a commit that changed a single file.
  local function one(path, old_lines, new_lines)
    return audit.classify(
      { { path = path, old_lines = old_lines, new_lines = new_lines } },
      COMMIT_DAY
    )
  end

  local LOG = { "--- log ---", "08:00 plan", "09:00 done" }

  t.test("a note-only edit is classified notes, with no logged days", function()
    local with_note = { "--- log ---", "08:00 plan", "09:00 done", "", "a free-text note" }
    local result = one(TODAY, LOG, with_note)
    t.eq(result.classification, "notes")
    t.eq(result.log_days, {})
    t.eq(result.needs_review, false)
  end)

  t.test("a regenerated summary alone is classified notes", function()
    local stale =
      { "--- log ---", "08:00 plan", "09:00 done", "", "--- summary q=15 d=dec ---", "stale" }
    local fresh =
      { "--- log ---", "08:00 plan", "09:00 done", "", "--- summary q=15 d=dec ---", "1.00h plan" }
    t.eq(one(TODAY, stale, fresh).classification, "notes")
  end)

  t.test("a whitespace-only entry edit is not a log change", function()
    local padded = { "--- log ---", "08:00 plan   ", "09:00 done" }
    t.eq(one(TODAY, LOG, padded).classification, "notes")
  end)

  t.test("changing an active entry's text on the commit day is classified today", function()
    local changed = { "--- log ---", "08:00 planning", "09:00 done" }
    local result = one(TODAY, LOG, changed)
    t.eq(result.classification, "today")
    t.eq(result.log_days, { COMMIT_DAY })
    t.eq(result.other_days, {})
  end)

  t.test("adding a #tag or a => mapping to an active entry is a log change", function()
    local tagged = { "--- log ---", "08:00 plan #ClientA", "09:00 done" }
    t.eq(one(TODAY, LOG, tagged).classification, "today")
    local mapped = { "--- log ---", "08:00 plan => Big Task", "09:00 done" }
    t.eq(one(TODAY, LOG, mapped).classification, "today")
  end)

  t.test("changing an entry time on another day is classified other-day", function()
    local changed = { "--- log ---", "08:00 plan", "10:00 done" }
    local result = one(YESTERDAY, LOG, changed)
    t.eq(result.classification, "other-day")
    t.eq(result.other_days, { "2026-05-17" })
    t.eq(result.log_days, { "2026-05-17" })
  end)

  t.test(
    "a commit touching today and another day is other-day, listing only the other day",
    function()
      local result = audit.classify({
        {
          path = TODAY,
          old_lines = LOG,
          new_lines = { "--- log ---", "08:00 planning", "09:00 done" },
        },
        {
          path = YESTERDAY,
          old_lines = LOG,
          new_lines = { "--- log ---", "08:00 plan", "10:00 done" },
        },
      }, COMMIT_DAY)
      t.eq(result.classification, "other-day")
      t.eq(result.log_days, { "2026-05-17", "2026-05-18" })
      t.eq(result.other_days, { "2026-05-17" })
    end
  )

  t.test("adding or deleting another day's log file is an other-day log change", function()
    t.eq(one("2026-05-15.day", {}, LOG).classification, "other-day") -- added
    t.eq(one("2026-05-16.day", LOG, {}).classification, "other-day") -- deleted
  end)

  t.test("adding a new day file dated the commit day is classified today", function()
    t.eq(one(TODAY, {}, LOG).classification, "today")
  end)

  t.test("an edit to a non-active earlier log block is only notes", function()
    local two_logs = {
      "--- log ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- log ---",
      "10:00 review",
      "11:00 done",
    }
    local first_edited = {
      "--- log ---",
      "08:00 planning", -- earlier (non-active) log
      "09:00 done",
      "",
      "--- log ---",
      "10:00 review",
      "11:00 done",
    }
    t.eq(one(TODAY, two_logs, first_edited).classification, "notes")
  end)

  t.test("a log change left with a daylog problem sets needs_review", function()
    local reversed = { "--- log ---", "09:00 plan", "08:00 done" } -- unordered timestamps
    local result = one(TODAY, LOG, reversed)
    t.eq(result.needs_review, true)
    t.ok(#result.reasons > 0, "a reason is recorded")
  end)

  t.test("changes to non-day files are ignored", function()
    local result = audit.classify({
      { path = "README.md", old_lines = { "a" }, new_lines = { "b" } },
      { path = "notes/2026.md", old_lines = {}, new_lines = { "x" } },
    }, COMMIT_DAY)
    t.eq(result.classification, "notes")
    t.eq(result.log_days, {})
  end)
end
