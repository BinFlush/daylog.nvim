return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_captured_notify = helpers.with_captured_notify
  local with_mocked_date = helpers.with_mocked_date
  local with_mocked_input = helpers.with_mocked_input
  local with_daylog_setup = helpers.with_daylog_setup

  helpers.setup_daylog()

  t.test("bare :Daylog routes to today", function()
    with_daylog_setup({}, function()
      with_captured_notify(function(messages)
        vim.cmd("Daylog")
        -- today() with no daybook configured warns -- proof the bare command reached it.
        t.eq(messages, {
          { message = "daylog: daybook.root is not configured", level = vim.log.levels.WARN },
        })
      end)
    end)
  end)

  t.test(":Daylog warns on an unknown verb", function()
    with_captured_notify(function(messages)
      vim.cmd("Daylog bogus")
      t.eq(messages, {
        {
          message = "daylog: unknown verb 'bogus' -- try :Daylog <Tab>",
          level = vim.log.levels.WARN,
        },
      })
    end)
  end)

  t.test(
    ":Daylog completion offers verbs and hides editing verbs outside a daylog buffer",
    function()
      t.reset({ "" })

      vim.bo.filetype = ""
      local entry = vim.fn.getcompletion("Daylog ", "cmdline")
      t.ok(vim.tbl_contains(entry, "today"))
      t.ok(vim.tbl_contains(entry, "report"))
      t.ok(not vim.tbl_contains(entry, "order"))

      vim.bo.filetype = "daylog"
      t.ok(vim.tbl_contains(vim.fn.getcompletion("Daylog ", "cmdline"), "order"))

      -- Per-verb argument completion: day offers date tokens.
      t.ok(vim.tbl_contains(vim.fn.getcompletion("Daylog day ", "cmdline"), "monday"))
    end
  )

  t.test("Daylog refresh rebuilds a stale summary and is a no-op when current", function()
    t.reset({
      "--- log ---",
      "08:00 plan",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "0.50h (+0m) plan",
      "",
      "--- totals ---",
      "0.50h (+0m) workday",
    })

    vim.cmd("Daylog refresh")
    t.eq(t.get_lines(), {
      "--- log ---",
      "08:00 plan",
      "10:00 done",
      "",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) plan",
      "",
      "--- totals ---",
      "2.00h (+0m) workday",
    })

    -- Running again leaves the now-current summary untouched.
    vim.cmd("Daylog refresh")
    t.eq(t.get_lines()[7], "2.00h (+0m) plan")
  end)

  local function has_unordered_diagnostic()
    for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
      if diagnostic.message:match("unordered timestamps") then
        return true
      end
    end

    return false
  end

  t.test("Daylog refresh reports an out-of-order log as a diagnostic", function()
    t.reset({
      "--- log ---",
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

    vim.cmd("Daylog refresh")
    t.ok(has_unordered_diagnostic(), "expected an unordered-timestamps diagnostic")

    -- The invalid log's summary is left untouched rather than churned.
    t.eq(t.get_lines(), before)
  end)

  t.test("Daylog refresh reports an out-of-order log with no summary", function()
    t.reset({
      "--- log ---",
      "08:00 input 1",
      "07:10 input 2",
    })

    vim.cmd("Daylog refresh")
    t.ok(has_unordered_diagnostic(), "expected a diagnostic even without a summary")
  end)

  t.test("Daylog order clears the out-of-order diagnostic", function()
    t.reset({
      "--- log ---",
      "09:00 later",
      "08:00 earlier",
      "10:00 done",
    })

    vim.cmd("Daylog refresh")
    t.ok(has_unordered_diagnostic(), "expected a diagnostic before fixing")

    -- Fixing via :Daylog order must clear the diagnostic on its own: a command
    -- edit does not fire the auto-refresh autocmds, so the command refreshes the
    -- diagnostics itself.
    vim.cmd("Daylog order")
    t.ok(not has_unordered_diagnostic(), "Daylog order should clear the diagnostic")
  end)

  t.test("log order rewrites all log blocks", function()
    t.reset({
      "--- log #ProjectOrion @office ---",
      "08:30 later",
      "note a",
      "08:00 earlier #sales",
      "note b",
      "",
      "--- summary q=15 d=dec ---",
      "x",
      "",
      "--- log #internal @home ---",
      "11:00 tea",
      "10:00 coffee @client",
      "12:00 done #internal @home",
    })

    vim.cmd("Daylog order")
    -- Reordering changes the durations, so :Daylog order rebuilds the first log's existing
    -- summary (the stale `x` placeholder) from the sorted entries -- with the canonical
    -- two-blank separators. The second log has no summary, so it is left summary-less.
    t.eq(t.get_lines(), {
      "--- log #ProjectOrion @office ---",
      "08:00 earlier #sales",
      "note b",
      "08:30 later #ProjectOrion",
      "note a",
      "",
      "",
      "--- summary q=15 d=dec ---",
      "0.50h (+0m) earlier",
      "",
      "--- tags ---",
      "0.50h (+0m) #sales",
      "",
      "--- locations ---",
      "0.50h (+0m) @office",
      "",
      "--- totals ---",
      "0.50h (+0m) workday",
      "",
      "",
      "--- log #internal @home ---",
      "10:00 coffee @client",
      "11:00 tea @home",
      "12:00 done",
    })
  end)

  t.test("new scaffolds a bare log into an empty buffer", function()
    with_daylog_setup({ auto_timezone = false }, function()
      t.reset({ "" })
      vim.cmd("Daylog new")
      t.eq(t.get_lines(), { "--- log ---" })
      t.eq(vim.api.nvim_win_get_cursor(0), { 1, 0 })
    end)
  end)

  t.test("new appends a fresh active log after existing content", function()
    with_daylog_setup({ auto_timezone = false }, function()
      t.reset({
        "--- log ---",
        "08:00 work",
        "09:00 done",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) work",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      })
      vim.cmd("Daylog new")
      t.eq(t.get_lines(), {
        "--- log ---",
        "08:00 work",
        "09:00 done",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) work",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "--- log ---",
      })
      t.eq(vim.api.nvim_win_get_cursor(0), { 11, 0 })
    end)
  end)

  t.test("new applies the configured header defaults", function()
    local opts =
      { auto_timezone = false, defaults = { quantize_minutes = 30, duration_format = "hm" } }
    with_daylog_setup(opts, function()
      t.reset({ "" })
      vim.cmd("Daylog new")
      t.eq(t.get_lines(), { "--- log q=30 d=hm ---" })
    end)
  end)

  t.test("copy uses latest active log and normalizes items", function()
    t.reset({
      "--- log #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "x",
      "",
      "--- log #sales @client ---",
      "11:00 tea #sales @client",
      "note tea",
      "",
      "12:00",
    })

    vim.cmd("Daylog copy")
    t.eq(t.get_lines(), {
      "--- log #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "x",
      "",
      "--- log #sales @client ---",
      "11:00 tea #sales @client",
      "note tea",
      "",
      "12:00",
      "",
      "--- log #sales @client ---",
      "11:00 tea",
      "note tea",
      "12:00",
      "",
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

  t.test("copy preserves explicit quantize on the active log header", function()
    t.reset({
      "--- log #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- log #sales @client q=30 ---",
      "11:00 tea",
      "12:00",
    })

    vim.cmd("Daylog copy")
    t.eq(t.get_lines(), {
      "--- log #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- log #sales @client q=30 ---",
      "11:00 tea",
      "12:00",
      "",
      "--- log #sales @client q=30 ---",
      "11:00 tea",
      "12:00",
      "",
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
      "--- log ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
    })

    vim.cmd("Daylog copy")
    t.eq(t.get_lines(), {
      "--- log ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
      "",
      "--- log ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
      "",
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
      "1.00h (+0m) workday",
      "1.00h (+0m) non-work",
    })
  end)

  t.test("copy does not preserve clear-only header metadata", function()
    t.reset({
      "--- log #- @- ---",
      "08:00 plan",
      "09:00 client #ClientA @home",
      "10:00 reset #- @-",
      "11:00 done",
    })

    vim.cmd("Daylog copy")
    t.eq(t.get_lines(), {
      "--- log #- @- ---",
      "08:00 plan",
      "09:00 client #ClientA @home",
      "10:00 reset #- @-",
      "11:00 done",
      "",
      "--- log ---",
      "08:00 plan",
      "09:00 client #ClientA @home",
      "10:00 reset #- @-",
      "11:00 done",
      "",
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

  t.test("repeat inserts into explicit log block containing cursor", function()
    t.reset({
      "--- log #ProjectOrion @office ---",
      "08:04 bake strudel",
      "08:21 negotiate with goose",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.93h (+0m) activity",
      "",
      "--- log #sales @client ---",
      "11:00 tea",
      "12:00",
    })
    t.set_cursor(10, 0)

    with_mocked_date("14:37", function()
      vim.cmd("Daylog repeat")
    end)

    t.eq(t.get_lines()[12], "14:37 tea")
  end)

  t.test("repeat re-emits sticky metadata when insertion state changed", function()
    t.reset({
      "--- log #ProjectOrion @office ---",
      "08:00 first",
      "08:15 break #ooo",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    with_mocked_date("08:30", function()
      vim.cmd("Daylog repeat")
    end)

    t.eq(t.get_lines(), {
      "--- log #ProjectOrion @office ---",
      "08:00 first",
      "08:15 break #ooo",
      "08:30 first #ProjectOrion",
      "09:00 done #ooo",
    })
  end)

  t.test("repeat keeps untagged entries untagged without sticky header metadata", function()
    t.reset({
      "--- log ---",
      "08:00 first",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    with_mocked_date("08:30", function()
      vim.cmd("Daylog repeat")
    end)

    t.eq(t.get_lines(), {
      "--- log ---",
      "08:00 first",
      "08:30 first",
      "09:00 done",
    })
  end)

  t.test(
    "repeat emits clear tokens when replaying nil metadata after sticky values were set",
    function()
      t.reset({
        "--- log ---",
        "08:00 first",
        "08:15 break #ooo @home",
        "09:00 done",
      })
      t.set_cursor(2, 0)

      with_mocked_date("08:30", function()
        vim.cmd("Daylog repeat")
      end)

      t.eq(t.get_lines(), {
        "--- log ---",
        "08:00 first",
        "08:15 break #ooo @home",
        "08:30 first #- @-",
        "09:00 done #ooo @home",
      })
    end
  )

  t.test("repeat from a summary row inserts the activity at the current time", function()
    t.reset({
      "--- log #ClientA @office ---",
      "08:00 planning",
      "10:00 implementation @home",
      "11:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) planning",
      "1.00h (+0m) implementation",
      "",
      "--- tags ---",
      "3.00h (+0m) #ClientA",
      "",
      "--- locations ---",
      "2.00h (+0m) @office",
      "1.00h (+0m) @home",
      "",
      "--- totals ---",
      "3.00h (+0m) workday",
    })
    t.set_cursor(8, 0) -- the "implementation" main summary row

    with_mocked_date("11:30", function()
      vim.cmd("Daylog repeat")
    end)

    -- The repeated entry is inserted into the log body, after "11:00 done".
    t.eq(t.get_lines()[5], "11:30 implementation")
  end)

  t.test("rename a tag from its tag-total row updates source, header, and summary", function()
    t.reset({
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
    })
    t.set_cursor(11, 0) -- the "#ClientA" tag total

    vim.cmd("Daylog rename Globex")

    local lines = t.get_lines()
    t.eq(lines[1], "--- log #Globex @office ---")
    t.eq(lines[4], "11:00 done #Globex")
    t.eq(lines[12], "2.00h (+0m) #Globex")
  end)

  t.test("rename an entry with no arg prompts with its text as the default", function()
    t.reset({
      "--- log ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })
    t.set_cursor(2, 0) -- the "implementation" entry (an empty pool falls back to the prompt)

    with_mocked_input("coding", function()
      vim.cmd("Daylog rename")
    end)

    t.eq(t.get_lines()[2], "08:00 coding")
    t.eq(t.get_lines()[7], "1.00h (+0m) coding")
  end)

  t.test("rename merges into a picked candidate via the fallback picker", function()
    t.reset({
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
    })
    t.set_cursor(11, 0) -- the "#a" tag total; its only merge candidate is "b"

    -- No Telescope in the test env, so :Daylog rename uses vim.ui.select; pick the
    -- first offered candidate ("b") to merge #a into #b.
    local old_select = vim.ui.select
    vim.ui.select = function(items, _, on_choice)
      on_choice(items[1])
    end
    local ok, err = pcall(function()
      vim.cmd("Daylog rename")
    end)
    vim.ui.select = old_select
    if not ok then
      error(err)
    end

    t.eq(t.get_lines()[2], "08:00 plan #b")
    t.eq(t.get_lines()[12], "2.00h (+0m) #b")
  end)

  t.test("rename accepts a multi-word name as a command argument on an entry", function()
    t.reset({
      "--- log ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })
    t.set_cursor(2, 0)

    vim.cmd("Daylog rename fix the build")

    t.eq(t.get_lines()[2], "08:00 fix the build")
    t.eq(t.get_lines()[7], "1.00h (+0m) fix the build")
  end)

  t.test("rename from an entry line renames only that entry", function()
    t.reset({
      "--- log ---",
      "08:00 alpha",
      "09:00 alpha",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) alpha",
      "",
      "--- totals ---",
      "2.00h (+0m) workday",
    })
    t.set_cursor(2, 0) -- the first "alpha" entry, not a summary row

    vim.cmd("Daylog rename beta")

    -- Only the cursor's entry is renamed; its sibling is untouched.
    t.eq(t.get_lines()[2], "08:00 beta")
    t.eq(t.get_lines()[3], "09:00 alpha")
  end)

  t.test("Daylog map over a line range maps every entry in the selection", function()
    t.reset({
      "--- log q=1 d=hm ---",
      "09:00 alpha",
      "09:30 beta",
      "10:00 gamma",
      "10:30 done",
    })
    vim.cmd("Daylog refresh")

    -- :N,M is what a visual selection sends; map all the entries in those lines at once.
    vim.cmd("2,4Daylog map WORK-1")

    t.eq(t.get_lines()[2], "09:00 alpha => WORK-1")
    t.eq(t.get_lines()[3], "09:30 beta => WORK-1")
    t.eq(t.get_lines()[4], "10:00 gamma => WORK-1")
    t.eq(t.get_lines()[5], "10:30 done")

    local folded = false
    for _, line in ipairs(t.get_lines()) do
      if line == "1:30 (+0m) WORK-1" then
        folded = true
      end
    end
    t.ok(folded, "the three entries fold under the one alias")
  end)

  t.test(
    "Daylog map over a range still maps later entries when the first already has the alias",
    function()
      -- Regression: the shell's no-op guard compared the chosen label to the FIRST selected entry's
      -- alias. With that entry already mapped to the target, the whole range was skipped, so a later
      -- unmapped entry never got the alias ("nothing happens"). The short-circuit must be single-target.
      t.reset({
        "--- log q=1 d=hm ---",
        "09:00 alpha => WORK-1",
        "09:30 beta",
        "10:00 done",
      })
      vim.cmd("Daylog refresh")

      vim.cmd("2,3Daylog map WORK-1")

      t.eq(t.get_lines()[2], "09:00 alpha => WORK-1") -- already mapped: unchanged
      t.eq(t.get_lines()[3], "09:30 beta => WORK-1") -- previously skipped, now mapped
    end
  )

  t.test("Daylog! map over a line range clears every mapping in the selection", function()
    t.reset({
      "--- log q=1 d=hm ---",
      "09:00 alpha => WORK-1",
      "09:30 beta => WORK-1",
      "10:00 done",
    })
    vim.cmd("Daylog refresh")

    vim.cmd("2,3Daylog! map")

    t.eq(t.get_lines()[2], "09:00 alpha")
    t.eq(t.get_lines()[3], "09:30 beta")
  end)

  t.test("Daylog map over a range refuses when the selection includes a logged entry", function()
    t.reset({
      "--- log q=1 d=hm ---",
      "09:00 alpha",
      "09:30 deploy !S30",
      "10:00 done",
    })
    vim.cmd("Daylog refresh")

    with_captured_notify(function(messages)
      vim.cmd("2,3Daylog map BUG-1")
      local refused = false
      for _, message in ipairs(messages) do
        if message.message:find("logged", 1, true) then
          refused = true
        end
      end
      t.ok(refused, "warns that a logged entry is in the selection")
    end)

    t.eq(t.get_lines()[2], "09:00 alpha") -- nothing mapped
  end)

  t.test("balance follows a reordered summary row with the cursor", function()
    t.reset({
      "--- log q=60 d=hm ---",
      "08:00 alpha",
      "09:00 beta",
      "11:00 done",
    })
    vim.cmd("Daylog refresh")

    -- Put the cursor on the "alpha" summary row (below "beta") at a non-zero column.
    local alpha_row
    for i, line in ipairs(t.get_lines()) do
      if line:find("%) alpha$") then
        alpha_row = i
      end
    end
    t.set_cursor(alpha_row, 3)

    vim.cmd("Daylog balance +2") -- alpha becomes 3h and jumps above beta

    local cursor = vim.api.nvim_win_get_cursor(0)
    t.ok(cursor[1] < alpha_row, "the cursor moved up to the row's new line")
    t.ok(t.get_lines()[cursor[1]]:find("alpha", 1, true), "the cursor is on the alpha row")
    t.eq(cursor[2], 3) -- the column is preserved
  end)

  t.test("copy moves the cursor onto the new log header", function()
    t.reset({
      "--- log ---",
      "08:00 plan",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) plan",
    })
    t.set_cursor(2, 0)
    local before = #t.get_lines()

    vim.cmd("Daylog copy")

    -- The cursor jumps into the appended copy, onto its log header (so the window
    -- scrolls to it).
    local cursor = vim.api.nvim_win_get_cursor(0)
    t.ok(cursor[1] > before, "the cursor moved into the new copy")
    t.ok(t.get_lines()[cursor[1]]:find("^%-%-%- log"), "the cursor is on the new log header")
  end)

  t.test("insert orders into explicit log block after equal timestamps", function()
    t.reset({
      "--- log #ProjectOrion @office ---",
      "08:00 first",
      "08:00 second",
      "09:00 done",
    })
    t.set_cursor(1, 0)

    with_mocked_date("08:00", function()
      vim.cmd("Daylog insert")
    end)

    t.eq(t.get_lines(), {
      "--- log #ProjectOrion @office ---",
      "08:00 first",
      "08:00 second",
      "08:00 ",
      "09:00 done",
    })
  end)

  t.test("insert works from a later log header", function()
    t.reset({
      "--- log #ProjectOrion @office ---",
      "08:00 raw",
      "09:00 done",
      "",
      "--- log #sales @client ---",
      "10:00 first",
      "11:00 done",
    })
    t.set_cursor(5, 0)

    with_mocked_date("10:30", function()
      vim.cmd("Daylog insert")
    end)

    t.eq(t.get_lines(), {
      "--- log #ProjectOrion @office ---",
      "08:00 raw",
      "09:00 done",
      "",
      "--- log #sales @client ---",
      "10:00 first",
      "10:30 ",
      "11:00 done",
    })
  end)

  t.test("insert warns when no explicit log exists", function()
    t.reset({
      "08:00 raw",
      "09:00 done",
    })
    t.set_cursor(1, 0)

    vim.cmd("Daylog insert")
    t.eq(t.get_lines(), {
      "08:00 raw",
      "09:00 done",
    })
  end)

  t.test("repeat ignores non-log lines", function()
    t.reset({
      "--- log #ProjectOrion @office ---",
      "08:00 task",
      "09:00",
      "",
      "--- summary q=15 d=dec ---",
      "0.00h (+0m) task",
    })
    t.set_cursor(5, 0)

    vim.cmd("Daylog repeat")
    t.eq(t.get_lines(), {
      "--- log #ProjectOrion @office ---",
      "08:00 task",
      "09:00",
      "",
      "--- summary q=15 d=dec ---",
      "0.00h (+0m) task",
    })
  end)

  t.test("invalid multiple trailing tags block commands", function()
    t.reset({
      "--- log #ProjectOrion @office ---",
      "08:00 plan #sales #meeting",
      "09:00 done",
    })

    vim.cmd("Daylog copy")
    t.eq(t.get_lines(), {
      "--- log #ProjectOrion @office ---",
      "08:00 plan #sales #meeting",
      "09:00 done",
    })
  end)

  t.test("log order emits clear tokens when sorting needs them and warns", function()
    t.reset({
      "--- log ---",
      "09:00 done",
      "08:00 plan #sales",
    })

    with_captured_notify(function(messages)
      vim.cmd("Daylog order")

      t.eq(messages, {
        {
          message = "daylog: ordering set the tag/location/utc offset of order-dependent entries; review: 09:00 done",
          level = vim.log.levels.WARN,
        },
      })
    end)

    t.eq(t.get_lines(), {
      "--- log ---",
      "08:00 plan #sales",
      "09:00 done #-",
    })
  end)

  t.test("log order sorts by effective utc time and warns about an offset change", function()
    -- a@-4 = 15:00Z, b@+2 = 10:00Z: in real time b is earlier, so ordering swaps
    -- them (the local clock then reads high-to-low) and warns that a's inherited
    -- offset changed.
    t.reset({
      "--- log utc-4 ---",
      "11:00 a",
      "12:00 b utc+2",
    })

    with_captured_notify(function(messages)
      vim.cmd("Daylog order")

      t.eq(messages, {
        {
          message = "daylog: ordering set the tag/location/utc offset of order-dependent entries; review: 11:00 a",
          level = vim.log.levels.WARN,
        },
      })
    end)

    t.eq(t.get_lines(), {
      "--- log utc-4 ---",
      "12:00 b utc+2",
      "11:00 a utc-4",
    })
  end)

  t.test("Daylog split splits the activity under the cursor and rebuilds the summary", function()
    t.reset({
      "--- log q=1 d=hm ---",
      "08:00 meeting",
      "10:00 done",
      "",
      "--- summary q=1 d=hm ---",
      "2:00 (+0m) meeting",
      "",
      "--- totals ---",
      "2:00 (+0m) workday",
    })
    t.set_cursor(6, 0)

    vim.cmd("Daylog split 3 1")

    local out = t.get_lines()
    t.eq(out[2], "08:00 meeting (1)")
    t.eq(out[3], "09:30 meeting (2)")
    t.eq(out[4], "10:00 done")
    local function has(needle)
      for _, l in ipairs(out) do
        if l == needle then
          return true
        end
      end
      return false
    end
    t.ok(has("1:30 (+0m) meeting (1)"), "part 1 is 90 minutes")
    t.ok(has("0:30 (+0m) meeting (2)"), "part 2 is 30 minutes")
    t.ok(has("2:00 (+0m) workday"), "the workday total is preserved")
  end)

  t.test("Daylog split warns on a bad weight without editing", function()
    t.reset({
      "--- log q=1 d=hm ---",
      "08:00 meeting",
      "10:00 done",
      "",
      "--- summary q=1 d=hm ---",
      "2:00 (+0m) meeting",
      "",
      "--- totals ---",
      "2:00 (+0m) workday",
    })
    t.set_cursor(6, 0)
    local before = t.get_lines()

    with_captured_notify(function(messages)
      vim.cmd("Daylog split 2 0")
      t.eq(#messages, 1)
      t.ok(messages[1].message:match("split weights must be positive"), "warns on the zero weight")
    end)

    t.eq(t.get_lines(), before)
  end)

  t.test("log log marks the source entry behind an unrounded summary row", function()
    t.reset({
      "--- log ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
    })
    t.set_cursor(6, 0)

    vim.cmd("Daylog log")

    t.eq(t.get_lines(), {
      "--- log ---",
      "08:00 implementation !S60",
      "09:00 done",
      "",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation !S",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })
  end)

  t.test("log log marks the source entry behind a quantized summary row", function()
    t.reset({
      "--- log q=30 ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "--- summary q=30 d=dec ---",
      "1.00h (+0m) implementation",
    })
    t.set_cursor(6, 0)

    vim.cmd("Daylog log")

    t.eq(t.get_lines(), {
      "--- log q=30 ---",
      "08:00 implementation !S60",
      "09:00 done",
      "",
      "",
      "--- summary q=30 d=dec ---",
      "1.00h (+0m) implementation !S",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })
  end)

  t.test("log log unmarks an already logged summary row", function()
    t.reset({
      "--- log ---",
      "08:00 implementation !S60",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation !S",
    })
    t.set_cursor(6, 0)

    vim.cmd("Daylog log")

    t.eq(t.get_lines(), {
      "--- log ---",
      "08:00 implementation",
      "09:00 done",
      "",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+0m) implementation",
      "",
      "--- totals ---",
      "1.00h (+0m) workday",
    })
  end)

  t.test("log log merges a newly logged row into an already logged one and sums", function()
    -- build has one logged interval (frozen 60) and one unlogged (60). Logging the
    -- unlogged one must combine them into a single 2.00h row, with BOTH entries
    -- carrying the combined !S120 -- not each keeping its own 60.
    t.reset({
      "--- log ---",
      "08:00 build !S60",
      "09:00 build",
      "10:00 done",
    })
    vim.cmd("Daylog refresh")

    local function find(pred)
      local lines = t.get_lines()
      for i, line in ipairs(lines) do
        if pred(line) then
          return i
        end
      end
    end
    -- The unlogged "build" summary row: a summary line (not an entry) mentioning build
    -- without an !S marker.
    local unlogged_row = find(function(line)
      return line:find("build", 1, true)
        and not line:find("!S", 1, true)
        and not line:match("^%d%d:%d%d")
    end)
    t.ok(unlogged_row ~= nil, "expected a separate unlogged build summary row")

    t.set_cursor(unlogged_row, 0)
    vim.cmd("Daylog log")

    local out = t.get_lines()
    t.eq(out[2], "08:00 build !S120")
    t.eq(out[3], "09:00 build !S120")

    local function has(needle)
      for _, line in ipairs(out) do
        if line == needle then
          return true
        end
      end
      return false
    end
    t.ok(has("2.00h (+0m) build !S"), "the merged row reads 2.00h")
    -- No separate unlogged build row survives.
    t.ok(find(function(line)
      return line:find("build", 1, true)
        and not line:find("!S", 1, true)
        and not line:match("^%d%d:%d%d")
    end) == nil, "the unlogged build row should be gone")
  end)

  t.test("log log unmark of a merged row returns the full unlogged time", function()
    -- Both build intervals are logged at the merged total; unmarking the row clears
    -- every entry and gives back the whole 2.00h as unlogged.
    t.reset({
      "--- log ---",
      "08:00 build !S120",
      "09:00 build !S120",
      "10:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "2.00h (+0m) build !S",
    })
    t.set_cursor(7, 0)

    vim.cmd("Daylog log")

    local out = t.get_lines()
    t.eq(out[2], "08:00 build")
    t.eq(out[3], "09:00 build")
    local function has(needle)
      for _, line in ipairs(out) do
        if line == needle then
          return true
        end
      end
      return false
    end
    t.ok(has("2.00h (+0m) build"), "the row is fully unlogged at 2.00h")
  end)

  t.test("log log freezes a row that survives a later appended entry", function()
    t.reset({
      "--- log ---",
      "00:00 logged item",
      "01:07 other task",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h (+7m) logged item",
    })
    t.set_cursor(6, 0)

    vim.cmd("Daylog log")
    -- The source entry is frozen at its committed 60 minutes (1.00h).
    t.eq(t.get_lines()[2], "00:00 logged item !S60")

    -- Append a third entry and refresh: the frozen logged slice holds at 1.00h, the block's
    -- remaining honest time surfaces as an unlogged "logged item" slice, and the 2-minute
    -- "other task" rounds to its own honest 0. The total is the honest sum of the parts.
    local lines = t.get_lines()
    table.insert(lines, 4, "01:09 new task")
    t.set_lines(lines)
    vim.cmd("Daylog refresh")

    local out = t.get_lines()
    local function has(needle)
      for _, l in ipairs(out) do
        if l == needle then
          return true
        end
      end
      return false
    end
    t.ok(has("1.00h (+7m) logged item !S"), "logged row should still read 1.00h")
    t.ok(has("0.25h (-15m) logged item"), "the unlogged remainder surfaces as its own row")
    t.ok(has("0.00h (+2m) other task"), "other task rounds to its own honest value")
    t.ok(has("1.25h (-6m) workday"), "the total is the honest sum of the displayed parts")
  end)

  t.test("logging two rounded rows commits identical values in either order", function()
    -- Reported order-dependence: `thing two round-1` then `thing one` used to commit
    -- thing one at !S75 (stale whole-day target), while the reverse order gave !S60. The
    -- committed value now tracks the frozen-aware display, so both orders converge.
    local function summary_item_row(text)
      for i, l in ipairs(t.get_lines()) do
        if l:match("^%d[%d%.]*h %b()") and l:find(text, 1, true) then
          return i
        end
      end
    end
    local function log_both(first, second)
      t.reset({
        "--- log ---",
        "08:00 thing one",
        "09:00 thing two round-1",
        "10:08 done",
      })
      vim.cmd("Daylog refresh")
      for _, text in ipairs({ first, second }) do
        t.set_cursor(summary_item_row(text), 0)
        vim.cmd("Daylog log")
        vim.cmd("Daylog refresh")
      end
      return t.get_lines()
    end

    local two_then_one = log_both("thing two", "thing one")
    t.eq(two_then_one, log_both("thing one", "thing two"))
    t.eq(two_then_one[2], "08:00 thing one !S60")
    t.eq(two_then_one[3], "09:00 thing two round-1 !S60")
  end)

  t.test("Daylog refresh warns when a frozen !S value no longer fits the bucket", function()
    t.reset({
      "--- log ---",
      "08:00 plan !S7",
      "09:00 done",
    })

    vim.cmd("Daylog refresh")

    local found = false
    for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
      if diagnostic.message:match("frozen !S value no longer fits") then
        found = true
      end
    end
    t.ok(found, "expected a frozen-drift diagnostic for a non-bucket !S value")
  end)

  t.test("Daylog refresh warns when same-row logged entries disagree on their !S value", function()
    t.reset({
      "--- log ---",
      "08:00 build !S60",
      "09:00 build !S45",
      "10:00 done",
    })

    vim.cmd("Daylog refresh")

    local found = false
    for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
      if diagnostic.message:match("disagree on their !S value") then
        found = true
      end
    end
    t.ok(found, "expected a divergent-!S diagnostic")
  end)

  t.test(
    "log log regression: multi-edit summary-refresh applies correctly through the real command path",
    function()
      -- Exercises the full :Daylog log -> apply_result path with the reported
      -- bug case. The fix returns a summary-group refresh edit (higher rows)
      -- before source-entry edits (lower rows); this test proves apply_result
      -- applies them in that order without index drift.
      t.reset({
        "--- log #someproject @office ---",
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

      vim.cmd("Daylog log")

      t.eq(t.get_lines(), {
        "--- log #someproject @office ---",
        "08:00 versions",
        "09:00 stand",
        "09:20 versions",
        "10:12 folksy",
        "    what is he talking about    ",
        "10:17 Q1 features !S45",
        "11:01 versions",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "2.00h (-8m) versions",
        "0.75h (-1m) Q1 features !S",
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
    end
  )

  t.test(
    "refresh recovery applies through the real shell path in order (insert before summary)",
    function()
      -- A deleted log header leaves the second log headerless. Recovery synthesizes
      -- a header (an INSERT, in the original coordinates) while the summary edits are in the
      -- post-insert coordinates, so buffer.apply_result must apply the list in order. If it
      -- sorted/reordered, the insert and summary edits would collide and corrupt the buffer.
      t.reset({
        "--- log ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "13:00 b",
        "14:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) b",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      })
      t.set_cursor(1, 0)

      require("daylog.buffer").apply_refresh(false)

      t.eq(t.get_lines(), {
        "--- log ---",
        "09:00 a",
        "10:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) a",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
        "",
        "",
        "--- log ---",
        "13:00 b",
        "14:00 done",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.00h (+0m) b",
        "",
        "--- totals ---",
        "1.00h (+0m) workday",
      })
    end
  )
end
