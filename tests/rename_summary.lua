return function(t)
  local rename_summary = require("worklog.usecases.rename_summary")

  -- Apply an edit script to a line list exactly as the shell does
  -- (nvim_buf_set_lines with 0-based, end-exclusive indexes). The usecase returns
  -- edits highest-row-first, so applying them in order never shifts a later edit.
  local function apply(lines, result)
    local out = {}
    for i, line in ipairs(lines) do
      out[i] = line
    end

    for _, edit in ipairs(result.edits) do
      local next_out = {}
      for i = 1, edit.start_index do
        next_out[#next_out + 1] = out[i]
      end
      for _, line in ipairs(edit.lines) do
        next_out[#next_out + 1] = line
      end
      for i = edit.end_index + 1, #out do
        next_out[#next_out + 1] = out[i]
      end
      out = next_out
    end

    return out
  end

  local function rename(lines, cursor_row, new_value)
    local result, err = rename_summary.run(lines, cursor_row, new_value)
    if not result then
      return nil, err
    end
    return apply(lines, result)
  end

  t.test("rename an activity row rewrites its source entries and the summary", function()
    local out = rename({
      "--- worklog ---",
      "08:00 implementation",
      "09:00 meeting",
      "10:00 implementation",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) implementation",
      "1.00h (+0m) meeting",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    }, 8, "coding")

    t.eq(out, {
      "--- worklog ---",
      "08:00 coding",
      "09:00 meeting",
      "10:00 coding",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) coding",
      "1.00h (+0m) meeting",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    })
  end)

  t.test("renaming an activity sanitizes trailing metadata in the new text", function()
    local out = rename({
      "--- worklog ---",
      "08:00 deploy",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) deploy",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    }, 6, "deploy #urgent")

    -- The trailing #urgent is parenthesized so it cannot become entry metadata.
    t.eq(out[2], "08:00 deploy (#urgent)")
    t.eq(out[6], "1.00h (+0m) deploy (#urgent)")
  end)

  t.test("rename a tag row renames the header token and explicit entries", function()
    local out = rename({
      "--- worklog #ClientA @office ---",
      "08:00 planning",
      "10:00 meeting #internal",
      "11:00 done #ClientA",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) planning",
      "1.00h (+0m) meeting",
      "",
      "--- tags ---",
      "2.00h (+0m) #ClientA",
      "1.00h (+0m) #internal",
      "",
      "--- locations ---",
      "3.00h (+0m) @office",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    }, 11, "Globex")

    t.eq(out, {
      "--- worklog #Globex @office ---",
      "08:00 planning",
      "10:00 meeting #internal",
      "11:00 done #Globex",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) planning",
      "1.00h (+0m) meeting",
      "",
      "--- tags ---",
      "2.00h (+0m) #Globex",
      "1.00h (+0m) #internal",
      "",
      "--- locations ---",
      "3.00h (+0m) @office",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    })
  end)

  t.test("renaming a tag rewrites only the explicit token, not inheriting entries", function()
    -- #proj is explicit on "build" and inherited by "test"/"done"; renaming it must
    -- touch only the "build" line and leave the inheriting lines as they are.
    local out = rename({
      "--- worklog ---",
      "08:00 setup",
      "09:00 build #proj",
      "10:00 test",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) setup",
      "1.00h (+0m) build",
      "1.00h (+0m) test",
      "",
      "--- tags ---",
      "2.00h (+0m) #proj",
      "1.00h (+0m) (untagged)",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    }, 13, "alpha")

    t.eq(out, {
      "--- worklog ---",
      "08:00 setup",
      "09:00 build #alpha",
      "10:00 test",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) setup",
      "1.00h (+0m) build",
      "1.00h (+0m) test",
      "",
      "--- tags ---",
      "2.00h (+0m) #alpha",
      "1.00h (+0m) (untagged)",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    })
  end)

  t.test("rename a location row renames the header token and the summary", function()
    local out = rename({
      "--- worklog @office ---",
      "08:00 planning",
      "10:00 implementation @home",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) planning",
      "1.00h (+0m) implementation",
      "",
      "--- locations ---",
      "2.00h (+0m) @office",
      "1.00h (+0m) @home",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    }, 11, "hq")

    t.eq(out, {
      "--- worklog @hq ---",
      "08:00 planning",
      "10:00 implementation @home",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) planning",
      "1.00h (+0m) implementation",
      "",
      "--- locations ---",
      "2.00h (+0m) @hq",
      "1.00h (+0m) @home",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    })
  end)

  t.test("renaming a tag to an existing tag merges them", function()
    local out = rename({
      "--- worklog ---",
      "08:00 plan #a",
      "09:00 build #b",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "1.00h (+0m) build",
      "",
      "--- tags ---",
      "1.00h (+0m) #a",
      "1.00h (+0m) #b",
      "",
      "--- totals ---",
      "2.00h (+0m) workday",
    }, 11, "b")

    t.eq(out, {
      "--- worklog ---",
      "08:00 plan #b",
      "09:00 build #b",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "1.00h (+0m) build",
      "",
      "--- tags ---",
      "2.00h (+0m) #b",
      "",
      "--- totals ---",
      "2.00h (+0m) workday",
    })
  end)

  t.test("resolve returns the other tags as merge candidates", function()
    local target = rename_summary.resolve({
      "--- worklog ---",
      "08:00 plan #a",
      "09:00 build #b",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "1.00h (+0m) build",
      "",
      "--- tags ---",
      "1.00h (+0m) #a",
      "1.00h (+0m) #b",
      "",
      "--- totals ---",
      "2.00h (+0m) workday",
    }, 11)

    t.eq(target.kind, "tag")
    t.eq(target.current, "a")
    t.eq(target.candidates, { "b" })
  end)

  t.test("resolve returns the same-tag activities as merge candidates", function()
    local target = rename_summary.resolve({
      "--- worklog #proj ---",
      "08:00 plan",
      "09:00 build",
      "10:00 review",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "1.00h (+0m) build",
      "1.00h (+0m) review",
      "",
      "--- tags ---",
      "3.00h (+0m) #proj",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    }, 8)

    t.eq(target.kind, "item")
    t.eq(target.current, "plan")
    t.eq(target.candidates, { "build", "review" })
  end)

  t.test("rename refuses a totals row", function()
    local _, err = rename_summary.run({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    }, 9, "whatever")

    t.eq(err, "worklog: a totals row cannot be renamed")
  end)

  t.test("rename refuses the (untagged) tag group", function()
    local _, err = rename_summary.run({
      "--- worklog ---",
      "08:00 plan #proj",
      "09:00 admin #-",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "1.00h (+0m) admin",
      "",
      "--- tags ---",
      "1.00h (+0m) #proj",
      "1.00h (+0m) (untagged)",
      "",
      "--- totals ---",
      "2.00h (+0m) workday",
    }, 12, "newtag")

    t.eq(err, "worklog: the (untagged) group cannot be renamed; tag the entries first")
  end)

  t.test("rename rejects an invalid tag name", function()
    local _, err = rename_summary.run({
      "--- worklog #proj ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "",
      "--- tags ---",
      "1.00h (+0m) #proj",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    }, 9, "bad name")

    t.eq(err, "worklog: a tag or location name must be letters, digits, underscores, or hyphens")
  end)

  t.test("rename rejects empty activity text", function()
    local _, err = rename_summary.run({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
    }, 6, "   ")

    t.eq(err, "worklog: the activity text cannot be empty")
  end)

  t.test("rename refuses the same name", function()
    local _, err = rename_summary.run({
      "--- worklog #proj ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "",
      "--- tags ---",
      "1.00h (+0m) #proj",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    }, 9, "proj")

    t.eq(err, "worklog: the new name matches the current name")
  end)

  t.test("rename refuses when the cursor is not on a summary row", function()
    local _, err = rename_summary.run({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
    }, 2, "whatever")

    t.eq(err, "worklog: put the cursor on a summary item, tag, or location row to rename it")
  end)

  local function rename_by_value(lines, target, new_value)
    local result, err = rename_summary.run_by_value(lines, target, new_value)
    if not result then
      return nil, err
    end
    return apply(lines, result)
  end

  t.test("run_by_value renames an activity found by text and tag", function()
    local out = rename_by_value({
      "--- worklog #ClientA ---",
      "08:00 implementation",
      "09:00 meeting",
      "10:00 implementation",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) implementation",
      "1.00h (+0m) meeting",
      "",
      "--- tags ---",
      "3.00h (+0m) #ClientA",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    }, { kind = "item", current = "implementation", tag = "ClientA" }, "coding")

    t.eq(out[2], "08:00 coding")
    t.eq(out[4], "10:00 coding")
    t.eq(out[8], "2.00h (+0m) coding")
  end)

  t.test("run_by_value renames a tag everywhere it is effective", function()
    local out = rename_by_value({
      "--- worklog #ClientA ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "",
      "--- tags ---",
      "1.00h (+0m) #ClientA",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    }, { kind = "tag", current = "ClientA" }, "ClientB")

    t.eq(out[1], "--- worklog #ClientB ---")
    t.eq(out[9], "1.00h (+0m) #ClientB")
  end)

  t.test("run_by_value returns nil with no error when the value is absent", function()
    local result, err = rename_summary.run_by_value({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    }, { kind = "item", current = "nonexistent", tag = nil }, "whatever")

    t.eq(result, nil)
    t.eq(err, nil)
  end)

  t.test("run_by_value surfaces an error when the worklog is invalid", function()
    local _, err = rename_summary.run_by_value({
      "--- worklog ---",
      "09:00 later",
      "08:00 earlier",
    }, { kind = "item", current = "later", tag = nil }, "whatever")

    t.ok(err ~= nil, "an invalid worklog yields an error")
  end)
end
