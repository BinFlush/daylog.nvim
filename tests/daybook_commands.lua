return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_captured_notify = helpers.with_captured_notify
  local with_mocked_confirm = helpers.with_mocked_confirm
  local with_mocked_time = helpers.with_mocked_time
  local with_temp_home_root = helpers.with_temp_home_root
  local write_daybook_file = helpers.write_daybook_file

  -- These tests assert freshly-created headers and run on a real machine clock, so
  -- default auto_timezone off -- otherwise every created header would gain the host's
  -- live `utc±N` (non-deterministic across machines/CI). The timezone feature has its
  -- own coverage in tests/auto_timezone.lua. A test can still opt in by passing
  -- `auto_timezone = true`.
  local function with_daylog_setup(options, fn)
    options = vim.tbl_extend("keep", options or {}, { auto_timezone = false })
    helpers.with_daylog_setup(options, fn)
  end

  helpers.setup_daylog()

  local function report_has_workday(buf, prefix)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:match("^" .. prefix .. " .* workday$") then
        return true
      end
    end
    return false
  end

  t.test("today opens a new daybook file and initializes the first entry", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    with_daylog_setup({
      defaults = {
        tag = "ClientA",
        location = "office",
        quantize_minutes = 30,
        duration_format = "hm",
      },
      daybook = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("DaylogToday")
      end)

      local expected_dir = root .. "/" .. os.date("%Y/%V", now)
      local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", now) .. ".day"

      t.eq(vim.fn.isdirectory(expected_dir), 1)
      t.eq(vim.api.nvim_buf_get_name(0), expected_path)
      t.eq(t.get_lines(), {
        "--- log #ClientA @office q=30 d=hm ---",
        "08:45 ",
        "",
        "",
        "--- summary q=30 d=hm ---",
        "",
        "--- totals ---",
        "0:00 (+0m) workday",
      })
      t.eq(vim.api.nvim_win_get_cursor(0), { 2, 6 })
    end)
  end)

  t.test("today reopened after navigating away does not duplicate the seeded log", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 18, hour = 8, min = 45, sec = 0 })

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        -- Seed today, then leave it unsaved.
        vim.cmd("DaylogToday")
        local seeded = t.get_lines()

        -- Navigate away (the unsaved buffer survives because hidden is set) and
        -- back: reopening today must reuse that buffer, not append a duplicate.
        -- DaylogToday -1 is an exact jump (PrevDay would find no earlier log).
        vim.cmd("DaylogToday -1")
        vim.cmd("DaylogToday")

        t.eq(t.get_lines(), seeded)
      end)
    end)
  end)

  t.test("today zero offset behaves like today", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("DaylogToday 0")
      end)

      t.eq(
        vim.api.nvim_buf_get_name(0),
        root .. "/" .. os.date("%Y", now) .. "/" .. os.date("%Y-%m-%d", now) .. ".day"
      )
      t.eq(t.get_lines(), {
        "--- log ---",
        "08:45 ",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "",
        "--- totals ---",
        "0.00h (+0m) workday",
      })
      t.eq(vim.api.nvim_win_get_cursor(0), { 2, 6 })
    end)
  end)

  t.test("today negative offset opens yesterday's dated daybook file", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })
    local yesterday = os.time({
      year = 2026,
      month = 5,
      day = 17,
      hour = 12,
      min = 0,
      sec = 0,
    })

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("DaylogToday -1")
      end)

      local path = root
        .. "/"
        .. os.date("%Y", yesterday)
        .. "/"
        .. os.date("%Y-%m-%d", yesterday)
        .. ".day"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      -- Navigation only: an empty, unmodified buffer with nothing written to disk.
      t.eq(t.get_lines(), { "" })
      t.eq(vim.bo.modified, false)
      t.eq(vim.fn.filereadable(path), 0)
    end)
  end)

  t.test("today positive offset opens tomorrow's dated daybook file", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })
    local tomorrow = os.time({
      year = 2026,
      month = 5,
      day = 19,
      hour = 12,
      min = 0,
      sec = 0,
    })

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("DaylogToday +1")
      end)

      local path = root
        .. "/"
        .. os.date("%Y", tomorrow)
        .. "/"
        .. os.date("%Y-%m-%d", tomorrow)
        .. ".day"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      -- Navigation only: an empty, unmodified buffer with nothing written to disk.
      t.eq(t.get_lines(), { "" })
      t.eq(vim.bo.modified, false)
      t.eq(vim.fn.filereadable(path), 0)
    end)
  end)

  t.test("navigation refuses to leave today while it has errors", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local earlier = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local earlier_path = write_daybook_file(root, "%Y", earlier, {
      "--- log ---",
      "08:00 plan",
    })
    local today_path = write_daybook_file(root, "%Y", now, {
      "--- log #ClientA @office ---",
      "09:00 later",
      "08:00 earlier",
    })

    with_daylog_setup({
      defaults = { tag = "ClientA", location = "office" },
      daybook = { root = root, directory = "%Y" },
    }, function()
      with_mocked_time(now, function()
        vim.cmd("edit " .. vim.fn.fnameescape(today_path))

        -- The out-of-order entries keep navigation on today.
        vim.cmd("DaylogPrevDay")
        t.eq(vim.api.nvim_buf_get_name(0), today_path)

        -- Fixing the order releases the guard; navigation skips to the prior log.
        vim.api.nvim_buf_set_lines(0, 1, 3, false, { "08:00 earlier", "09:00 later" })
        vim.cmd("DaylogPrevDay")
        t.eq(vim.api.nvim_buf_get_name(0), earlier_path)
      end)
    end)
  end)

  t.test("today expands a home-relative daybook root before opening", function()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    with_temp_home_root(function(relative_root, expanded_root)
      with_daylog_setup({
        daybook = {
          root = relative_root,
          directory = "%Y",
        },
      }, function()
        vim.cmd("enew!")
        vim.bo.modified = false

        with_mocked_time(now, function()
          vim.cmd("DaylogToday")
        end)

        t.eq(
          vim.api.nvim_buf_get_name(0),
          expanded_root .. "/" .. os.date("%Y", now) .. "/" .. os.date("%Y-%m-%d", now) .. ".day"
        )
      end)
    end)
  end)

  t.test("today initializes an existing empty daybook file", function()
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
    local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", now) .. ".day"

    vim.fn.mkdir(expected_dir, "p")
    vim.fn.writefile({}, expected_path)

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("DaylogToday")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), expected_path)
      t.eq(t.get_lines(), {
        "--- log ---",
        "08:45 ",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "",
        "--- totals ---",
        "0.00h (+0m) workday",
      })
    end)
  end)

  t.test("today nonzero offset opens an existing empty daybook file without writing", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })
    local tomorrow = os.time({
      year = 2026,
      month = 5,
      day = 19,
      hour = 12,
      min = 0,
      sec = 0,
    })
    local expected_dir = root .. "/" .. os.date("%Y", tomorrow)
    local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", tomorrow) .. ".day"

    vim.fn.mkdir(expected_dir, "p")
    vim.fn.writefile({}, expected_path)

    with_daylog_setup({
      defaults = {
        tag = "ClientA",
      },
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("DaylogToday 1")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), expected_path)
      -- Navigation only: the existing empty file is opened, not written to.
      t.eq(t.get_lines(), { "" })
      t.eq(vim.bo.modified, false)
    end)
  end)

  t.test("today opens an existing daybook file without changing it", function()
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
    local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", now) .. ".day"

    vim.fn.mkdir(expected_dir, "p")
    vim.fn.writefile({
      "--- log ---",
      "08:00 plan",
      "09:00 done",
    }, expected_path)

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("DaylogToday")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), expected_path)
      t.eq(t.get_lines(), {
        "--- log ---",
        "08:00 plan",
        "09:00 done",
      })
      t.ok(not vim.bo.modified)
    end)
  end)

  t.test("today nonzero offset opens an existing daybook file without changing it", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })
    local yesterday = os.time({
      year = 2026,
      month = 5,
      day = 17,
      hour = 12,
      min = 0,
      sec = 0,
    })
    local expected_dir = root .. "/" .. os.date("%Y", yesterday)
    local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", yesterday) .. ".day"

    vim.fn.mkdir(expected_dir, "p")
    vim.fn.writefile({
      "--- log ---",
      "08:00 plan",
      "09:00 done",
    }, expected_path)

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("DaylogToday -1")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), expected_path)
      t.eq(t.get_lines(), {
        "--- log ---",
        "08:00 plan",
        "09:00 done",
      })
      t.ok(not vim.bo.modified)
    end)
  end)

  t.test("today does nothing when daybook settings are missing", function()
    with_daylog_setup({}, function()
      vim.cmd("enew!")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "scratch" })
      vim.bo.modified = false

      vim.cmd("DaylogToday")

      t.eq(vim.api.nvim_buf_get_name(0), "")
      t.eq(t.get_lines(), { "scratch" })
    end)
  end)

  t.test("today rejects invalid day offsets and leaves the current buffer unchanged", function()
    local root = vim.fn.tempname()

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      t.reset({ "scratch" })

      for _, command in ipairs({
        "DaylogToday nope",
        "DaylogToday 1.5",
        "DaylogToday --1",
        "DaylogToday +",
      }) do
        with_captured_notify(function(messages)
          vim.cmd(command)

          t.eq(messages, {
            {
              message = "daylog: day offset must be an integer",
              level = vim.log.levels.WARN,
            },
          })
        end)

        t.eq(vim.api.nvim_buf_get_name(0), "")
        t.eq(t.get_lines(), { "scratch" })
      end
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

    with_daylog_setup({
      daybook = {
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

        vim.cmd("DaylogToday")

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

  t.test(
    "today nonzero offset does not create directories when current buffer has unsaved changes",
    function()
      local root = vim.fn.tempname()
      local now = os.time({
        year = 2026,
        month = 5,
        day = 18,
        hour = 8,
        min = 45,
        sec = 0,
      })
      local yesterday = os.time({
        year = 2026,
        month = 5,
        day = 17,
        hour = 12,
        min = 0,
        sec = 0,
      })
      local expected_dir = root .. "/" .. os.date("%Y", yesterday)
      local old_hidden = vim.o.hidden
      local old_autowrite = vim.o.autowrite
      local old_autowriteall = vim.o.autowriteall

      with_daylog_setup({
        daybook = {
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

          with_mocked_time(now, function()
            vim.cmd("DaylogToday -1")
          end)

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
    end
  )

  t.test("next day skips empty days to the next existing log", function()
    local root = vim.fn.tempname()
    local opened = os.time({ year = 2026, month = 5, day = 10, hour = 12, min = 0, sec = 0 })
    -- A gap (05-11) with no log is skipped; the next real log is 05-12.
    local next_day = os.time({ year = 2026, month = 5, day = 12, hour = 12, min = 0, sec = 0 })

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local open_path = write_daybook_file(root, "%Y", opened, {
        "--- log ---",
        "08:00 plan",
      })
      write_daybook_file(root, "%Y", next_day, {
        "--- log ---",
        "09:00 review",
      })
      vim.cmd("edit " .. vim.fn.fnameescape(open_path))
      vim.bo.modified = false

      vim.cmd("DaylogNextDay")

      local path = root
        .. "/"
        .. os.date("%Y", next_day)
        .. "/"
        .. os.date("%Y-%m-%d", next_day)
        .. ".day"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      t.eq(t.get_lines(), { "--- log ---", "09:00 review" })
    end)
  end)

  t.test("prev day count skips that many existing logs backward", function()
    local root = vim.fn.tempname()
    local opened = os.time({ year = 2026, month = 5, day = 10, hour = 12, min = 0, sec = 0 })
    -- Two existing logs precede the open day; the count walks past the first.
    local nearer = os.time({ year = 2026, month = 5, day = 9, hour = 12, min = 0, sec = 0 })
    local target = os.time({ year = 2026, month = 5, day = 8, hour = 12, min = 0, sec = 0 })

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local open_path = write_daybook_file(root, "%Y", opened, {
        "--- log ---",
      })
      write_daybook_file(root, "%Y", nearer, { "--- log ---", "08:00 a" })
      write_daybook_file(root, "%Y", target, { "--- log ---", "08:00 b" })
      vim.cmd("edit " .. vim.fn.fnameescape(open_path))
      vim.bo.modified = false

      vim.cmd("DaylogPrevDay 2")

      local path = root
        .. "/"
        .. os.date("%Y", target)
        .. "/"
        .. os.date("%Y-%m-%d", target)
        .. ".day"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      t.eq(t.get_lines(), { "--- log ---", "08:00 b" })
    end)
  end)

  t.test("relative navigation warns and stays when no log lies that way", function()
    local root = vim.fn.tempname()
    local opened = os.time({ year = 2026, month = 5, day = 10, hour = 12, min = 0, sec = 0 })

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local open_path = write_daybook_file(root, "%Y", opened, {
        "--- log ---",
        "08:00 plan",
      })
      vim.cmd("edit " .. vim.fn.fnameescape(open_path))
      vim.bo.modified = false

      -- The only log is the open one: there is nothing later or earlier.
      with_captured_notify(function(messages)
        vim.cmd("DaylogNextDay")
        t.eq(messages, {
          { message = "daylog: no later log", level = vim.log.levels.WARN },
        })
      end)
      t.eq(vim.api.nvim_buf_get_name(0), open_path)

      with_captured_notify(function(messages)
        vim.cmd("DaylogPrevDay")
        t.eq(messages, {
          { message = "daylog: no earlier log", level = vim.log.levels.WARN },
        })
      end)
      t.eq(vim.api.nvim_buf_get_name(0), open_path)
    end)
  end)

  t.test("prev day falls back to today when the buffer is not a daybook file", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })
    -- The nearest earlier log is several days back; today has no file.
    local earlier = os.time({ year = 2026, month = 5, day = 15, hour = 12, min = 0, sec = 0 })

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local earlier_path = write_daybook_file(root, "%Y", earlier, {
        "--- log ---",
        "08:00 plan",
      })
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        -- Anchored on today (the scratch buffer is not a daybook file), the prior
        -- log three days back is found.
        vim.cmd("DaylogPrevDay")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), earlier_path)
      t.eq(t.get_lines(), { "--- log ---", "08:00 plan" })
    end)
  end)

  t.test("stepping onto today does not insert the current time", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })
    local yesterday = os.time({
      year = 2026,
      month = 5,
      day = 17,
      hour = 12,
      min = 0,
      sec = 0,
    })

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local open_path = write_daybook_file(root, "%Y", yesterday, {
        "--- log ---",
      })
      -- Today already has a log, so navigation lands on it rather than seeding.
      local today_path = write_daybook_file(root, "%Y", now, {
        "--- log ---",
        "08:00 plan",
      })
      vim.cmd("edit " .. vim.fn.fnameescape(open_path))
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("DaylogNextDay")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      -- Navigation onto today opens the file as-is; no current time is inserted.
      t.eq(t.get_lines(), { "--- log ---", "08:00 plan" })
      t.eq(vim.bo.modified, false)
    end)
  end)

  t.test("init scaffolds a past day with a header and no current time", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 18, hour = 8, min = 45, sec = 0 })
    local target = os.time({ year = 2026, month = 5, day = 16, hour = 12, min = 0, sec = 0 })

    with_daylog_setup({
      defaults = {
        tag = "ClientA",
        quantize_minutes = 30,
        duration_format = "hm",
      },
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("DaylogInit -2")
      end)

      local path = root
        .. "/"
        .. os.date("%Y", target)
        .. "/"
        .. os.date("%Y-%m-%d", target)
        .. ".day"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      -- A header (with defaults) and an empty summary, but no timestamped entry.
      t.eq(t.get_lines(), {
        "--- log #ClientA q=30 d=hm ---",
        "",
        "",
        "--- summary q=30 d=hm ---",
        "",
        "--- totals ---",
        "0:00 (+0m) workday",
      })
    end)
  end)

  t.test("init opens an existing daybook day without changing it", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 18, hour = 8, min = 45, sec = 0 })
    local target = os.time({ year = 2026, month = 5, day = 20, hour = 12, min = 0, sec = 0 })
    local existing_path = write_daybook_file(root, "%Y", target, {
      "--- log ---",
      "08:00 plan",
      "09:00 done",
    })

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("DaylogInit 2")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), existing_path)
      t.eq(t.get_lines(), { "--- log ---", "08:00 plan", "09:00 done" })
      t.eq(vim.bo.modified, false)
    end)
  end)

  t.test("init rejects a non-integer offset and leaves the current buffer unchanged", function()
    local root = vim.fn.tempname()

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      t.reset({ "scratch" })

      with_captured_notify(function(messages)
        vim.cmd("DaylogInit nope")

        t.eq(messages, {
          { message = "daylog: day offset must be an integer", level = vim.log.levels.WARN },
        })
      end)

      t.eq(vim.api.nvim_buf_get_name(0), "")
      t.eq(t.get_lines(), { "scratch" })
    end)
  end)

  t.test("step commands reject invalid counts and leave the current buffer unchanged", function()
    local root = vim.fn.tempname()

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y",
      },
    }, function()
      t.reset({ "scratch" })

      for _, command in ipairs({
        "DaylogNextDay nope",
        "DaylogPrevDay 0",
        "DaylogNextDay 1.5",
        "DaylogPrevDay -1",
      }) do
        with_captured_notify(function(messages)
          vim.cmd(command)

          t.eq(messages, {
            {
              message = "daylog: days count must be a positive integer",
              level = vim.log.levels.WARN,
            },
          })
        end)

        t.eq(vim.api.nvim_buf_get_name(0), "")
        t.eq(t.get_lines(), { "scratch" })
      end
    end)
  end)

  t.test("a range report reflects unsaved edits in an open daybook buffer", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 12, min = 0, sec = 0 })
    local monday = os.time({ year = 2026, month = 5, day = 18, hour = 12, min = 0, sec = 0 })

    local monday_path = write_daybook_file(root, "%Y/%V", monday, {
      "--- log #ClientA @office q=30 ---",
      "08:00 plan",
      "09:00 done",
    })

    with_daylog_setup({
      defaults = {
        duration_format = "hm",
      },
      daybook = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("silent! only!")

      -- Open Monday and extend it to two hours without saving.
      vim.cmd("edit " .. vim.fn.fnameescape(monday_path))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "--- log #ClientA @office q=30 ---",
        "08:00 plan",
        "10:00 done",
      })
      t.ok(vim.bo.modified)

      with_mocked_time(now, function()
        vim.cmd("DaylogDays 2026-05-18..2026-05-22")
      end)

      local has_two_hours, has_one_hour = false, false
      for _, line in ipairs(t.get_lines()) do
        if line:match("^2:00 .* workday$") then
          has_two_hours = true
        elseif line:match("^1:00 .* workday$") then
          has_one_hour = true
        end
      end
      t.ok(has_two_hours, "report should use the buffer's two-hour day")
      t.ok(not has_one_hour, "disk's one-hour day leaked into the report")

      -- The reporting path must not write the unsaved buffer back to disk.
      t.eq(vim.fn.readfile(monday_path), {
        "--- log #ClientA @office q=30 ---",
        "08:00 plan",
        "09:00 done",
      })

      vim.cmd("silent! only!")
    end)
  end)

  t.test("a range report expands a home-relative daybook root before building it", function()
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

    with_temp_home_root(function(relative_root, expanded_root)
      write_daybook_file(expanded_root, "%Y/%V", monday, {
        "--- log ---",
        "08:00 plan",
        "09:00 done",
      })

      with_daylog_setup({
        daybook = {
          root = relative_root,
          directory = "%Y/%V",
        },
      }, function()
        vim.cmd("silent! only!")
        t.reset({ "notes" })

        with_mocked_time(now, function()
          vim.cmd("DaylogDays 2026-05-18..2026-05-22")
        end)

        t.eq(
          vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
          "daylog-days-2026-05-18..2026-05-22.day"
        )
        t.eq(t.get_lines()[1], "--- day summary 2026-05-18 q=15 ---")

        vim.cmd("silent! only!")
      end)
    end)
  end)

  t.test("days rejects malformed arguments", function()
    with_daylog_setup({}, function()
      t.reset({ "scratch" })

      local ok, err = pcall(vim.cmd, "DaylogDays")
      t.ok(not ok)
      t.ok(tostring(err):match("E471") ~= nil)

      local range_error = "daylog: expected a day count or a FROM..TO range "
        .. "(e.g. 2026-05-10..2026-05-20, monday.., ..today)"
      local count_error = "daylog: days count must be a positive integer"

      for _, case in ipairs({
        { "DaylogDays nope", range_error },
        { "DaylogDays 0", count_error },
        { "DaylogDays -1", range_error },
        { "DaylogDays 1.5", range_error },
        { "DaylogDays 2026-05-10", range_error },
      }) do
        with_captured_notify(function(messages)
          vim.cmd(case[1])

          t.eq(messages, { { message = case[2], level = vim.log.levels.WARN } })
        end)

        t.eq(t.get_lines(), { "scratch" })
      end
    end)
  end)

  t.test("days opens a scratch report for the last n daybook dates", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 22,
      hour = 12,
      min = 0,
      sec = 0,
    })
    local wednesday = os.time({
      year = 2026,
      month = 5,
      day = 20,
      hour = 12,
      min = 0,
      sec = 0,
    })
    local thursday = os.time({
      year = 2026,
      month = 5,
      day = 21,
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

    write_daybook_file(root, "%Y/%V", wednesday, {
      "--- log #ClientA @office q=30 ---",
      "08:00 plan",
      "08:20 implementation @home",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "stale",
    })
    write_daybook_file(root, "%Y/%V", thursday, {})
    write_daybook_file(root, "%Y/%V", friday, {
      "--- log #internal @home q=60 ---",
      "10:00 retro",
      "10:40 done",
      "",
      "--- summary q=15 d=dec ---",
      "stale",
    })

    with_daylog_setup({
      defaults = {
        duration_format = "hm",
      },
      daybook = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("silent! only!")
      t.reset({ "notes" })

      with_mocked_time(now, function()
        vim.cmd("DaylogDays 4")
      end)

      t.eq(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
        "daylog-days-2026-05-19..2026-05-22.day"
      )
      t.eq(t.get_lines(), {
        "--- day summary 2026-05-20 q=30 ---",
        "0:30 (+10m) implementation",
        "0:30 (-10m) plan",
        "",
        "--- day tags 2026-05-20 ---",
        "1:00 (+0m) #ClientA",
        "",
        "--- day locations 2026-05-20 ---",
        "0:30 (+10m) @home",
        "0:30 (-10m) @office",
        "",
        "--- day totals 2026-05-20 ---",
        "1:00 (+0m) workday",
        "",
        "--- day summary 2026-05-22 q=60 ---",
        "1:00 (-20m) retro",
        "",
        "--- day tags 2026-05-22 ---",
        "1:00 (-20m) #internal",
        "",
        "--- day locations 2026-05-22 ---",
        "1:00 (-20m) @home",
        "",
        "--- day totals 2026-05-22 ---",
        "1:00 (-20m) workday",
        "",
        "--- range summary 2026-05-20..2026-05-22 (2 found) ---",
        "1:00 (-20m) retro",
        "0:30 (+10m) implementation",
        "0:30 (-10m) plan",
        "",
        "--- range tags 2026-05-20..2026-05-22 (2 found) ---",
        "1:00 (+0m) #ClientA",
        "1:00 (-20m) #internal",
        "",
        "--- range locations 2026-05-20..2026-05-22 (2 found) ---",
        "1:30 (-10m) @home",
        "0:30 (-10m) @office",
        "",
        "--- range totals 2026-05-20..2026-05-22 (2 found) ---",
        "2:00 (-20m) workday",
      })

      vim.cmd("silent! only!")
    end)
  end)

  -- A small daybook with logs on 2026-05-18 and 2026-05-20 (week 21), nothing on the
  -- days between or after, used to exercise the range forms.
  local function with_range_daybook(now, fn)
    local root = vim.fn.tempname()
    local function ts(day)
      return os.time({ year = 2026, month = 5, day = day, hour = 12, min = 0, sec = 0 })
    end

    write_daybook_file(root, "%Y/%V", ts(18), {
      "--- log #ClientA @office q=60 ---",
      "08:00 plan",
      "09:00 done",
    })
    write_daybook_file(root, "%Y/%V", ts(20), {
      "--- log #ClientA @office q=60 ---",
      "10:00 review",
      "11:00 done",
    })

    with_daylog_setup({
      defaults = { duration_format = "hm" },
      daybook = { root = root, directory = "%Y/%V" },
    }, function()
      vim.cmd("silent! only!")
      t.reset({ "notes" })
      with_mocked_time(now, fn)
      vim.cmd("silent! only!")
    end)
  end

  local function report_name()
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
  end

  t.test("days reports an explicit range and skips missing days", function()
    -- 2026-05-17 (boundary) and 2026-05-19 (interior) have no file. The buffer name keeps
    -- the requested range, while the aggregate headers resolve to the span of days found
    -- (05-18..05-20) and carry a found-day count on every header.
    with_range_daybook(os.time({ year = 2026, month = 5, day = 22, hour = 12 }), function()
      vim.cmd("DaylogDays! 2026-05-17..2026-05-20")

      t.eq(report_name(), "daylog-days-summary-2026-05-17..2026-05-20.day")
      t.eq(t.get_lines(), {
        "--- range summary 2026-05-18..2026-05-20 (2 found) ---",
        "1:00 (+0m) plan",
        "1:00 (+0m) review",
        "",
        "--- range tags 2026-05-18..2026-05-20 (2 found) ---",
        "2:00 (+0m) #ClientA",
        "",
        "--- range locations 2026-05-18..2026-05-20 (2 found) ---",
        "2:00 (+0m) @office",
        "",
        "--- range totals 2026-05-18..2026-05-20 (2 found) ---",
        "2:00 (+0m) workday",
      })
    end)
  end)

  t.test("days resolves open-ended ranges against the daybook extent", function()
    -- The daybook has logs on 05-18 and 05-20 only; today (05-22) carries none.
    with_range_daybook(os.time({ year = 2026, month = 5, day = 22, hour = 12 }), function()
      -- FROM.. runs through the latest day on file (not today).
      vim.cmd("DaylogDays! 2026-05-20..")
      t.eq(report_name(), "daylog-days-summary-2026-05-20..2026-05-20.day")

      -- ..TO starts at the earliest logged day on file.
      vim.cmd("enew")
      vim.cmd("DaylogDays! ..2026-05-19")
      t.eq(report_name(), "daylog-days-summary-2026-05-18..2026-05-19.day")

      -- .. spans the earliest through the latest day on file.
      vim.cmd("enew")
      vim.cmd("DaylogDays! ..")
      t.eq(report_name(), "daylog-days-summary-2026-05-18..2026-05-20.day")

      -- A named token resolves: monday.. is the week's Monday through the latest log.
      vim.cmd("enew")
      vim.cmd("DaylogDays! monday..")
      t.eq(report_name(), "daylog-days-summary-2026-05-18..2026-05-20.day")
    end)
  end)

  t.test("an open right end reaches future-dated files", function()
    local root = vim.fn.tempname()
    local function ts(day)
      return os.time({ year = 2026, month = 5, day = day, hour = 12, min = 0, sec = 0 })
    end
    -- A log dated after "today" (05-22): an open right end must include it.
    write_daybook_file(root, "%Y/%V", ts(20), { "--- log ---", "10:00 review", "11:00 done" })
    write_daybook_file(root, "%Y/%V", ts(25), { "--- log ---", "10:00 plan ahead", "11:00 done" })

    with_daylog_setup({
      defaults = { duration_format = "hm" },
      daybook = { root = root, directory = "%Y/%V" },
    }, function()
      vim.cmd("silent! only!")
      t.reset({ "notes" })
      with_mocked_time(ts(22), function()
        vim.cmd("DaylogDays! 2026-05-20..")
      end)
      t.eq(report_name(), "daylog-days-summary-2026-05-20..2026-05-25.day")
      vim.cmd("silent! only!")
    end)
  end)

  t.test("days rejects reversed, invalid, and empty ranges", function()
    with_range_daybook(os.time({ year = 2026, month = 5, day = 22, hour = 12 }), function()
      local cases = {
        { "DaylogDays 2026-05-20..2026-05-18", "daylog: range start is after end" },
        { "DaylogDays 2026-13-01..2026-05-20", "daylog: invalid date: 2026-13-01" },
        { "DaylogDays 2026-05-18..2026-99-99", "daylog: invalid date: 2026-99-99" },
        { "DaylogDays ..2026-05-10", "daylog: no daybook logs found" },
      }

      for _, case in ipairs(cases) do
        with_captured_notify(function(messages)
          vim.cmd(case[1])

          t.eq(messages, { { message = case[2], level = vim.log.levels.WARN } })
        end)
      end
    end)
  end)

  t.test("days bang opens only the range aggregate scratch report", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 22,
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

    write_daybook_file(root, "%Y/%V", friday, {
      "--- log #internal @home q=60 ---",
      "10:00 retro",
      "11:00 done",
    })

    with_daylog_setup({
      defaults = {
        duration_format = "hm",
      },
      daybook = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("silent! only!")
      t.reset({ "notes" })

      with_mocked_time(now, function()
        vim.cmd("DaylogDays! 3")
      end)

      t.eq(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
        "daylog-days-summary-2026-05-20..2026-05-22.day"
      )
      t.eq(t.get_lines(), {
        "--- range summary 2026-05-22..2026-05-22 (1 found) ---",
        "1:00 (+0m) retro",
        "",
        "--- range tags 2026-05-22..2026-05-22 (1 found) ---",
        "1:00 (+0m) #internal",
        "",
        "--- range locations 2026-05-22..2026-05-22 (1 found) ---",
        "1:00 (+0m) @home",
        "",
        "--- range totals 2026-05-22..2026-05-22 (1 found) ---",
        "1:00 (+0m) workday",
      })

      vim.cmd("silent! only!")
    end)
  end)

  t.test("days warns and leaves the current buffer unchanged when no daily files exist", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 22,
      hour = 12,
      min = 0,
      sec = 0,
    })

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("silent! only!")
      t.reset({ "scratch" })

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("DaylogDays 3")
        end)

        t.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
        t.eq(vim.api.nvim_buf_get_name(0), "")
        t.eq(t.get_lines(), { "scratch" })
        t.eq(messages, {
          {
            message = "daylog: no daybook logs found",
            level = vim.log.levels.WARN,
          },
        })
      end)
    end)
  end)

  t.test("days aborts on invalid existing files and includes the file path", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 22,
      hour = 12,
      min = 0,
      sec = 0,
    })
    local thursday = os.time({
      year = 2026,
      month = 5,
      day = 21,
      hour = 12,
      min = 0,
      sec = 0,
    })
    local bad_path = write_daybook_file(root, "%Y/%V", thursday, {
      "--- log ---",
      "09:00 done",
      "08:00 plan",
    })

    with_daylog_setup({
      daybook = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      t.reset({ "scratch" })

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("DaylogDays 3")
        end)

        t.eq(vim.api.nvim_buf_get_name(0), "")
        t.eq(t.get_lines(), { "scratch" })
        t.eq(messages, {
          {
            message = "daylog: "
              .. bad_path
              .. ": unordered timestamps near lines 2 and 3; fix manually or run :DaylogOrder",
            level = vim.log.levels.WARN,
          },
        })
      end)
    end)
  end)

  t.test("days report refreshes when a dependent daybook buffer changes", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local day_one = os.time({ year = 2026, month = 5, day = 18, hour = 12, min = 0, sec = 0 })

    local day_one_path = write_daybook_file(root, "%Y", day_one, {
      "--- log #ClientA @office q=30 ---",
      "08:00 plan",
      "09:00 done",
    })

    with_daylog_setup({
      auto_summary = "save",
      defaults = { duration_format = "hm" },
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("silent! only!")

      vim.cmd("edit " .. vim.fn.fnameescape(day_one_path))
      local source_buf = vim.api.nvim_get_current_buf()
      local source_win = vim.api.nvim_get_current_win()

      with_mocked_time(now, function()
        vim.cmd("DaylogDays 2")
      end)
      local report_buf = vim.api.nvim_get_current_buf()

      t.ok(report_has_workday(report_buf, "1:00"))

      vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
        "--- log #ClientA @office q=30 ---",
        "08:00 plan",
        "10:00 done",
      })
      vim.api.nvim_set_current_win(source_win)
      with_mocked_time(now, function()
        vim.api.nvim_exec_autocmds("BufWritePre", { buffer = source_buf })
      end)

      t.ok(report_has_workday(report_buf, "2:00"))
      t.ok(not report_has_workday(report_buf, "1:00"))

      vim.cmd("silent! only!")
    end)
  end)

  t.test("the date guard recognizes a relative daybook root", function()
    -- A relative daybook.root must be absolutized so the buffer's date is
    -- recognized; otherwise the time guard silently disables itself.
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local previous_cwd = vim.fn.getcwd()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 9, min = 0, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })

    local ok, err = pcall(function()
      vim.cmd("cd " .. vim.fn.fnameescape(tmp))
      write_daybook_file("rel-daybook", "%Y", yesterday, {
        "--- log #ClientA @office ---",
        "08:00 planning",
        "17:00",
      })

      with_daylog_setup({
        daybook = { root = "rel-daybook", directory = "%Y" },
      }, function()
        vim.cmd("edit rel-daybook/2026/2026-05-21.day")
        t.set_cursor(2, 0)

        with_captured_notify(function(messages)
          with_mocked_time(now, function()
            vim.cmd("DaylogInsert")
          end)

          t.eq(messages, {
            {
              message = "daylog: this file is dated 2026-05-21, not today (2026-05-22); "
                .. "refusing to insert the current time",
              level = vim.log.levels.WARN,
            },
          })
        end)

        t.eq(t.get_lines(), {
          "--- log #ClientA @office ---",
          "08:00 planning",
          "17:00",
        })
      end)
    end)

    vim.cmd("cd " .. vim.fn.fnameescape(previous_cwd))
    vim.fn.delete(tmp, "rf")

    if not ok then
      error(err, 0)
    end
  end)

  t.test("insert refuses to stamp the current time into a non-today daybook file", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 9, min = 0, sec = 0 })
    local past = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local path = write_daybook_file(root, "%Y", past, {
      "--- log ---",
      "08:00 plan",
    })

    with_daylog_setup({
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      t.set_cursor(2, 0)

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("DaylogInsert")
        end)

        t.eq(messages, {
          {
            message = "daylog: this file is dated 2026-05-19, not today (2026-05-22); "
              .. "refusing to insert the current time",
            level = vim.log.levels.WARN,
          },
        })
      end)

      t.eq(t.get_lines(), {
        "--- log ---",
        "08:00 plan",
      })
    end)
  end)

  t.test("insert proceeds on a buffer that is not a daybook file", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 9, min = 0, sec = 0 })

    with_daylog_setup({
      daybook = { root = root, directory = "%Y" },
    }, function()
      t.reset({
        "--- log ---",
        "08:00 plan",
      })

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("DaylogInsert")
        end)

        t.eq(messages, {})
      end)

      local inserted = 0
      for _, line in ipairs(t.get_lines()) do
        if line:match("^%d%d:%d%d $") then
          inserted = inserted + 1
        end
      end
      t.eq(inserted, 1)
    end)
  end)

  t.test("insert proceeds normally on today's daybook file", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 9, min = 0, sec = 0 })
    local path = write_daybook_file(root, "%Y", now, {
      "--- log ---",
      "08:00 plan",
    })

    with_daylog_setup({
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      t.set_cursor(2, 0)

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("DaylogInsert")
        end)

        t.eq(messages, {})
      end)

      -- The inserted clock time comes from the real wall clock, so assert shape
      -- rather than an exact value: one fresh empty timestamp line was added.
      local lines = t.get_lines()
      t.eq(#lines, 3)
      t.eq(lines[1], "--- log ---")
      local inserted = 0
      for _, line in ipairs(lines) do
        if line:match("^%d%d:%d%d $") then
          inserted = inserted + 1
        end
      end
      t.eq(inserted, 1)
    end)
  end)

  t.test("carryover refreshes the previous day's summary before saving it", function()
    local refresh_summaries = require("daylog.usecases.refresh_summaries")
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_daybook_file(root, "%Y", yesterday, {
      "--- log #ClientA @office ---",
      "08:00 standup",
      "10:30 writing report",
      "",
      "--- summary q=15 d=dec ---",
      "2.50h standup",
      "",
      "--- totals ---",
      "2.50h workday",
    })

    with_daylog_setup({
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(3, 0)

      with_mocked_confirm(1, function()
        with_mocked_time(now, function()
          vim.cmd("DaylogInsert")
        end)
      end)

      -- The carried-over 24:00 close was written, and the previous day's summary
      -- was refreshed to match (no drift) instead of being saved stale.
      local saved = vim.fn.readfile(yesterday_path)
      local has_summary = false
      for _, line in ipairs(saved) do
        if line:match("^%-%-%- summary") then
          has_summary = true
        end
      end
      t.ok(has_summary, "previous day kept its summary")
      t.eq(#(refresh_summaries.run(saved).edits or {}), 0)
    end)
  end)

  t.test("insert past midnight carries the running task into today", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_daybook_file(root, "%Y", yesterday, {
      "--- log #ClientA @office ---",
      "22:30 writing report",
    })
    local today_path = root .. "/2026/2026-05-22.day"

    with_daylog_setup({
      defaults = { tag = "ClientA", location = "office" },
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_mocked_confirm(1, function()
        with_mocked_time(now, function()
          vim.cmd("DaylogInsert")
        end)
      end)

      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      t.eq(t.get_lines(), {
        "--- log #ClientA @office ---",
        "00:00 writing report",
        "00:47 ",
      })
      -- The pre-save refresh closes yesterday at 24:00 and gives it a summary.
      t.eq(vim.fn.readfile(yesterday_path), {
        "--- log #ClientA @office ---",
        "22:30 writing report",
        "24:00",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "1.50h (+0m) writing report",
        "",
        "--- tags ---",
        "1.50h (+0m) #ClientA",
        "",
        "--- locations ---",
        "1.50h (+0m) @office",
        "",
        "--- totals ---",
        "1.50h (+0m) workday",
      })
    end)
  end)

  t.test("repeat on another day brings the cursor activity into today", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local past = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local past_path = write_daybook_file(root, "%Y", past, {
      "--- log #ClientA @office ---",
      "08:00 deep work",
      "09:00 done",
    })
    local today_path = root .. "/2026/2026-05-22.day"

    with_daylog_setup({
      defaults = { tag = "ClientA", location = "office" },
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(past_path))
      t.set_cursor(2, 0)

      with_mocked_time(now, function()
        vim.cmd("DaylogRepeat")
      end)

      -- Switched to a fresh today, with the activity at the current time.
      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      t.eq(t.get_lines(), {
        "--- log #ClientA @office ---",
        "10:00 deep work",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "",
        "--- totals ---",
        "0.00h (+0m) workday",
      })
      -- The browsed day is left untouched.
      t.eq(vim.fn.readfile(past_path), {
        "--- log #ClientA @office ---",
        "08:00 deep work",
        "09:00 done",
      })
    end)
  end)

  t.test("repeat from another day inserts into an existing today log", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local past = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local past_path = write_daybook_file(root, "%Y", past, {
      "--- log #ClientA @office ---",
      "08:00 deep work",
      "09:00 done",
    })
    local today = os.time({ year = 2026, month = 5, day = 22, hour = 12, min = 0, sec = 0 })
    local today_path = write_daybook_file(root, "%Y", today, {
      "--- log #ClientA @office ---",
      "08:00 standup",
      "09:00 done",
    })

    with_daylog_setup({
      defaults = { tag = "ClientA", location = "office" },
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(past_path))
      t.set_cursor(2, 0)

      with_mocked_time(now, function()
        vim.cmd("DaylogRepeat")
      end)

      -- deep work is inserted at 10:00, after the existing entries.
      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      local lines = t.get_lines()
      t.eq(lines[2], "08:00 standup")
      t.eq(lines[3], "09:00 done")
      t.eq(lines[4], "10:00 deep work")
    end)
  end)

  t.test("repeat on another day with the cursor off an entry warns and does nothing", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local past = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local past_path = write_daybook_file(root, "%Y", past, {
      "--- log #ClientA @office ---",
      "08:00 deep work",
      "09:00 done",
    })

    with_daylog_setup({
      defaults = { tag = "ClientA", location = "office" },
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(past_path))
      t.set_cursor(1, 0)

      with_mocked_time(now, function()
        vim.cmd("DaylogRepeat")
      end)

      -- Stayed on the browsed day, unchanged.
      t.eq(vim.api.nvim_buf_get_name(0), past_path)
      t.eq(t.get_lines(), {
        "--- log #ClientA @office ---",
        "08:00 deep work",
        "09:00 done",
      })
    end)
  end)

  t.test("repeat on another day reports a broken today without leaving the browsed day", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local past = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local past_path = write_daybook_file(root, "%Y", past, {
      "--- log #ClientA @office ---",
      "08:00 deep work",
      "09:00 done",
    })
    local today = os.time({ year = 2026, month = 5, day = 22, hour = 8, min = 0, sec = 0 })
    -- today already has out-of-order entries, so the activity cannot be seeded into it.
    write_daybook_file(root, "%Y", today, {
      "--- log #ClientA @office ---",
      "09:00 later",
      "08:00 earlier",
    })

    with_daylog_setup({
      defaults = { tag = "ClientA", location = "office" },
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(past_path))
      t.set_cursor(2, 0)

      with_mocked_time(now, function()
        vim.cmd("DaylogRepeat")
      end)

      -- Stayed on the browsed day rather than being switched onto the broken today.
      t.eq(vim.api.nvim_buf_get_name(0), past_path)
    end)
  end)

  t.test("repeat on another day initializes a whitespace-only today", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local past = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local past_path = write_daybook_file(root, "%Y", past, {
      "--- log #ClientA @office ---",
      "08:00 deep work",
      "09:00 done",
    })
    local today = os.time({ year = 2026, month = 5, day = 22, hour = 8, min = 0, sec = 0 })
    local today_path = write_daybook_file(root, "%Y", today, { "", "  ", "" })

    with_daylog_setup({
      defaults = { tag = "ClientA", location = "office" },
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(past_path))
      t.set_cursor(2, 0)

      with_mocked_time(now, function()
        vim.cmd("DaylogRepeat")
      end)

      -- The whitespace today is initialized fresh, with the header on line 1.
      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      local lines = t.get_lines()
      t.eq(lines[1], "--- log #ClientA @office ---")
      t.eq(lines[2], "10:00 deep work")
    end)
  end)

  t.test("repeat past midnight carries the running task and repeats the cursor entry", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_daybook_file(root, "%Y", yesterday, {
      "--- log #ClientA @office ---",
      "20:00 standup",
      "22:30 writing report",
    })
    local today_path = root .. "/2026/2026-05-22.day"

    with_daylog_setup({
      defaults = { tag = "ClientA", location = "office" },
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_mocked_confirm(1, function()
        with_mocked_time(now, function()
          vim.cmd("DaylogRepeat")
        end)
      end)

      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      t.eq(t.get_lines(), {
        "--- log #ClientA @office ---",
        "00:00 writing report",
        "00:47 standup",
      })
      -- The pre-save refresh closes yesterday at 24:00 and gives it a summary.
      t.eq(vim.fn.readfile(yesterday_path), {
        "--- log #ClientA @office ---",
        "20:00 standup",
        "22:30 writing report",
        "24:00",
        "",
        "",
        "--- summary q=15 d=dec ---",
        "2.50h (+0m) standup",
        "1.50h (+0m) writing report",
        "",
        "--- tags ---",
        "4.00h (+0m) #ClientA",
        "",
        "--- locations ---",
        "4.00h (+0m) @office",
        "",
        "--- totals ---",
        "4.00h (+0m) workday",
      })
    end)
  end)

  t.test("insert past midnight leaves both days untouched when declined", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_daybook_file(root, "%Y", yesterday, {
      "--- log #ClientA @office ---",
      "22:30 writing report",
    })
    local today_path = root .. "/2026/2026-05-22.day"

    with_daylog_setup({
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_mocked_confirm(2, function()
        with_mocked_time(now, function()
          vim.cmd("DaylogInsert")
        end)
      end)

      t.eq(vim.api.nvim_buf_get_name(0), yesterday_path)
      t.eq(t.get_lines(), {
        "--- log #ClientA @office ---",
        "22:30 writing report",
      })
      t.eq(vim.fn.filereadable(today_path), 0)
    end)
  end)

  t.test("insert past midnight refuses when today's log already exists", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_daybook_file(root, "%Y", yesterday, {
      "--- log #ClientA @office ---",
      "22:30 writing report",
    })
    write_daybook_file(root, "%Y", now, {
      "--- log ---",
      "00:10 already here",
    })

    with_daylog_setup({
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_captured_notify(function(messages)
        with_mocked_confirm(1, function()
          with_mocked_time(now, function()
            vim.cmd("DaylogInsert")
          end)
        end)

        t.eq(messages, {
          {
            message = "daylog: today's log already exists; open it with :DaylogToday",
            level = vim.log.levels.WARN,
          },
        })
      end)

      t.eq(vim.api.nvim_buf_get_name(0), yesterday_path)
      t.eq(t.get_lines(), {
        "--- log #ClientA @office ---",
        "22:30 writing report",
      })
    end)
  end)

  t.test("insert past midnight refuses when an unsaved today buffer exists", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_daybook_file(root, "%Y", yesterday, {
      "--- log #ClientA @office ---",
      "22:30 writing report",
    })
    local today_path = root .. "/2026/2026-05-22.day"

    with_daylog_setup({
      daybook = { root = root, directory = "%Y" },
    }, function()
      -- Today exists only as an unsaved buffer, never written to disk.
      vim.cmd("edit " .. vim.fn.fnameescape(today_path))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "--- log ---",
        "00:10 already here",
      })

      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_captured_notify(function(messages)
        with_mocked_confirm(1, function()
          with_mocked_time(now, function()
            vim.cmd("DaylogInsert")
          end)
        end)

        t.eq(messages, {
          {
            message = "daylog: today's log already exists; open it with :DaylogToday",
            level = vim.log.levels.WARN,
          },
        })
      end)

      t.eq(vim.api.nvim_buf_get_name(0), yesterday_path)
      t.eq(t.get_lines(), {
        "--- log #ClientA @office ---",
        "22:30 writing report",
      })
      t.eq(vim.fn.filereadable(today_path), 0)
    end)
  end)

  t.test("repeat past midnight inserts the cursor entry into an existing today on disk", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    -- Yesterday ends with a still-running task, so without the fix this would take
    -- the carryover branch and refuse because today already exists.
    local yesterday_path = write_daybook_file(root, "%Y", yesterday, {
      "--- log #ClientA @office ---",
      "20:00 standup",
      "22:30 writing report",
    })
    local today_path = write_daybook_file(root, "%Y", now, {
      "--- log #ClientA @office ---",
      "08:00 morning sync",
      "09:00 done",
    })

    with_daylog_setup({
      defaults = { tag = "ClientA", location = "office" },
      daybook = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      -- No confirm is mocked: the carryover prompt must never appear, since this is
      -- a plain cross-day repeat into the existing today.
      with_mocked_time(now, function()
        vim.cmd("DaylogRepeat")
      end)

      -- Switched to today, with the cursor entry brought in at the current time.
      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      local lines = t.get_lines()
      t.eq(lines[1], "--- log #ClientA @office ---")
      t.eq(lines[2], "08:00 morning sync")
      t.eq(lines[3], "09:00 done")
      t.eq(lines[4], "10:00 standup")

      -- Yesterday is left untouched -- not closed at 24:00, not saved -- proving the
      -- cross-day repeat ran rather than the carryover.
      t.eq(vim.fn.readfile(yesterday_path), {
        "--- log #ClientA @office ---",
        "20:00 standup",
        "22:30 writing report",
      })
    end)
  end)

  t.test("repeat past midnight inserts the cursor entry into an unsaved today buffer", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_daybook_file(root, "%Y", yesterday, {
      "--- log #ClientA @office ---",
      "20:00 standup",
      "22:30 writing report",
    })
    local today_path = root .. "/2026/2026-05-22.day"

    with_daylog_setup({
      defaults = { tag = "ClientA", location = "office" },
      daybook = { root = root, directory = "%Y" },
    }, function()
      -- Today exists only as an unsaved buffer, never written to disk.
      vim.cmd("edit " .. vim.fn.fnameescape(today_path))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "--- log #ClientA @office ---",
        "08:00 morning sync",
        "09:00 done",
      })

      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_mocked_time(now, function()
        vim.cmd("DaylogRepeat")
      end)

      -- Switched to the unsaved today buffer, with the entry inserted there.
      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      local lines = t.get_lines()
      t.eq(lines[2], "08:00 morning sync")
      t.eq(lines[3], "09:00 done")
      t.eq(lines[4], "10:00 standup")

      -- The unsaved today was edited in place; nothing was persisted to disk, and
      -- yesterday is untouched.
      t.eq(vim.fn.filereadable(today_path), 0)
      t.eq(vim.fn.readfile(yesterday_path), {
        "--- log #ClientA @office ---",
        "20:00 standup",
        "22:30 writing report",
      })
    end)
  end)
end
