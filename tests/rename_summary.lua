return function(t)
  local rename_summary = require("daylog.usecases.rename_summary")

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

  local function has(lines, line)
    for _, l in ipairs(lines) do
      if l == line then
        return true
      end
    end
    return false
  end

  t.test("rename refuses an activity summary row -- :DaylogMap relabels for the report", function()
    local _, err = rename_summary.run({
      "--- log ---",
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

    t.eq(err, rename_summary.REFUSE_ACTIVITY_ROW)
  end)

  t.test("rename sanitizes trailing metadata in an entry's new text", function()
    -- Rename acts on the entry under the cursor (row 2), not the summary row.
    local out = rename({
      "--- log ---",
      "08:00 deploy",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) deploy",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    }, 2, "deploy #urgent")

    -- The trailing #urgent is parenthesized so it cannot become entry metadata.
    t.eq(out[2], "08:00 deploy (#urgent)")
    t.eq(out[7], "1.00h (+0m) deploy (#urgent)")
  end)

  t.test("rename a tag row renames the header token and explicit entries", function()
    local out = rename({
      "--- log #ClientA @office ---",
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
      "--- log #Globex @office ---",
      "08:00 planning",
      "10:00 meeting #internal",
      "11:00 done #Globex",
      "",
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
      "--- log ---",
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
      "--- log ---",
      "08:00 setup",
      "09:00 build #alpha",
      "10:00 test",
      "11:00 done",
      "",
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
      "--- log @office ---",
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
      "--- log @hq ---",
      "08:00 planning",
      "10:00 implementation @home",
      "11:00 done",
      "",
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
      "--- log ---",
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
      "--- log ---",
      "08:00 plan #b",
      "09:00 build #b",
      "10:00 done",
      "",
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
      "--- log ---",
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

  t.test("resolve refuses an activity summary row", function()
    local _, err = rename_summary.resolve({
      "--- log #proj ---",
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

    t.eq(err, rename_summary.REFUSE_ACTIVITY_ROW)
  end)

  t.test("rename refuses a totals row", function()
    local _, err = rename_summary.run({
      "--- log ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    }, 9, "whatever")

    t.eq(err, "daylog: a totals row cannot be renamed")
  end)

  t.test("rename refuses the (untagged) tag group", function()
    local _, err = rename_summary.run({
      "--- log ---",
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

    t.eq(err, "daylog: the (untagged) group cannot be renamed; tag the entries first")
  end)

  t.test("rename rejects an invalid tag name", function()
    local _, err = rename_summary.run({
      "--- log #proj ---",
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

    t.eq(err, "daylog: a tag or location name must be letters, digits, underscores, or hyphens")
  end)

  t.test("rename rejects empty activity text on an entry", function()
    local _, err = rename_summary.run({
      "--- log ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
    }, 2, "   ")

    t.eq(err, "daylog: the activity text cannot be empty")
  end)

  t.test("rename refuses the same name", function()
    local _, err = rename_summary.run({
      "--- log #proj ---",
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

    t.eq(err, "daylog: the new name matches the current name")
  end)

  t.test("rename refuses when the cursor is not on an entry or a summary row", function()
    -- Row 1 is the log header: neither a summary row nor an entry.
    local _, err = rename_summary.run({
      "--- log ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
    }, 1, "whatever")

    t.eq(err, rename_summary.NOT_A_ROW)
  end)

  t.test("rename on an entry renames only that entry, not its same-named siblings", function()
    local out = rename({
      "--- log ---",
      "08:00 alpha",
      "09:00 alpha",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) alpha",
    }, 2, "beta") -- cursor on the first "alpha" entry

    -- Only the cursor's entry changes; its sibling keeps the old text.
    t.eq(out[2], "08:00 beta")
    t.eq(out[3], "09:00 alpha")
    -- The summary splits into the two one-hour groups.
    t.ok(has(out, "1.00h (+0m) beta"), "the renamed entry is its own group")
    t.ok(has(out, "1.00h (+0m) alpha"), "the sibling stays under alpha")
    t.ok(not has(out, "2.00h (+0m) alpha"), "they no longer share a row")
  end)

  t.test(
    "rename on an entry resolves to its own text with the other activities as candidates",
    function()
      local target = rename_summary.resolve({
        "--- log ---",
        "08:00 alpha",
        "09:00 gamma",
        "10:00 done",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) alpha",
        "1.00h (+0m) gamma",
      }, 2) -- cursor on the "alpha" entry

      t.eq(target.kind, "item")
      t.eq(target.current, "alpha")
      t.eq(target.candidates, { "gamma" })
    end
  )

  t.test("rename on an entry can merge just that entry into an existing activity", function()
    local out = rename({
      "--- log ---",
      "08:00 alpha",
      "09:00 alpha",
      "10:00 gamma",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) alpha",
      "1.00h (+0m) gamma",
    }, 2, "gamma") -- merge the first alpha into gamma

    t.eq(out[2], "08:00 gamma")
    t.eq(out[3], "09:00 alpha")
    t.eq(out[4], "10:00 gamma")
    t.ok(has(out, "1.00h (+0m) alpha"), "the other alpha entry stays")
    t.ok(has(out, "2.00h (+0m) gamma"), "the renamed entry merged into gamma")
  end)

  t.test("rename on an aliased entry edits the description and keeps the alias", function()
    local out = rename({
      "--- log ---",
      "08:00 fix login => BUG-1",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) BUG-1",
    }, 2, "investigate timeout")

    t.eq(out[2], "08:00 investigate timeout => BUG-1")
    t.eq(out[7], "1.00h (+0m) BUG-1")
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
      "--- log #ClientA ---",
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
    t.eq(out[9], "2.00h (+0m) coding")
  end)

  t.test("run_by_value renames a tag everywhere it is effective", function()
    local out = rename_by_value({
      "--- log #ClientA ---",
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

    t.eq(out[1], "--- log #ClientB ---")
    t.eq(out[10], "1.00h (+0m) #ClientB")
  end)

  t.test("run_by_value returns nil with no error when the value is absent", function()
    local result, err = rename_summary.run_by_value({
      "--- log ---",
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

  t.test("run_by_value surfaces an error when the log is invalid", function()
    local _, err = rename_summary.run_by_value({
      "--- log ---",
      "09:00 later",
      "08:00 earlier",
    }, { kind = "item", current = "later", tag = nil }, "whatever")

    t.ok(err ~= nil, "an invalid log yields an error")
  end)

  t.test("rename refuses a mapped activity row (descriptions kept; :DaylogMap relabels)", function()
    local lines = {
      "--- log ---",
      "08:00 fix login => BUG-1",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) BUG-1",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    }

    -- The row is labeled by the alias BUG-1; a rename (which edits descriptions) would
    -- silently overwrite "fix login", so the row is refused. Both run and resolve refuse.
    local _, run_err = rename_summary.run(lines, 6, "investigate timeout")
    t.eq(run_err, rename_summary.REFUSE_ACTIVITY_ROW)

    local _, resolve_err = rename_summary.resolve(lines, 6)
    t.eq(resolve_err, rename_summary.REFUSE_ACTIVITY_ROW)
  end)

  t.test("rename on an entry leaves a same-named closing entry untouched", function()
    -- The closing "10:00 alpha" shares the cursor entry's text but is a different entry;
    -- an entry rename must touch only the entry under the cursor.
    local out = rename({
      "--- log ---",
      "08:00 alpha",
      "09:00 beta",
      "10:00 alpha", -- the closing entry, same text as the cursor entry
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) alpha",
      "1.00h (+0m) beta",
      "",
      "--- totals ---",
      "2.00h (+0m) workday",
    }, 2, "gamma") -- cursor on the first "alpha"

    t.eq(out[2], "08:00 gamma")
    t.eq(out[4], "10:00 alpha") -- the closing entry keeps its text
  end)
end
