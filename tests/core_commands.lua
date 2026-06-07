return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_captured_notify = helpers.with_captured_notify
  local with_mocked_date = helpers.with_mocked_date

  helpers.setup_worklog()

  t.test("WorklogRefresh rebuilds a stale summary and is a no-op when current", function()
    t.reset({
      "--- worklog ---",
      "08:00 plan",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "0.50h (+0m) plan",
      "",
      "--- totals ---",
      "0.50h (+0m) workday",
    })

    vim.cmd("WorklogRefresh")
    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 plan",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) plan",
      "",
      "--- totals ---",
      "2.00h (+0m) workday",
    })

    -- Running again leaves the now-current summary untouched.
    vim.cmd("WorklogRefresh")
    t.eq(t.get_lines()[6], "2.00h (+0m) plan")
  end)

  local function has_unordered_diagnostic()
    for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
      if diagnostic.message:match("unordered timestamps") then
        return true
      end
    end

    return false
  end

  t.test("WorklogRefresh reports an out-of-order worklog as a diagnostic", function()
    t.reset({
      "--- worklog ---",
      "09:00 later",
      "08:00 earlier",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "0.50h (+0m) later",
      "",
      "--- totals ---",
      "0.50h (+0m) workday",
    })
    local before = t.get_lines()

    vim.cmd("WorklogRefresh")
    t.ok(has_unordered_diagnostic(), "expected an unordered-timestamps diagnostic")

    -- The invalid worklog's summary is left untouched rather than churned.
    t.eq(t.get_lines(), before)
  end)

  t.test("WorklogRefresh reports an out-of-order worklog with no summary", function()
    t.reset({
      "--- worklog ---",
      "08:00 input 1",
      "07:10 input 2",
    })

    vim.cmd("WorklogRefresh")
    t.ok(has_unordered_diagnostic(), "expected a diagnostic even without a summary")
  end)

  t.test("WorklogOrder clears the out-of-order diagnostic", function()
    t.reset({
      "--- worklog ---",
      "09:00 later",
      "08:00 earlier",
      "10:00 done",
    })

    vim.cmd("WorklogRefresh")
    t.ok(has_unordered_diagnostic(), "expected a diagnostic before fixing")

    -- Fixing via :WorklogOrder must clear the diagnostic on its own: a command
    -- edit does not fire the auto-refresh autocmds, so the command refreshes the
    -- diagnostics itself.
    vim.cmd("WorklogOrder")
    t.ok(not has_unordered_diagnostic(), "WorklogOrder should clear the diagnostic")
  end)

  t.test("worklog order rewrites all worklog blocks", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:30 later",
      "note a",
      "08:00 earlier #sales",
      "note b",
      "",
      "--- summary q=15 d=dec ---",
      "x",
      "",
      "--- worklog #internal @home ---",
      "11:00 tea",
      "10:00 coffee @client",
      "12:00 done #internal @home",
    })

    vim.cmd("WorklogOrder")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 earlier #sales",
      "note b",
      "08:30 later #ProjectOrion",
      "note a",
      "--- summary q=15 d=dec ---",
      "x",
      "",
      "--- worklog #internal @home ---",
      "10:00 coffee @client",
      "11:00 tea @home",
      "12:00 done",
    })
  end)

  t.test("copy uses latest active worklog and normalizes items", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "x",
      "",
      "--- worklog #sales @client ---",
      "11:00 tea #sales @client",
      "note tea",
      "",
      "12:00",
    })

    vim.cmd("WorklogCopy")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "x",
      "",
      "--- worklog #sales @client ---",
      "11:00 tea #sales @client",
      "note tea",
      "",
      "12:00",
      "",
      "--- worklog #sales @client ---",
      "11:00 tea",
      "note tea",
      "12:00",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) tea",
      "",
      "--- tags ---",
      "1.00h (+0m) #sales",
      "",
      "--- locations ---",
      "1.00h (+0m) @client",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })
  end)

  t.test("copy preserves explicit quantize on the active worklog header", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- worklog #sales @client q=30 ---",
      "11:00 tea",
      "12:00",
    })

    vim.cmd("WorklogCopy")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- worklog #sales @client q=30 ---",
      "11:00 tea",
      "12:00",
      "",
      "--- worklog #sales @client q=30 ---",
      "11:00 tea",
      "12:00",
      "",
      "--- summary q=30 d=dec ---",
      "1.00h (+0m) tea",
      "",
      "--- tags ---",
      "1.00h (+0m) #sales",
      "",
      "--- locations ---",
      "1.00h (+0m) @client",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })
  end)

  t.test("copy preserves clear tokens needed to return to nil metadata", function()
    t.reset({
      "--- worklog ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
    })

    vim.cmd("WorklogCopy")
    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
      "",
      "--- worklog ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) break",
      "1.00h (+0m) resume",
      "",
      "--- tags ---",
      "1.00h (+0m) #ooo",
      "1.00h (+0m) (untagged)",
      "",
      "--- locations ---",
      "1.00h (+0m) @home",
      "1.00h (+0m) (no location)",
      "",
      "--- totals ---",
      "2.00h (+0m) activity",
      "1.00h (+0m) workday",
    })
  end)

  t.test("copy does not preserve clear-only header metadata", function()
    t.reset({
      "--- worklog #- @- ---",
      "08:00 plan",
      "09:00 client #ClientA @home",
      "10:00 reset #- @-",
      "11:00 done",
    })

    vim.cmd("WorklogCopy")
    t.eq(t.get_lines(), {
      "--- worklog #- @- ---",
      "08:00 plan",
      "09:00 client #ClientA @home",
      "10:00 reset #- @-",
      "11:00 done",
      "",
      "--- worklog ---",
      "08:00 plan",
      "09:00 client #ClientA @home",
      "10:00 reset #- @-",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
      "1.00h (+0m) client",
      "1.00h (+0m) reset",
      "",
      "--- tags ---",
      "2.00h (+0m) (untagged)",
      "1.00h (+0m) #ClientA",
      "",
      "--- locations ---",
      "2.00h (+0m) (no location)",
      "1.00h (+0m) @home",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    })
  end)

  t.test("repeat inserts into explicit worklog block containing cursor", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:04 bake strudel",
      "08:21 negotiate with goose",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.93h (+0m) activity",
      "",
      "--- worklog #sales @client ---",
      "11:00 tea",
      "12:00",
    })
    t.set_cursor(10, 0)

    with_mocked_date("14:37", function()
      vim.cmd("WorklogRepeat")
    end)

    t.eq(t.get_lines()[12], "14:37 tea")
  end)

  t.test("repeat re-emits sticky metadata when insertion state changed", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "08:15 break #ooo",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    with_mocked_date("08:30", function()
      vim.cmd("WorklogRepeat")
    end)

    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "08:15 break #ooo",
      "08:30 first #ProjectOrion",
      "09:00 done #ooo",
    })
  end)

  t.test("repeat keeps untagged entries untagged without sticky header metadata", function()
    t.reset({
      "--- worklog ---",
      "08:00 first",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    with_mocked_date("08:30", function()
      vim.cmd("WorklogRepeat")
    end)

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 first",
      "08:30 first",
      "09:00 done",
    })
  end)

  t.test(
    "repeat emits clear tokens when replaying nil metadata after sticky values were set",
    function()
      t.reset({
        "--- worklog ---",
        "08:00 first",
        "08:15 break #ooo @home",
        "09:00 done",
      })
      t.set_cursor(2, 0)

      with_mocked_date("08:30", function()
        vim.cmd("WorklogRepeat")
      end)

      t.eq(t.get_lines(), {
        "--- worklog ---",
        "08:00 first",
        "08:15 break #ooo @home",
        "08:30 first #- @-",
        "09:00 done #ooo @home",
      })
    end
  )

  t.test("insert orders into explicit worklog block after equal timestamps", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "08:00 second",
      "09:00 done",
    })
    t.set_cursor(1, 0)

    with_mocked_date("08:00", function()
      vim.cmd("WorklogInsert")
    end)

    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "08:00 second",
      "08:00 ",
      "09:00 done",
    })
  end)

  t.test("insert works from a later worklog header", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 raw",
      "09:00 done",
      "",
      "--- worklog #sales @client ---",
      "10:00 first",
      "11:00 done",
    })
    t.set_cursor(5, 0)

    with_mocked_date("10:30", function()
      vim.cmd("WorklogInsert")
    end)

    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 raw",
      "09:00 done",
      "",
      "--- worklog #sales @client ---",
      "10:00 first",
      "10:30 ",
      "11:00 done",
    })
  end)

  t.test("insert warns when no explicit worklog exists", function()
    t.reset({
      "08:00 raw",
      "09:00 done",
    })
    t.set_cursor(1, 0)

    vim.cmd("WorklogInsert")
    t.eq(t.get_lines(), {
      "08:00 raw",
      "09:00 done",
    })
  end)

  t.test("repeat ignores non-worklog lines", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 task",
      "09:00",
      "",
      "--- summary q=15 d=dec ---",
      "0.00h (+0m) task",
    })
    t.set_cursor(5, 0)

    vim.cmd("WorklogRepeat")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 task",
      "09:00",
      "",
      "--- summary q=15 d=dec ---",
      "0.00h (+0m) task",
    })
  end)

  t.test("invalid multiple trailing tags block commands", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan #sales #meeting",
      "09:00 done",
    })

    vim.cmd("WorklogCopy")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan #sales #meeting",
      "09:00 done",
    })
  end)

  t.test("worklog order emits clear tokens when sorting needs them and warns", function()
    t.reset({
      "--- worklog ---",
      "09:00 done",
      "08:00 plan #sales",
    })

    with_captured_notify(function(messages)
      vim.cmd("WorklogOrder")

      t.eq(messages, {
        {
          message = "worklog: ordering set the tag/location of order-dependent entries; review: 09:00 done",
          level = vim.log.levels.WARN,
        },
      })
    end)

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 plan #sales",
      "09:00 done #-",
    })
  end)

  t.test("worklog log marks the source entry behind an unrounded summary row", function()
    t.reset({
      "--- worklog ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
    })
    t.set_cursor(6, 0)

    vim.cmd("WorklogLog")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 implementation !L",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation !L",
      "",
      "--- logged ---",
      "1.00h (+0m) logged",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })
  end)

  t.test("worklog log marks the source entry behind a quantized summary row", function()
    t.reset({
      "--- worklog q=30 ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
    })
    t.set_cursor(6, 0)

    vim.cmd("WorklogLog")

    t.eq(t.get_lines(), {
      "--- worklog q=30 ---",
      "08:00 implementation !L",
      "09:00 done",
      "",
      "--- summary q=30 d=dec ---",
      "1.00h (+0m) implementation !L",
      "",
      "--- logged ---",
      "1.00h (+0m) logged",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })
  end)

  t.test("worklog log unmarks an already logged summary row", function()
    t.reset({
      "--- worklog ---",
      "08:00 implementation !L",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation !L",
    })
    t.set_cursor(6, 0)

    vim.cmd("WorklogLog")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })
  end)

  t.test(
    "worklog log regression: multi-edit summary-refresh applies correctly through the real command path",
    function()
      -- Exercises the full :WorklogLog -> apply_result path with the reported
      -- bug case. The fix returns a summary-group refresh edit (higher rows)
      -- before source-entry edits (lower rows); this test proves apply_result
      -- applies them in that order without index drift.
      t.reset({
        "--- worklog #someproject @office ---",
        "08:00 versions",
        "09:00 stand",
        "09:20 versions",
        "10:12 folksy",
        "    what is he talking about    ",
        "10:17 Q1 features",
        "11:01 versions",
        "",
        "--- summary q=15 d=dec ---",
        "2.00h (-8m) versions",
        "0.75h (-1m) Q1 features",
        "0.25h (+5m) stand",
        "0.00h (+5m) folksy",
        "",
        "--- tags ---",
        "3.00h (+1m) #someproject",
        "",
        "--- locations ---",
        "3.00h (+1m) @office",
        "",
        "--- totals ---",
        "3.00h (+1m) workday",
      })
      t.set_cursor(12, 0)

      vim.cmd("WorklogLog")

      t.eq(t.get_lines(), {
        "--- worklog #someproject @office ---",
        "08:00 versions",
        "09:00 stand",
        "09:20 versions",
        "10:12 folksy",
        "    what is he talking about    ",
        "10:17 Q1 features !L",
        "11:01 versions",
        "",
        "--- summary q=15 d=dec ---",
        "2.00h (-8m) versions",
        "0.75h (-1m) Q1 features !L",
        "0.25h (+5m) stand",
        "0.00h (+5m) folksy",
        "",
        "--- tags ---",
        "3.00h (+1m) #someproject",
        "",
        "--- locations ---",
        "3.00h (+1m) @office",
        "",
        "--- logged ---",
        "0.75h (-1m) logged",
        "2.25h (+2m) unlogged",
        "",
        "--- totals ---",
        "3.00h (+1m) workday",
      })
    end
  )
end
