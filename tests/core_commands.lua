return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_mocked_date = helpers.with_mocked_date

  helpers.setup_worklog()

  t.test("summarize blocks on unordered worklog", function()
    t.reset({
      "--- worklog #ProjectOrion ---",
      "08:30 later",
      "08:00 earlier #sales",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion ---",
      "08:30 later",
      "08:00 earlier #sales",
      "09:00 done",
    })
  end)

  t.test("WorklogRefresh rebuilds a stale summary and is a no-op when current", function()
    t.reset({
      "--- worklog ---",
      "08:00 plan",
      "10:00 done",
      "",
      "--- summary exact ---",
      "0.50h plan",
      "",
      "--- totals exact ---",
      "0.50h workday",
    })

    vim.cmd("WorklogRefresh")
    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 plan",
      "10:00 done",
      "",
      "--- summary exact ---",
      "2.00h plan",
      "",
      "--- totals exact ---",
      "2.00h workday",
    })

    -- Running again leaves the now-current summary untouched.
    vim.cmd("WorklogRefresh")
    t.eq(t.get_lines()[6], "2.00h plan")
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
      "--- summary exact ---",
      "0.50h later",
      "",
      "--- totals exact ---",
      "0.50h workday",
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

  t.test("equal timestamps are allowed in summarize", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 same",
      "08:00 same again @client",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")
    local lines = t.get_lines()

    t.eq(lines[6], "--- summary exact ---")
    t.eq(lines[7], "1.00h same again")
    t.eq(lines[8], "0.00h same")
    t.eq(lines[10], "--- tags exact ---")
    t.eq(lines[11], "1.00h #ProjectOrion")
    t.eq(lines[13], "--- locations exact ---")
    t.eq(lines[14], "1.00h @client")
    t.eq(lines[15], "0.00h @office")
    t.eq(lines[18], "1.00h workday")
  end)

  t.test("worklog order rewrites all worklog blocks", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:30 later",
      "note a",
      "08:00 earlier #sales",
      "note b",
      "",
      "--- summary exact ---",
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
      "--- summary exact ---",
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
      "--- summary exact ---",
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
      "--- summary exact ---",
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
    })
  end)

  t.test("copy preserves explicit quantize on the active worklog header", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- worklog #sales @client quantize=30 ---",
      "11:00 tea",
      "12:00",
    })

    vim.cmd("WorklogCopy")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- worklog #sales @client quantize=30 ---",
      "11:00 tea",
      "12:00",
      "",
      "--- worklog #sales @client quantize=30 ---",
      "11:00 tea",
      "12:00",
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
    })
  end)

  t.test("repeat inserts into explicit worklog block containing cursor", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:04 bake strudel",
      "08:21 negotiate with goose",
      "10:00 done",
      "",
      "--- summary exact ---",
      "1.93h activity",
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
      "09:00 done",
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
        "09:00 done",
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

  t.test("worklog check does not modify the buffer or cursor", function()
    t.reset({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
    })
    t.set_cursor(2, 3)

    vim.cmd("WorklogCheck")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
    })
    t.eq(vim.api.nvim_win_get_cursor(0), { 2, 3 })
  end)

  t.test(
    "WorklogCheck publishes diagnostics for an invalid buffer and clears them when valid",
    function()
      t.reset({
        "--- worklog ---",
        "09:00 later",
        "08:00 earlier",
        "10:00 done",
      })

      vim.cmd("WorklogCheck")
      t.ok(has_unordered_diagnostic(), "WorklogCheck should publish a diagnostic for the problem")

      -- A valid buffer publishes none.
      t.reset({
        "--- worklog ---",
        "08:00 plan",
        "09:00 done",
      })
      vim.cmd("WorklogCheck")
      t.eq(vim.diagnostic.get(0), {})
    end
  )

  t.test("summaries show untagged and no location buckets without header metadata", function()
    t.reset({
      "--- worklog ---",
      "08:00 plan",
      "08:15 call #sales @client",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 plan",
      "08:15 call #sales @client",
      "09:00 done",
      "",
      "--- summary exact ---",
      "0.75h call",
      "0.25h plan",
      "",
      "--- tags exact ---",
      "0.75h #sales",
      "0.25h (untagged)",
      "",
      "--- locations exact ---",
      "0.75h @client",
      "0.25h (no location)",
      "",
      "--- totals exact ---",
      "1.00h workday",
    })
  end)

  t.test("summaries split logged and unlogged work on the same activity", function()
    t.reset({
      "--- worklog ---",
      "08:00 implementation !L",
      "09:00 implementation",
      "10:00 done",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 implementation !L",
      "09:00 implementation",
      "10:00 done",
      "",
      "--- summary exact ---",
      "1.00h implementation !L",
      "1.00h implementation",
      "",
      "--- logged exact ---",
      "1.00h logged",
      "1.00h unlogged",
      "",
      "--- totals exact ---",
      "2.00h workday",
    })
  end)

  t.test(
    "summaries keep same-text different-tag rows adjacent and sort by combined duration",
    function()
      t.reset({
        "--- worklog ---",
        "08:00 meeting #ClientA",
        "09:00 implementation #ClientA",
        "12:00 meeting #internal",
        "14:00 done",
      })

      vim.cmd("WorklogSummarize")

      t.eq(t.get_lines(), {
        "--- worklog ---",
        "08:00 meeting #ClientA",
        "09:00 implementation #ClientA",
        "12:00 meeting #internal",
        "14:00 done",
        "",
        "--- summary exact ---",
        "2.00h meeting #internal",
        "1.00h meeting #ClientA",
        "3.00h implementation",
        "",
        "--- tags exact ---",
        "4.00h #ClientA",
        "2.00h #internal",
        "",
        "--- totals exact ---",
        "6.00h workday",
      })
    end
  )

  t.test("summaries omit placeholder-only metadata sections", function()
    t.reset({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h plan",
      "",
      "--- totals exact ---",
      "1.00h workday",
    })
  end)

  t.test("summaries show cleared metadata as placeholder buckets", function()
    t.reset({
      "--- worklog ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
      "",
      "--- summary exact ---",
      "1.00h break",
      "1.00h resume",
      "",
      "--- tags exact ---",
      "1.00h #ooo",
      "1.00h (untagged)",
      "",
      "--- locations exact ---",
      "1.00h @home",
      "1.00h (no location)",
      "",
      "--- totals exact ---",
      "2.00h activity",
      "1.00h workday",
    })
  end)

  t.test("active summaries ignore unrelated invalid older worklog blocks", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 broken #sales #meeting",
      "09:00 done",
      "",
      "--- worklog #sales @client ---",
      "10:00 plan",
      "11:00 done",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 broken #sales #meeting",
      "09:00 done",
      "",
      "--- worklog #sales @client ---",
      "10:00 plan",
      "11:00 done",
      "",
      "--- summary exact ---",
      "1.00h plan",
      "",
      "--- tags exact ---",
      "1.00h #sales",
      "",
      "--- locations exact ---",
      "1.00h @client",
      "",
      "--- totals exact ---",
      "1.00h workday",
    })
  end)

  t.test("summaries ignore attached note lines", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "note about planning",
      "08:30 call #sales @client",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "note about planning",
      "08:30 call #sales @client",
      "09:00 done",
      "",
      "--- summary exact ---",
      "0.50h plan",
      "0.50h call",
      "",
      "--- tags exact ---",
      "0.50h #ProjectOrion",
      "0.50h #sales",
      "",
      "--- locations exact ---",
      "0.50h @office",
      "0.50h @client",
      "",
      "--- totals exact ---",
      "1.00h workday",
    })
  end)

  t.test(
    "quantized summaries show untagged and no location buckets without header metadata",
    function()
      t.reset({
        "--- worklog quantize=30 ---",
        "08:00 plan",
        "08:12 call #sales @client",
        "08:30 done",
      })

      vim.cmd("WorklogQuantSum")

      t.eq(t.get_lines(), {
        "--- worklog quantize=30 ---",
        "08:00 plan",
        "08:12 call #sales @client",
        "08:30 done",
        "",
        "--- summary quantized ---",
        "0.50h (-12m) call",
        "0.00h (+12m) plan",
        "",
        "--- tags quantized ---",
        "0.50h (-12m) #sales",
        "0.00h (+12m) (untagged)",
        "",
        "--- locations quantized ---",
        "0.50h (-12m) @client",
        "0.00h (+12m) (no location)",
        "",
        "--- totals quantized ---",
        "0.50h (+0m) workday",
      })
    end
  )

  t.test("quantized summaries omit placeholder-only metadata sections", function()
    t.reset({
      "--- worklog quantize=30 ---",
      "08:00 plan",
      "08:30 done",
    })

    vim.cmd("WorklogQuantSum")

    t.eq(t.get_lines(), {
      "--- worklog quantize=30 ---",
      "08:00 plan",
      "08:30 done",
      "",
      "--- summary quantized ---",
      "0.50h (+0m) plan",
      "",
      "--- totals quantized ---",
      "0.50h (+0m) workday",
    })
  end)

  t.test("quantized summaries split logged and unlogged work on the same activity", function()
    t.reset({
      "--- worklog quantize=30 ---",
      "08:00 implementation !L",
      "08:20 implementation",
      "08:40 done",
    })

    vim.cmd("WorklogQuantSum")

    t.eq(t.get_lines(), {
      "--- worklog quantize=30 ---",
      "08:00 implementation !L",
      "08:20 implementation",
      "08:40 done",
      "",
      "--- summary quantized ---",
      "0.50h (-10m) implementation !L",
      "0.00h (+20m) implementation",
      "",
      "--- logged quantized ---",
      "0.50h (-10m) logged",
      "0.00h (+20m) unlogged",
      "",
      "--- totals quantized ---",
      "0.50h (+10m) workday",
    })
  end)

  t.test("quantized summaries honor active worklog quantization", function()
    t.reset({
      "--- worklog @office quantize=30 ---",
      "08:00 earlier",
      "08:30 done",
      "",
      "--- worklog @office quantize=60 ---",
      "09:00 plan",
      "09:20 call #sales @client",
      "10:00 done",
    })

    vim.cmd("WorklogQuantSum")

    t.eq(t.get_lines(), {
      "--- worklog @office quantize=30 ---",
      "08:00 earlier",
      "08:30 done",
      "",
      "--- worklog @office quantize=60 ---",
      "09:00 plan",
      "09:20 call #sales @client",
      "10:00 done",
      "",
      "--- summary quantized ---",
      "1.00h (-20m) call",
      "0.00h (+20m) plan",
      "",
      "--- tags quantized ---",
      "1.00h (-20m) #sales",
      "0.00h (+20m) (untagged)",
      "",
      "--- locations quantized ---",
      "1.00h (-20m) @client",
      "0.00h (+20m) @office",
      "",
      "--- totals quantized ---",
      "1.00h (+0m) workday",
    })
  end)

  t.test("repeat ignores non-worklog lines", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 task",
      "09:00",
      "",
      "--- summary exact ---",
      "0.00h task",
    })
    t.set_cursor(5, 0)

    vim.cmd("WorklogRepeat")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 task",
      "09:00",
      "",
      "--- summary exact ---",
      "0.00h task",
    })
  end)

  t.test("summaries keep exact tag and location totals and render ooo explicitly", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "08:30 plan #sales @client",
      "09:00 break #ooo",
      "09:15 done #ProjectOrion @office",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "08:30 plan #sales @client",
      "09:00 break #ooo",
      "09:15 done #ProjectOrion @office",
      "",
      "--- summary exact ---",
      "0.50h plan #ProjectOrion",
      "0.50h plan #sales",
      "0.25h break",
      "",
      "--- tags exact ---",
      "0.50h #ProjectOrion",
      "0.50h #sales",
      "0.25h #ooo",
      "",
      "--- locations exact ---",
      "0.75h @client",
      "0.50h @office",
      "",
      "--- totals exact ---",
      "1.25h activity",
      "1.00h workday",
    })
  end)

  t.test("quantsum shows signed exact deltas and explicit metadata", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:04 bake strudel",
      "08:21 negotiate with goose #sales @client",
      "08:33 bake strudel #ProjectOrion @office",
      "08:52 coffee with ghost #ooo @home",
      "09:11 polish trombone #ProjectOrion @office",
      "09:36 bake strudel",
      "10:00 done",
    })

    vim.cmd("WorklogQuantSum")

    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:04 bake strudel",
      "08:21 negotiate with goose #sales @client",
      "08:33 bake strudel #ProjectOrion @office",
      "08:52 coffee with ghost #ooo @home",
      "09:11 polish trombone #ProjectOrion @office",
      "09:36 bake strudel",
      "10:00 done",
      "",
      "--- summary quantized ---",
      "1.00h (+0m) bake strudel",
      "0.50h (-5m) polish trombone",
      "0.25h (+4m) coffee with ghost",
      "0.25h (-3m) negotiate with goose",
      "",
      "--- tags quantized ---",
      "1.50h (-5m) #ProjectOrion",
      "0.25h (+4m) #ooo",
      "0.25h (-3m) #sales",
      "",
      "--- locations quantized ---",
      "1.50h (-5m) @office",
      "0.25h (+4m) @home",
      "0.25h (-3m) @client",
      "",
      "--- totals quantized ---",
      "2.00h (-4m) activity",
      "1.75h (-8m) workday",
    })
  end)

  t.test("invalid multiple trailing tags block commands", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan #sales #meeting",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan #sales #meeting",
      "09:00 done",
    })
  end)

  t.test("worklog order emits clear tokens when sorting needs them", function()
    t.reset({
      "--- worklog ---",
      "09:00 done",
      "08:00 plan #sales",
    })

    vim.cmd("WorklogOrder")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 plan #sales",
      "09:00 done #-",
    })
  end)

  t.test("worklog log marks the source entry behind an exact summary row", function()
    t.reset({
      "--- worklog ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h implementation",
    })
    t.set_cursor(6, 0)

    vim.cmd("WorklogLog")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 implementation !L",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h implementation !L",
      "",
      "--- logged exact ---",
      "1.00h logged",
      "",
      "--- totals exact ---",
      "1.00h workday",
    })
  end)

  t.test("worklog log marks the source entry behind a quantized summary row", function()
    t.reset({
      "--- worklog quantize=30 ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary quantized ---",
      "1.00h (+0m) implementation",
    })
    t.set_cursor(6, 0)

    vim.cmd("WorklogLog")

    t.eq(t.get_lines(), {
      "--- worklog quantize=30 ---",
      "08:00 implementation !L",
      "09:00 done",
      "",
      "--- summary quantized ---",
      "1.00h (+0m) implementation !L",
      "",
      "--- logged quantized ---",
      "1.00h (+0m) logged",
      "",
      "--- totals quantized ---",
      "1.00h (+0m) workday",
    })
  end)

  t.test("worklog log unmarks an already logged summary row", function()
    t.reset({
      "--- worklog ---",
      "08:00 implementation !L",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h implementation !L",
    })
    t.set_cursor(6, 0)

    vim.cmd("WorklogLog")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h implementation",
      "",
      "--- totals exact ---",
      "1.00h workday",
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
        "--- summary quantized ---",
        "2.00h (-8m) versions",
        "0.75h (-1m) Q1 features",
        "0.25h (+5m) stand",
        "0.00h (+5m) folksy",
        "",
        "--- tags quantized ---",
        "3.00h (+1m) #someproject",
        "",
        "--- locations quantized ---",
        "3.00h (+1m) @office",
        "",
        "--- totals quantized ---",
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
        "--- summary quantized ---",
        "2.00h (-8m) versions",
        "0.75h (-1m) Q1 features !L",
        "0.25h (+5m) stand",
        "0.00h (+5m) folksy",
        "",
        "--- tags quantized ---",
        "3.00h (+1m) #someproject",
        "",
        "--- locations quantized ---",
        "3.00h (+1m) @office",
        "",
        "--- logged quantized ---",
        "0.75h (-1m) logged",
        "2.25h (+2m) unlogged",
        "",
        "--- totals quantized ---",
        "3.00h (+1m) workday",
      })
    end
  )
end
