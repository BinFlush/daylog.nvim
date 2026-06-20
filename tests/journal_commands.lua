return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_captured_notify = helpers.with_captured_notify
  local with_mocked_confirm = helpers.with_mocked_confirm
  local with_mocked_time = helpers.with_mocked_time
  local with_temp_home_root = helpers.with_temp_home_root
  local with_blotter_setup = helpers.with_blotter_setup
  local write_journal_file = helpers.write_journal_file

  helpers.setup_blotter()

  local function report_has_workday(buf, prefix)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:match("^" .. prefix .. " .* workday$") then
        return true
      end
    end
    return false
  end

  t.test("today opens a new journal file and initializes the first blot", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    with_blotter_setup({
      defaults = {
        tag = "ClientA",
        location = "office",
        quantize_minutes = 30,
        duration_format = "hm",
      },
      journal = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("BlotterToday")
      end)

      local expected_dir = root .. "/" .. os.date("%Y/%V", now)
      local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", now) .. ".blot"

      t.eq(vim.fn.isdirectory(expected_dir), 1)
      t.eq(vim.api.nvim_buf_get_name(0), expected_path)
      t.eq(t.get_lines(), {
        "--- blots #ClientA @office q=30 d=hm ---",
        "08:45 ",
        "",
        "--- summary q=30 d=hm ---",
        "",
        "--- totals ---",
        "0:00 (+0m) workday",
      })
      t.eq(vim.api.nvim_win_get_cursor(0), { 2, 6 })
    end)
  end)

  t.test("today reopened after navigating away does not duplicate the seeded blotter", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 18, hour = 8, min = 45, sec = 0 })

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        -- Seed today, then leave it unsaved.
        vim.cmd("BlotterToday")
        local seeded = t.get_lines()

        -- Navigate away (the unsaved buffer survives because hidden is set) and
        -- back: reopening today must reuse that buffer, not append a duplicate.
        -- BlotterToday -1 is an exact jump (PrevDay would find no earlier blotter).
        vim.cmd("BlotterToday -1")
        vim.cmd("BlotterToday")

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

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("BlotterToday 0")
      end)

      t.eq(
        vim.api.nvim_buf_get_name(0),
        root .. "/" .. os.date("%Y", now) .. "/" .. os.date("%Y-%m-%d", now) .. ".blot"
      )
      t.eq(t.get_lines(), {
        "--- blots ---",
        "08:45 ",
        "",
        "--- summary q=15 d=dec ---",
        "",
        "--- totals ---",
        "0.00h (+0m) workday",
      })
      t.eq(vim.api.nvim_win_get_cursor(0), { 2, 6 })
    end)
  end)

  t.test("today negative offset opens yesterday's dated journal file", function()
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

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("BlotterToday -1")
      end)

      local path = root
        .. "/"
        .. os.date("%Y", yesterday)
        .. "/"
        .. os.date("%Y-%m-%d", yesterday)
        .. ".blot"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      -- Navigation only: an empty, unmodified buffer with nothing written to disk.
      t.eq(t.get_lines(), { "" })
      t.eq(vim.bo.modified, false)
      t.eq(vim.fn.filereadable(path), 0)
    end)
  end)

  t.test("today positive offset opens tomorrow's dated journal file", function()
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

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("BlotterToday +1")
      end)

      local path = root
        .. "/"
        .. os.date("%Y", tomorrow)
        .. "/"
        .. os.date("%Y-%m-%d", tomorrow)
        .. ".blot"
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
    local earlier_path = write_journal_file(root, "%Y", earlier, {
      "--- blots ---",
      "08:00 plan",
    })
    local today_path = write_journal_file(root, "%Y", now, {
      "--- blots #ClientA @office ---",
      "09:00 later",
      "08:00 earlier",
    })

    with_blotter_setup({
      defaults = { tag = "ClientA", location = "office" },
      journal = { root = root, directory = "%Y" },
    }, function()
      with_mocked_time(now, function()
        vim.cmd("edit " .. vim.fn.fnameescape(today_path))

        -- The out-of-order blots keep navigation on today.
        vim.cmd("BlotterPrevDay")
        t.eq(vim.api.nvim_buf_get_name(0), today_path)

        -- Fixing the order releases the guard; navigation skips to the prior blotter.
        vim.api.nvim_buf_set_lines(0, 1, 3, false, { "08:00 earlier", "09:00 later" })
        vim.cmd("BlotterPrevDay")
        t.eq(vim.api.nvim_buf_get_name(0), earlier_path)
      end)
    end)
  end)

  t.test("today expands a home-relative journal root before opening", function()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })

    with_temp_home_root(function(relative_root, expanded_root)
      with_blotter_setup({
        journal = {
          root = relative_root,
          directory = "%Y",
        },
      }, function()
        vim.cmd("enew!")
        vim.bo.modified = false

        with_mocked_time(now, function()
          vim.cmd("BlotterToday")
        end)

        t.eq(
          vim.api.nvim_buf_get_name(0),
          expanded_root .. "/" .. os.date("%Y", now) .. "/" .. os.date("%Y-%m-%d", now) .. ".blot"
        )
      end)
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
    local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", now) .. ".blot"

    vim.fn.mkdir(expected_dir, "p")
    vim.fn.writefile({}, expected_path)

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("BlotterToday")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), expected_path)
      t.eq(t.get_lines(), {
        "--- blots ---",
        "08:45 ",
        "",
        "--- summary q=15 d=dec ---",
        "",
        "--- totals ---",
        "0.00h (+0m) workday",
      })
    end)
  end)

  t.test("today nonzero offset opens an existing empty journal file without writing", function()
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
    local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", tomorrow) .. ".blot"

    vim.fn.mkdir(expected_dir, "p")
    vim.fn.writefile({}, expected_path)

    with_blotter_setup({
      defaults = {
        tag = "ClientA",
      },
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("BlotterToday 1")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), expected_path)
      -- Navigation only: the existing empty file is opened, not written to.
      t.eq(t.get_lines(), { "" })
      t.eq(vim.bo.modified, false)
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
    local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", now) .. ".blot"

    vim.fn.mkdir(expected_dir, "p")
    vim.fn.writefile({
      "--- blots ---",
      "08:00 plan",
      "09:00 done",
    }, expected_path)

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("BlotterToday")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), expected_path)
      t.eq(t.get_lines(), {
        "--- blots ---",
        "08:00 plan",
        "09:00 done",
      })
      t.ok(not vim.bo.modified)
    end)
  end)

  t.test("today nonzero offset opens an existing journal file without changing it", function()
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
    local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", yesterday) .. ".blot"

    vim.fn.mkdir(expected_dir, "p")
    vim.fn.writefile({
      "--- blots ---",
      "08:00 plan",
      "09:00 done",
    }, expected_path)

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("BlotterToday -1")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), expected_path)
      t.eq(t.get_lines(), {
        "--- blots ---",
        "08:00 plan",
        "09:00 done",
      })
      t.ok(not vim.bo.modified)
    end)
  end)

  t.test("today does nothing when journal settings are missing", function()
    with_blotter_setup({}, function()
      vim.cmd("enew!")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "scratch" })
      vim.bo.modified = false

      vim.cmd("BlotterToday")

      t.eq(vim.api.nvim_buf_get_name(0), "")
      t.eq(t.get_lines(), { "scratch" })
    end)
  end)

  t.test("today rejects invalid day offsets and leaves the current buffer unchanged", function()
    local root = vim.fn.tempname()

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      t.reset({ "scratch" })

      for _, command in ipairs({
        "BlotterToday nope",
        "BlotterToday 1.5",
        "BlotterToday --1",
        "BlotterToday +",
      }) do
        with_captured_notify(function(messages)
          vim.cmd(command)

          t.eq(messages, {
            {
              message = "blotter: day offset must be an integer",
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

    with_blotter_setup({
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

        vim.cmd("BlotterToday")

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

      with_blotter_setup({
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

          with_mocked_time(now, function()
            vim.cmd("BlotterToday -1")
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

  t.test("next day skips empty days to the next existing blotter", function()
    local root = vim.fn.tempname()
    local opened = os.time({ year = 2026, month = 5, day = 10, hour = 12, min = 0, sec = 0 })
    -- A gap (05-11) with no blotter is skipped; the next real blotter is 05-12.
    local next_day = os.time({ year = 2026, month = 5, day = 12, hour = 12, min = 0, sec = 0 })

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local open_path = write_journal_file(root, "%Y", opened, {
        "--- blots ---",
        "08:00 plan",
      })
      write_journal_file(root, "%Y", next_day, {
        "--- blots ---",
        "09:00 review",
      })
      vim.cmd("edit " .. vim.fn.fnameescape(open_path))
      vim.bo.modified = false

      vim.cmd("BlotterNextDay")

      local path = root
        .. "/"
        .. os.date("%Y", next_day)
        .. "/"
        .. os.date("%Y-%m-%d", next_day)
        .. ".blot"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      t.eq(t.get_lines(), { "--- blots ---", "09:00 review" })
    end)
  end)

  t.test("prev day count skips that many existing blotters backward", function()
    local root = vim.fn.tempname()
    local opened = os.time({ year = 2026, month = 5, day = 10, hour = 12, min = 0, sec = 0 })
    -- Two existing blotters precede the open day; the count walks past the first.
    local nearer = os.time({ year = 2026, month = 5, day = 9, hour = 12, min = 0, sec = 0 })
    local target = os.time({ year = 2026, month = 5, day = 8, hour = 12, min = 0, sec = 0 })

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local open_path = write_journal_file(root, "%Y", opened, {
        "--- blots ---",
      })
      write_journal_file(root, "%Y", nearer, { "--- blots ---", "08:00 a" })
      write_journal_file(root, "%Y", target, { "--- blots ---", "08:00 b" })
      vim.cmd("edit " .. vim.fn.fnameescape(open_path))
      vim.bo.modified = false

      vim.cmd("BlotterPrevDay 2")

      local path = root
        .. "/"
        .. os.date("%Y", target)
        .. "/"
        .. os.date("%Y-%m-%d", target)
        .. ".blot"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      t.eq(t.get_lines(), { "--- blots ---", "08:00 b" })
    end)
  end)

  t.test("relative navigation warns and stays when no blotter lies that way", function()
    local root = vim.fn.tempname()
    local opened = os.time({ year = 2026, month = 5, day = 10, hour = 12, min = 0, sec = 0 })

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local open_path = write_journal_file(root, "%Y", opened, {
        "--- blots ---",
        "08:00 plan",
      })
      vim.cmd("edit " .. vim.fn.fnameescape(open_path))
      vim.bo.modified = false

      -- The only blotter is the open one: there is nothing later or earlier.
      with_captured_notify(function(messages)
        vim.cmd("BlotterNextDay")
        t.eq(messages, {
          { message = "blotter: no later blotter", level = vim.log.levels.WARN },
        })
      end)
      t.eq(vim.api.nvim_buf_get_name(0), open_path)

      with_captured_notify(function(messages)
        vim.cmd("BlotterPrevDay")
        t.eq(messages, {
          { message = "blotter: no earlier blotter", level = vim.log.levels.WARN },
        })
      end)
      t.eq(vim.api.nvim_buf_get_name(0), open_path)
    end)
  end)

  t.test("prev day falls back to today when the buffer is not a journal file", function()
    local root = vim.fn.tempname()
    local now = os.time({
      year = 2026,
      month = 5,
      day = 18,
      hour = 8,
      min = 45,
      sec = 0,
    })
    -- The nearest earlier blotter is several days back; today has no file.
    local earlier = os.time({ year = 2026, month = 5, day = 15, hour = 12, min = 0, sec = 0 })

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local earlier_path = write_journal_file(root, "%Y", earlier, {
        "--- blots ---",
        "08:00 plan",
      })
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        -- Anchored on today (the scratch buffer is not a journal file), the prior
        -- blotter three days back is found.
        vim.cmd("BlotterPrevDay")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), earlier_path)
      t.eq(t.get_lines(), { "--- blots ---", "08:00 plan" })
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

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local open_path = write_journal_file(root, "%Y", yesterday, {
        "--- blots ---",
      })
      -- Today already has a blotter, so navigation lands on it rather than seeding.
      local today_path = write_journal_file(root, "%Y", now, {
        "--- blots ---",
        "08:00 plan",
      })
      vim.cmd("edit " .. vim.fn.fnameescape(open_path))
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("BlotterNextDay")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      -- Navigation onto today opens the file as-is; no current time is inserted.
      t.eq(t.get_lines(), { "--- blots ---", "08:00 plan" })
      t.eq(vim.bo.modified, false)
    end)
  end)

  t.test("init scaffolds a past day with a header and no current time", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 18, hour = 8, min = 45, sec = 0 })
    local target = os.time({ year = 2026, month = 5, day = 16, hour = 12, min = 0, sec = 0 })

    with_blotter_setup({
      defaults = {
        tag = "ClientA",
        quantize_minutes = 30,
        duration_format = "hm",
      },
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("BlotterInit -2")
      end)

      local path = root
        .. "/"
        .. os.date("%Y", target)
        .. "/"
        .. os.date("%Y-%m-%d", target)
        .. ".blot"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      -- A header (with defaults) and an empty summary, but no timestamped blot.
      t.eq(t.get_lines(), {
        "--- blots #ClientA q=30 d=hm ---",
        "",
        "--- summary q=30 d=hm ---",
        "",
        "--- totals ---",
        "0:00 (+0m) workday",
      })
    end)
  end)

  t.test("init opens an existing journal day without changing it", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 18, hour = 8, min = 45, sec = 0 })
    local target = os.time({ year = 2026, month = 5, day = 20, hour = 12, min = 0, sec = 0 })
    local existing_path = write_journal_file(root, "%Y", target, {
      "--- blots ---",
      "08:00 plan",
      "09:00 done",
    })

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("BlotterInit 2")
      end)

      t.eq(vim.api.nvim_buf_get_name(0), existing_path)
      t.eq(t.get_lines(), { "--- blots ---", "08:00 plan", "09:00 done" })
      t.eq(vim.bo.modified, false)
    end)
  end)

  t.test("init rejects a non-integer offset and leaves the current buffer unchanged", function()
    local root = vim.fn.tempname()

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      t.reset({ "scratch" })

      with_captured_notify(function(messages)
        vim.cmd("BlotterInit nope")

        t.eq(messages, {
          { message = "blotter: day offset must be an integer", level = vim.log.levels.WARN },
        })
      end)

      t.eq(vim.api.nvim_buf_get_name(0), "")
      t.eq(t.get_lines(), { "scratch" })
    end)
  end)

  t.test("step commands reject invalid counts and leave the current buffer unchanged", function()
    local root = vim.fn.tempname()

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      t.reset({ "scratch" })

      for _, command in ipairs({
        "BlotterNextDay nope",
        "BlotterPrevDay 0",
        "BlotterNextDay 1.5",
        "BlotterPrevDay -1",
      }) do
        with_captured_notify(function(messages)
          vim.cmd(command)

          t.eq(messages, {
            {
              message = "blotter: days count must be a positive integer",
              level = vim.log.levels.WARN,
            },
          })
        end)

        t.eq(vim.api.nvim_buf_get_name(0), "")
        t.eq(t.get_lines(), { "scratch" })
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
      "--- blots #ClientA @office q=30 ---",
      "08:00 plan",
      "08:20 implementation @home",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "stale",
    })

    write_journal_file(root, "%Y/%V", friday, {
      "--- blots #ClientA @office q=30 ---",
      "09:00 stale",
      "09:30 done",
      "",
      "--- summary q=15 d=dec ---",
      "stale",
      "",
      "--- blots #internal @home q=60 ---",
      "10:00 retro",
      "10:40 done",
    })

    with_blotter_setup({
      defaults = {
        duration_format = "hm",
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
        vim.cmd("BlotterWeek")
      end)

      t.eq(#vim.api.nvim_tabpage_list_wins(0), windows_before + 1)
      t.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "blotter-week-2026-W21.blot")
      t.eq(vim.bo.buftype, "nofile")
      t.eq(vim.bo.bufhidden, "wipe")
      t.ok(not vim.bo.swapfile)
      t.ok(not vim.bo.modifiable)
      t.ok(not vim.bo.modified)
      t.eq(t.get_lines(), {
        "--- day summary 2026-05-18 q=30 ---",
        "0:30 (+10m) implementation",
        "0:30 (-10m) plan",
        "",
        "--- day tags 2026-05-18 ---",
        "1:00 (+0m) #ClientA",
        "",
        "--- day locations 2026-05-18 ---",
        "0:30 (+10m) @home",
        "0:30 (-10m) @office",
        "",
        "--- day totals 2026-05-18 ---",
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
        "--- week summary 2026-W21 ---",
        "1:00 (-20m) retro",
        "0:30 (+10m) implementation",
        "0:30 (-10m) plan",
        "",
        "--- week tags 2026-W21 ---",
        "1:00 (+0m) #ClientA",
        "1:00 (-20m) #internal",
        "",
        "--- week locations 2026-W21 ---",
        "1:30 (-10m) @home",
        "0:30 (-10m) @office",
        "",
        "--- week totals 2026-W21 ---",
        "2:00 (-20m) workday",
      })

      vim.cmd("silent! only!")
    end)
  end)

  t.test("week report reflects unsaved edits in an open journal buffer", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 12, min = 0, sec = 0 })
    local monday = os.time({ year = 2026, month = 5, day = 18, hour = 12, min = 0, sec = 0 })

    local monday_path = write_journal_file(root, "%Y/%V", monday, {
      "--- blots #ClientA @office q=30 ---",
      "08:00 plan",
      "09:00 done",
    })

    with_blotter_setup({
      defaults = {
        duration_format = "hm",
      },
      journal = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("silent! only!")

      -- Open Monday and extend it to two hours without saving.
      vim.cmd("edit " .. vim.fn.fnameescape(monday_path))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "--- blots #ClientA @office q=30 ---",
        "08:00 plan",
        "10:00 done",
      })
      t.ok(vim.bo.modified)

      with_mocked_time(now, function()
        vim.cmd("BlotterWeek")
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
        "--- blots #ClientA @office q=30 ---",
        "08:00 plan",
        "09:00 done",
      })

      vim.cmd("silent! only!")
    end)
  end)

  t.test("week bang opens only the weekly aggregate scratch report", function()
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

    write_journal_file(root, "%Y/%V", monday, {
      "--- blots #ClientA @office q=30 ---",
      "08:00 plan",
      "09:00 done",
    })

    with_blotter_setup({
      defaults = {
        duration_format = "hm",
      },
      journal = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("silent! only!")
      t.reset({ "notes" })

      with_mocked_time(now, function()
        vim.cmd("BlotterWeek!")
      end)

      t.eq(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
        "blotter-week-summary-2026-W21.blot"
      )
      t.eq(t.get_lines(), {
        "--- week summary 2026-W21 ---",
        "1:00 (+0m) plan",
        "",
        "--- week tags 2026-W21 ---",
        "1:00 (+0m) #ClientA",
        "",
        "--- week locations 2026-W21 ---",
        "1:00 (+0m) @office",
        "",
        "--- week totals 2026-W21 ---",
        "1:00 (+0m) workday",
      })

      vim.cmd("silent! only!")
    end)
  end)

  t.test("week expands a home-relative journal root before building reports", function()
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
      write_journal_file(expanded_root, "%Y/%V", monday, {
        "--- blots ---",
        "08:00 plan",
        "09:00 done",
      })

      with_blotter_setup({
        journal = {
          root = relative_root,
          directory = "%Y/%V",
        },
      }, function()
        vim.cmd("silent! only!")
        t.reset({ "notes" })

        with_mocked_time(now, function()
          vim.cmd("BlotterWeek")
        end)

        t.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "blotter-week-2026-W21.blot")
        t.eq(t.get_lines()[1], "--- day summary 2026-05-18 q=15 ---")

        vim.cmd("silent! only!")
      end)
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

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("silent! only!")
      t.reset({ "scratch" })

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("BlotterWeek")
        end)

        t.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
        t.eq(vim.api.nvim_buf_get_name(0), "")
        t.eq(t.get_lines(), { "scratch" })
        t.eq(messages, {
          {
            message = "blotter: no journal blotters found",
            level = vim.log.levels.WARN,
          },
        })
      end)
    end)
  end)

  t.test("days validates the requested count", function()
    with_blotter_setup({}, function()
      t.reset({ "scratch" })

      local ok, err = pcall(vim.cmd, "BlotterDays")
      t.ok(not ok)
      t.ok(tostring(err):match("E471") ~= nil)

      for _, command in ipairs({
        "BlotterDays nope",
        "BlotterDays 0",
        "BlotterDays -1",
        "BlotterDays 1.5",
      }) do
        with_captured_notify(function(messages)
          vim.cmd(command)

          t.eq(messages, {
            {
              message = "blotter: days count must be a positive integer",
              level = vim.log.levels.WARN,
            },
          })
        end)

        t.eq(t.get_lines(), { "scratch" })
      end
    end)
  end)

  t.test("days opens a scratch report for the last n journal dates", function()
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

    write_journal_file(root, "%Y/%V", wednesday, {
      "--- blots #ClientA @office q=30 ---",
      "08:00 plan",
      "08:20 implementation @home",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "stale",
    })
    write_journal_file(root, "%Y/%V", thursday, {})
    write_journal_file(root, "%Y/%V", friday, {
      "--- blots #internal @home q=60 ---",
      "10:00 retro",
      "10:40 done",
      "",
      "--- summary q=15 d=dec ---",
      "stale",
    })

    with_blotter_setup({
      defaults = {
        duration_format = "hm",
      },
      journal = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("silent! only!")
      t.reset({ "notes" })

      with_mocked_time(now, function()
        vim.cmd("BlotterDays 4")
      end)

      t.eq(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
        "blotter-days-2026-05-19..2026-05-22.blot"
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
        "--- range summary 2026-05-19..2026-05-22 ---",
        "1:00 (-20m) retro",
        "0:30 (+10m) implementation",
        "0:30 (-10m) plan",
        "",
        "--- range tags 2026-05-19..2026-05-22 ---",
        "1:00 (+0m) #ClientA",
        "1:00 (-20m) #internal",
        "",
        "--- range locations 2026-05-19..2026-05-22 ---",
        "1:30 (-10m) @home",
        "0:30 (-10m) @office",
        "",
        "--- range totals 2026-05-19..2026-05-22 ---",
        "2:00 (-20m) workday",
      })

      vim.cmd("silent! only!")
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

    write_journal_file(root, "%Y/%V", friday, {
      "--- blots #internal @home q=60 ---",
      "10:00 retro",
      "11:00 done",
    })

    with_blotter_setup({
      defaults = {
        duration_format = "hm",
      },
      journal = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("silent! only!")
      t.reset({ "notes" })

      with_mocked_time(now, function()
        vim.cmd("BlotterDays! 3")
      end)

      t.eq(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
        "blotter-days-summary-2026-05-20..2026-05-22.blot"
      )
      t.eq(t.get_lines(), {
        "--- range summary 2026-05-20..2026-05-22 ---",
        "1:00 (+0m) retro",
        "",
        "--- range tags 2026-05-20..2026-05-22 ---",
        "1:00 (+0m) #internal",
        "",
        "--- range locations 2026-05-20..2026-05-22 ---",
        "1:00 (+0m) @home",
        "",
        "--- range totals 2026-05-20..2026-05-22 ---",
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

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      vim.cmd("silent! only!")
      t.reset({ "scratch" })

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("BlotterDays 3")
        end)

        t.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
        t.eq(vim.api.nvim_buf_get_name(0), "")
        t.eq(t.get_lines(), { "scratch" })
        t.eq(messages, {
          {
            message = "blotter: no journal blotters found",
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
    local bad_path = write_journal_file(root, "%Y/%V", thursday, {
      "--- blots ---",
      "09:00 done",
      "08:00 plan",
    })

    with_blotter_setup({
      journal = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      t.reset({ "scratch" })

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("BlotterDays 3")
        end)

        t.eq(vim.api.nvim_buf_get_name(0), "")
        t.eq(t.get_lines(), { "scratch" })
        t.eq(messages, {
          {
            message = "blotter: "
              .. bad_path
              .. ": unordered timestamps near lines 2 and 3; fix manually or run :BlotterOrder",
            level = vim.log.levels.WARN,
          },
        })
      end)
    end)
  end)

  t.test("week report refreshes when a dependent journal buffer changes", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 12, min = 0, sec = 0 })
    local monday = os.time({ year = 2026, month = 5, day = 18, hour = 12, min = 0, sec = 0 })

    local monday_path = write_journal_file(root, "%Y/%V", monday, {
      "--- blots #ClientA @office q=30 ---",
      "08:00 plan",
      "09:00 done",
    })

    with_blotter_setup({
      auto_summary = "save",
      defaults = { duration_format = "hm" },
      journal = { root = root, directory = "%Y/%V" },
    }, function()
      vim.cmd("silent! only!")

      -- Monday open in its own window so the report split does not replace it.
      vim.cmd("edit " .. vim.fn.fnameescape(monday_path))
      local monday_buf = vim.api.nvim_get_current_buf()
      local monday_win = vim.api.nvim_get_current_win()

      with_mocked_time(now, function()
        vim.cmd("BlotterWeek")
      end)
      local report_buf = vim.api.nvim_get_current_buf()

      t.ok(report_has_workday(report_buf, "1:00"), "report should start from Monday's one-hour day")

      -- Extend Monday to two hours in its buffer (unsaved) and signal a save.
      vim.api.nvim_buf_set_lines(monday_buf, 0, -1, false, {
        "--- blots #ClientA @office q=30 ---",
        "08:00 plan",
        "10:00 done",
      })
      vim.api.nvim_set_current_win(monday_win)
      with_mocked_time(now, function()
        vim.api.nvim_exec_autocmds("BufWritePre", { buffer = monday_buf })
      end)

      t.ok(report_has_workday(report_buf, "2:00"), "report should rebuild to the two-hour day")
      t.ok(not report_has_workday(report_buf, "1:00"), "stale one-hour total should be gone")

      vim.cmd("silent! only!")
    end)
  end)

  t.test("days report refreshes when a dependent journal buffer changes", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local day_one = os.time({ year = 2026, month = 5, day = 18, hour = 12, min = 0, sec = 0 })

    local day_one_path = write_journal_file(root, "%Y", day_one, {
      "--- blots #ClientA @office q=30 ---",
      "08:00 plan",
      "09:00 done",
    })

    with_blotter_setup({
      auto_summary = "save",
      defaults = { duration_format = "hm" },
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("silent! only!")

      vim.cmd("edit " .. vim.fn.fnameescape(day_one_path))
      local source_buf = vim.api.nvim_get_current_buf()
      local source_win = vim.api.nvim_get_current_win()

      with_mocked_time(now, function()
        vim.cmd("BlotterDays 2")
      end)
      local report_buf = vim.api.nvim_get_current_buf()

      t.ok(report_has_workday(report_buf, "1:00"))

      vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
        "--- blots #ClientA @office q=30 ---",
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

  t.test("the date guard recognizes a relative journal root", function()
    -- A relative journal.root must be absolutized so the buffer's date is
    -- recognized; otherwise the time guard silently disables itself.
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local previous_cwd = vim.fn.getcwd()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 9, min = 0, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })

    local ok, err = pcall(function()
      vim.cmd("cd " .. vim.fn.fnameescape(tmp))
      write_journal_file("rel-journal", "%Y", yesterday, {
        "--- blots #ClientA @office ---",
        "08:00 planning",
        "17:00",
      })

      with_blotter_setup({
        journal = { root = "rel-journal", directory = "%Y" },
      }, function()
        vim.cmd("edit rel-journal/2026/2026-05-21.blot")
        t.set_cursor(2, 0)

        with_captured_notify(function(messages)
          with_mocked_time(now, function()
            vim.cmd("BlotInsert")
          end)

          t.eq(messages, {
            {
              message = "blotter: this file is dated 2026-05-21, not today (2026-05-22); "
                .. "refusing to insert the current time",
              level = vim.log.levels.WARN,
            },
          })
        end)

        t.eq(t.get_lines(), {
          "--- blots #ClientA @office ---",
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

  t.test("insert refuses to stamp the current time into a non-today journal file", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 9, min = 0, sec = 0 })
    local past = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local path = write_journal_file(root, "%Y", past, {
      "--- blots ---",
      "08:00 plan",
    })

    with_blotter_setup({
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      t.set_cursor(2, 0)

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("BlotInsert")
        end)

        t.eq(messages, {
          {
            message = "blotter: this file is dated 2026-05-19, not today (2026-05-22); "
              .. "refusing to insert the current time",
            level = vim.log.levels.WARN,
          },
        })
      end)

      t.eq(t.get_lines(), {
        "--- blots ---",
        "08:00 plan",
      })
    end)
  end)

  t.test("insert proceeds on a buffer that is not a journal file", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 9, min = 0, sec = 0 })

    with_blotter_setup({
      journal = { root = root, directory = "%Y" },
    }, function()
      t.reset({
        "--- blots ---",
        "08:00 plan",
      })

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("BlotInsert")
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

  t.test("insert proceeds normally on today's journal file", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 9, min = 0, sec = 0 })
    local path = write_journal_file(root, "%Y", now, {
      "--- blots ---",
      "08:00 plan",
    })

    with_blotter_setup({
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      t.set_cursor(2, 0)

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("BlotInsert")
        end)

        t.eq(messages, {})
      end)

      -- The inserted clock time comes from the real wall clock, so assert shape
      -- rather than an exact value: one fresh empty timestamp line was added.
      local lines = t.get_lines()
      t.eq(#lines, 3)
      t.eq(lines[1], "--- blots ---")
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
    local refresh_summaries = require("blotter.usecases.refresh_summaries")
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_journal_file(root, "%Y", yesterday, {
      "--- blots #ClientA @office ---",
      "08:00 standup",
      "10:30 writing report",
      "",
      "--- summary q=15 d=dec ---",
      "2.50h standup",
      "",
      "--- totals ---",
      "2.50h workday",
    })

    with_blotter_setup({
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(3, 0)

      with_mocked_confirm(1, function()
        with_mocked_time(now, function()
          vim.cmd("BlotInsert")
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
    local yesterday_path = write_journal_file(root, "%Y", yesterday, {
      "--- blots #ClientA @office ---",
      "22:30 writing report",
    })
    local today_path = root .. "/2026/2026-05-22.blot"

    with_blotter_setup({
      defaults = { tag = "ClientA", location = "office" },
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_mocked_confirm(1, function()
        with_mocked_time(now, function()
          vim.cmd("BlotInsert")
        end)
      end)

      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      t.eq(t.get_lines(), {
        "--- blots #ClientA @office ---",
        "00:00 writing report",
        "00:47 ",
      })
      -- The pre-save refresh closes yesterday at 24:00 and gives it a summary.
      t.eq(vim.fn.readfile(yesterday_path), {
        "--- blots #ClientA @office ---",
        "22:30 writing report",
        "24:00",
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
    local past_path = write_journal_file(root, "%Y", past, {
      "--- blots #ClientA @office ---",
      "08:00 deep work",
      "09:00 done",
    })
    local today_path = root .. "/2026/2026-05-22.blot"

    with_blotter_setup({
      defaults = { tag = "ClientA", location = "office" },
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(past_path))
      t.set_cursor(2, 0)

      with_mocked_time(now, function()
        vim.cmd("BlotRepeat")
      end)

      -- Switched to a fresh today, with the activity at the current time.
      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      t.eq(t.get_lines(), {
        "--- blots #ClientA @office ---",
        "10:00 deep work",
        "",
        "--- summary q=15 d=dec ---",
        "",
        "--- totals ---",
        "0.00h (+0m) workday",
      })
      -- The browsed day is left untouched.
      t.eq(vim.fn.readfile(past_path), {
        "--- blots #ClientA @office ---",
        "08:00 deep work",
        "09:00 done",
      })
    end)
  end)

  t.test("repeat from another day inserts into an existing today blotter", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local past = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local past_path = write_journal_file(root, "%Y", past, {
      "--- blots #ClientA @office ---",
      "08:00 deep work",
      "09:00 done",
    })
    local today = os.time({ year = 2026, month = 5, day = 22, hour = 12, min = 0, sec = 0 })
    local today_path = write_journal_file(root, "%Y", today, {
      "--- blots #ClientA @office ---",
      "08:00 standup",
      "09:00 done",
    })

    with_blotter_setup({
      defaults = { tag = "ClientA", location = "office" },
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(past_path))
      t.set_cursor(2, 0)

      with_mocked_time(now, function()
        vim.cmd("BlotRepeat")
      end)

      -- deep work is inserted at 10:00, after the existing blots.
      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      local lines = t.get_lines()
      t.eq(lines[2], "08:00 standup")
      t.eq(lines[3], "09:00 done")
      t.eq(lines[4], "10:00 deep work")
    end)
  end)

  t.test("repeat on another day with the cursor off an blot warns and does nothing", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local past = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local past_path = write_journal_file(root, "%Y", past, {
      "--- blots #ClientA @office ---",
      "08:00 deep work",
      "09:00 done",
    })

    with_blotter_setup({
      defaults = { tag = "ClientA", location = "office" },
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(past_path))
      t.set_cursor(1, 0)

      with_mocked_time(now, function()
        vim.cmd("BlotRepeat")
      end)

      -- Stayed on the browsed day, unchanged.
      t.eq(vim.api.nvim_buf_get_name(0), past_path)
      t.eq(t.get_lines(), {
        "--- blots #ClientA @office ---",
        "08:00 deep work",
        "09:00 done",
      })
    end)
  end)

  t.test("repeat on another day reports a broken today without leaving the browsed day", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local past = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local past_path = write_journal_file(root, "%Y", past, {
      "--- blots #ClientA @office ---",
      "08:00 deep work",
      "09:00 done",
    })
    local today = os.time({ year = 2026, month = 5, day = 22, hour = 8, min = 0, sec = 0 })
    -- today already has out-of-order blots, so the activity cannot be seeded into it.
    write_journal_file(root, "%Y", today, {
      "--- blots #ClientA @office ---",
      "09:00 later",
      "08:00 earlier",
    })

    with_blotter_setup({
      defaults = { tag = "ClientA", location = "office" },
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(past_path))
      t.set_cursor(2, 0)

      with_mocked_time(now, function()
        vim.cmd("BlotRepeat")
      end)

      -- Stayed on the browsed day rather than being switched onto the broken today.
      t.eq(vim.api.nvim_buf_get_name(0), past_path)
    end)
  end)

  t.test("repeat on another day initializes a whitespace-only today", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local past = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local past_path = write_journal_file(root, "%Y", past, {
      "--- blots #ClientA @office ---",
      "08:00 deep work",
      "09:00 done",
    })
    local today = os.time({ year = 2026, month = 5, day = 22, hour = 8, min = 0, sec = 0 })
    local today_path = write_journal_file(root, "%Y", today, { "", "  ", "" })

    with_blotter_setup({
      defaults = { tag = "ClientA", location = "office" },
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(past_path))
      t.set_cursor(2, 0)

      with_mocked_time(now, function()
        vim.cmd("BlotRepeat")
      end)

      -- The whitespace today is initialized fresh, with the header on line 1.
      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      local lines = t.get_lines()
      t.eq(lines[1], "--- blots #ClientA @office ---")
      t.eq(lines[2], "10:00 deep work")
    end)
  end)

  t.test("repeat past midnight carries the running task and repeats the cursor blot", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_journal_file(root, "%Y", yesterday, {
      "--- blots #ClientA @office ---",
      "20:00 standup",
      "22:30 writing report",
    })
    local today_path = root .. "/2026/2026-05-22.blot"

    with_blotter_setup({
      defaults = { tag = "ClientA", location = "office" },
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_mocked_confirm(1, function()
        with_mocked_time(now, function()
          vim.cmd("BlotRepeat")
        end)
      end)

      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      t.eq(t.get_lines(), {
        "--- blots #ClientA @office ---",
        "00:00 writing report",
        "00:47 standup",
      })
      -- The pre-save refresh closes yesterday at 24:00 and gives it a summary.
      t.eq(vim.fn.readfile(yesterday_path), {
        "--- blots #ClientA @office ---",
        "20:00 standup",
        "22:30 writing report",
        "24:00",
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
    local yesterday_path = write_journal_file(root, "%Y", yesterday, {
      "--- blots #ClientA @office ---",
      "22:30 writing report",
    })
    local today_path = root .. "/2026/2026-05-22.blot"

    with_blotter_setup({
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_mocked_confirm(2, function()
        with_mocked_time(now, function()
          vim.cmd("BlotInsert")
        end)
      end)

      t.eq(vim.api.nvim_buf_get_name(0), yesterday_path)
      t.eq(t.get_lines(), {
        "--- blots #ClientA @office ---",
        "22:30 writing report",
      })
      t.eq(vim.fn.filereadable(today_path), 0)
    end)
  end)

  t.test("insert past midnight refuses when today's blotter already exists", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_journal_file(root, "%Y", yesterday, {
      "--- blots #ClientA @office ---",
      "22:30 writing report",
    })
    write_journal_file(root, "%Y", now, {
      "--- blots ---",
      "00:10 already here",
    })

    with_blotter_setup({
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_captured_notify(function(messages)
        with_mocked_confirm(1, function()
          with_mocked_time(now, function()
            vim.cmd("BlotInsert")
          end)
        end)

        t.eq(messages, {
          {
            message = "blotter: today's blotter already exists; open it with :BlotterToday",
            level = vim.log.levels.WARN,
          },
        })
      end)

      t.eq(vim.api.nvim_buf_get_name(0), yesterday_path)
      t.eq(t.get_lines(), {
        "--- blots #ClientA @office ---",
        "22:30 writing report",
      })
    end)
  end)

  t.test("insert past midnight refuses when an unsaved today buffer exists", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_journal_file(root, "%Y", yesterday, {
      "--- blots #ClientA @office ---",
      "22:30 writing report",
    })
    local today_path = root .. "/2026/2026-05-22.blot"

    with_blotter_setup({
      journal = { root = root, directory = "%Y" },
    }, function()
      -- Today exists only as an unsaved buffer, never written to disk.
      vim.cmd("edit " .. vim.fn.fnameescape(today_path))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "--- blots ---",
        "00:10 already here",
      })

      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_captured_notify(function(messages)
        with_mocked_confirm(1, function()
          with_mocked_time(now, function()
            vim.cmd("BlotInsert")
          end)
        end)

        t.eq(messages, {
          {
            message = "blotter: today's blotter already exists; open it with :BlotterToday",
            level = vim.log.levels.WARN,
          },
        })
      end)

      t.eq(vim.api.nvim_buf_get_name(0), yesterday_path)
      t.eq(t.get_lines(), {
        "--- blots #ClientA @office ---",
        "22:30 writing report",
      })
      t.eq(vim.fn.filereadable(today_path), 0)
    end)
  end)

  t.test("repeat past midnight inserts the cursor blot into an existing today on disk", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    -- Yesterday ends with a still-running task, so without the fix this would take
    -- the carryover branch and refuse because today already exists.
    local yesterday_path = write_journal_file(root, "%Y", yesterday, {
      "--- blots #ClientA @office ---",
      "20:00 standup",
      "22:30 writing report",
    })
    local today_path = write_journal_file(root, "%Y", now, {
      "--- blots #ClientA @office ---",
      "08:00 morning sync",
      "09:00 done",
    })

    with_blotter_setup({
      defaults = { tag = "ClientA", location = "office" },
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      -- No confirm is mocked: the carryover prompt must never appear, since this is
      -- a plain cross-day repeat into the existing today.
      with_mocked_time(now, function()
        vim.cmd("BlotRepeat")
      end)

      -- Switched to today, with the cursor blot brought in at the current time.
      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      local lines = t.get_lines()
      t.eq(lines[1], "--- blots #ClientA @office ---")
      t.eq(lines[2], "08:00 morning sync")
      t.eq(lines[3], "09:00 done")
      t.eq(lines[4], "10:00 standup")

      -- Yesterday is left untouched -- not closed at 24:00, not saved -- proving the
      -- cross-day repeat ran rather than the carryover.
      t.eq(vim.fn.readfile(yesterday_path), {
        "--- blots #ClientA @office ---",
        "20:00 standup",
        "22:30 writing report",
      })
    end)
  end)

  t.test("repeat past midnight inserts the cursor blot into an unsaved today buffer", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 10, min = 0, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_journal_file(root, "%Y", yesterday, {
      "--- blots #ClientA @office ---",
      "20:00 standup",
      "22:30 writing report",
    })
    local today_path = root .. "/2026/2026-05-22.blot"

    with_blotter_setup({
      defaults = { tag = "ClientA", location = "office" },
      journal = { root = root, directory = "%Y" },
    }, function()
      -- Today exists only as an unsaved buffer, never written to disk.
      vim.cmd("edit " .. vim.fn.fnameescape(today_path))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "--- blots #ClientA @office ---",
        "08:00 morning sync",
        "09:00 done",
      })

      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_mocked_time(now, function()
        vim.cmd("BlotRepeat")
      end)

      -- Switched to the unsaved today buffer, with the blot inserted there.
      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      local lines = t.get_lines()
      t.eq(lines[2], "08:00 morning sync")
      t.eq(lines[3], "09:00 done")
      t.eq(lines[4], "10:00 standup")

      -- The unsaved today was edited in place; nothing was persisted to disk, and
      -- yesterday is untouched.
      t.eq(vim.fn.filereadable(today_path), 0)
      t.eq(vim.fn.readfile(yesterday_path), {
        "--- blots #ClientA @office ---",
        "20:00 standup",
        "22:30 writing report",
      })
    end)
  end)
end
