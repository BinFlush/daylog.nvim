return function(t)
  local journal = require("worklog.journal")
  local worklog = require("worklog")

  local function with_mocked_date(value, fn)
    local old_date = os.date

    rawset(os, "date", function()
      return value
    end)

    local ok, err = xpcall(fn, debug.traceback)
    rawset(os, "date", old_date)

    if not ok then
      error(err, 0)
    end
  end

  local function with_mocked_time(value, fn)
    local old_time = os.time

    rawset(os, "time", function(argument)
      if argument ~= nil then
        return old_time(argument)
      end

      return value
    end)

    local ok, err = xpcall(fn, debug.traceback)
    rawset(os, "time", old_time)

    if not ok then
      error(err, 0)
    end
  end

  local function with_worklog_setup(options, fn)
    worklog.setup(options)

    local ok, err = xpcall(fn, debug.traceback)
    worklog.setup()

    if not ok then
      error(err, 0)
    end
  end

  local function with_captured_notify(fn)
    local old_notify = vim.notify
    local messages = {}

    vim.notify = function(message, level)
      table.insert(messages, {
        message = message,
        level = level,
      })
    end

    local ok, err = xpcall(function()
      fn(messages)
    end, debug.traceback)

    vim.notify = old_notify

    if not ok then
      error(err, 0)
    end
  end

  local function write_journal_file(root, directory, now, lines)
    local path = journal.path_for_date({
      root = root,
      directory = directory,
    }, now)

    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
    return path
  end

  worklog.setup()

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

  t.test("new creates the initial worklog block in an empty buffer", function()
    t.reset({})

    vim.cmd("WorklogNew")
    t.eq(t.get_lines(), {
      "--- worklog ---",
    })
    t.eq(vim.api.nvim_win_get_cursor(0), { 1, 0 })
  end)

  t.test("new appends a worklog block with configured defaults", function()
    with_worklog_setup({
      defaults = {
        tag = "ClientA",
        location = "office",
        quantize_minutes = 30,
        duration_format = "hhmm",
      },
    }, function()
      t.reset({
        "notes",
      })

      vim.cmd("WorklogNew")
      t.eq(t.get_lines(), {
        "notes",
        "",
        "--- worklog #ClientA @office quantize=30 duration=hhmm ---",
      })
      t.eq(vim.api.nvim_win_get_cursor(0), { 3, 0 })
    end)
  end)

  t.test("today opens a new journal file and initializes the first entry", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    with_worklog_setup({
      defaults = {
        tag = "ClientA",
        location = "office",
        quantize_minutes = 30,
        duration_format = "hhmm",
      },
      journal = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("WorklogToday")
      end)

      local expected_dir = root .. "/" .. os.date("%Y/%V", now)
      local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", now) .. ".wkl"

      t.eq(vim.fn.isdirectory(expected_dir), 1)
      t.eq(vim.api.nvim_buf_get_name(0), expected_path)
      t.eq(t.get_lines(), {
        "--- worklog #ClientA @office quantize=30 duration=hhmm ---",
        "08:45 ",
      })
      t.eq(vim.api.nvim_win_get_cursor(0), { 2, 6 })
    end)
  end)

  t.test("today initializes an existing empty journal file", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })
    local expected_dir = root .. "/" .. os.date("%Y", now)
    local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", now) .. ".wkl"

    vim.fn.mkdir(expected_dir, "p")
    vim.fn.writefile({}, expected_path)

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("WorklogToday")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), expected_path)
      t.eq(t.get_lines(), {
        "--- worklog ---",
        "08:45 ",
      })
    end)
  end)

  t.test("today opens an existing journal file without changing it", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })
    local expected_dir = root .. "/" .. os.date("%Y", now)
    local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", now) .. ".wkl"

    vim.fn.mkdir(expected_dir, "p")
    vim.fn.writefile({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
    }, expected_path)

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("WorklogToday")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), expected_path)
      t.eq(t.get_lines(), {
        "--- worklog ---",
        "08:00 plan",
        "09:00 done",
      })
      t.ok(not vim.bo.modified)
    end)
  end)

  t.test("today does nothing when journal settings are missing", function()
    with_worklog_setup({}, function()
      vim.cmd("enew!")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "scratch" })
      vim.bo.modified = false

      vim.cmd("WorklogToday")

      t.eq(vim.api.nvim_buf_get_name(0), "")
      t.eq(t.get_lines(), { "scratch" })
    end)
  end)

  t.test("today does not create directories when current buffer has unsaved changes", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })
    local expected_dir = root .. "/" .. os.date("%Y", now)
    local old_hidden = vim.o.hidden
    local old_autowrite = vim.o.autowrite
    local old_autowriteall = vim.o.autowriteall

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local ok, err = xpcall(function()
        vim.o.hidden = false
        vim.o.autowrite = false
        vim.o.autowriteall = false

        vim.cmd("enew!")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "scratch" })

        vim.cmd("WorklogToday")

        t.eq(vim.api.nvim_buf_get_name(0), "")
        t.eq(t.get_lines(), { "scratch" })
        t.ok(vim.bo.modified)
        t.eq(vim.fn.isdirectory(expected_dir), 0)
      end, debug.traceback)

      vim.o.hidden = old_hidden
      vim.o.autowrite = old_autowrite
      vim.o.autowriteall = old_autowriteall

      if not ok then
        error(err, 0)
      end
    end)
  end)

  t.test("week opens a scratch report with daily summaries before the weekly total", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 22,
      hour = 12,
      min = 0,
      sec = 0,
    })
    local monday = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 12,
      min = 0,
      sec = 0,
    })
    local friday = os.time({
      year = 2026,
      month = 5,
      day = 22,
      hour = 12,
      min = 0,
      sec = 0,
    })

    write_journal_file(root, "%Y/%V", monday, {
      "--- worklog #ClientA @office quantize=30 ---",
      "08:00 plan",
      "08:20 implementation @home",
      "09:00 done",
      "",
      "--- summary exact ---",
      "stale",
    })

    write_journal_file(root, "%Y/%V", friday, {
      "--- worklog #ClientA @office quantize=30 ---",
      "09:00 stale",
      "09:30 done",
      "",
      "--- summary exact ---",
      "stale",
      "",
      "--- worklog #internal @home quantize=60 ---",
      "10:00 retro",
      "10:40 done",
    })

    with_worklog_setup({
      defaults = {
        duration_format = "hhmm",
      },
      journal = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("silent! only!")
      t.reset({ "notes" })

      local windows_before = #vim.api.nvim_tabpage_list_wins(0)

      with_mocked_time(now, function()
        vim.cmd("WorklogWeek")
      end)

      t.eq(#vim.api.nvim_tabpage_list_wins(0), windows_before + 1)
      t.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "worklog-week-2026-W21")
      t.eq(vim.bo.buftype, "nofile")
      t.eq(vim.bo.bufhidden, "wipe")
      t.ok(not vim.bo.swapfile)
      t.ok(not vim.bo.modifiable)
      t.ok(not vim.bo.modified)
      t.eq(t.get_lines(), {
        "--- day summary quantized 2026-05-18 ---",
        "0:30 (+10m) implementation",
        "0:30 (-10m) plan",
        "",
        "--- day tags quantized 2026-05-18 ---",
        "1:00 (+0m) #ClientA",
        "",
        "--- day locations quantized 2026-05-18 ---",
        "0:30 (+10m) @home",
        "0:30 (-10m) @office",
        "",
        "--- day totals quantized 2026-05-18 ---",
        "1:00 (+0m) workday",
        "",
        "--- day summary quantized 2026-05-22 ---",
        "1:00 (-20m) retro",
        "",
        "--- day tags quantized 2026-05-22 ---",
        "1:00 (-20m) #internal",
        "",
        "--- day locations quantized 2026-05-22 ---",
        "1:00 (-20m) @home",
        "",
        "--- day totals quantized 2026-05-22 ---",
        "1:00 (-20m) workday",
        "",
        "--- week summary quantized 2026-W21 ---",
        "1:00 (-20m) retro",
        "0:30 (+10m) implementation",
        "0:30 (-10m) plan",
        "",
        "--- week tags quantized 2026-W21 ---",
        "1:00 (+0m) #ClientA",
        "1:00 (-20m) #internal",
        "",
        "--- week locations quantized 2026-W21 ---",
        "1:30 (-10m) @home",
        "0:30 (-10m) @office",
        "",
        "--- week totals quantized 2026-W21 ---",
        "2:00 (-20m) workday",
      })

      vim.cmd("silent! only!")
    end)
  end)

  t.test("week warns and leaves the current buffer unchanged when no daily files exist", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 22,
      hour = 12,
      min = 0,
      sec = 0,
    })

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("silent! only!")
      t.reset({ "scratch" })

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("WorklogWeek")
        end)

        t.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
        t.eq(vim.api.nvim_buf_get_name(0), "")
        t.eq(t.get_lines(), { "scratch" })
        t.eq(messages, {
          {
            message = "worklog: no journal worklogs found for week 2026-W21",
            level = vim.log.levels.WARN,
          },
        })
      end)
    end)
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
end
