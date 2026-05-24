return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_captured_notify = helpers.with_captured_notify
  local with_mocked_confirm = helpers.with_mocked_confirm
  local with_mocked_time = helpers.with_mocked_time
  local with_temp_home_root = helpers.with_temp_home_root
  local with_worklog_setup = helpers.with_worklog_setup
  local write_journal_file = helpers.write_journal_file

  helpers.setup_worklog()

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
        "",
        "--- summary quantized ---",
        "",
        "--- totals quantized ---",
        "0:00 (+0m) workday",
      })
      t.eq(vim.api.nvim_win_get_cursor(0), { 2, 6 })
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

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("WorklogToday 0")
      end)

      t.eq(
        vim.api.nvim_buf_get_name(0),
        root .. "/" .. os.date("%Y", now) .. "/" .. os.date("%Y-%m-%d", now) .. ".wkl"
      )
      t.eq(t.get_lines(), {
        "--- worklog ---",
        "08:45 ",
        "",
        "--- summary quantized ---",
        "",
        "--- totals quantized ---",
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

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("WorklogToday -1")
      end)

      local path = root
        .. "/"
        .. os.date("%Y", yesterday)
        .. "/"
        .. os.date("%Y-%m-%d", yesterday)
        .. ".wkl"
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

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("WorklogToday +1")
      end)

      local path = root
        .. "/"
        .. os.date("%Y", tomorrow)
        .. "/"
        .. os.date("%Y-%m-%d", tomorrow)
        .. ".wkl"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      -- Navigation only: an empty, unmodified buffer with nothing written to disk.
      t.eq(t.get_lines(), { "" })
      t.eq(vim.bo.modified, false)
      t.eq(vim.fn.filereadable(path), 0)
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
      with_worklog_setup({
        journal = {
          root = relative_root,
          directory = "%Y",
        },
      }, function()
        vim.cmd("enew!")
        vim.bo.modified = false

        with_mocked_time(now, function()
          vim.cmd("WorklogToday")
        end)

        t.eq(
          vim.api.nvim_buf_get_name(0),
          expanded_root .. "/" .. os.date("%Y", now) .. "/" .. os.date("%Y-%m-%d", now) .. ".wkl"
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
        "",
        "--- summary quantized ---",
        "",
        "--- totals quantized ---",
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
    local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", tomorrow) .. ".wkl"

    vim.fn.mkdir(expected_dir, "p")
    vim.fn.writefile({}, expected_path)

    with_worklog_setup({
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
        vim.cmd("WorklogToday 1")
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
    local expected_path = expected_dir .. "/" .. os.date("%Y-%m-%d", yesterday) .. ".wkl"

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
        vim.cmd("WorklogToday -1")
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

  t.test("today rejects invalid day offsets and leaves the current buffer unchanged", function()
    local root = vim.fn.tempname()

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      t.reset({ "scratch" })

      for _, command in ipairs({
        "WorklogToday nope",
        "WorklogToday 1.5",
        "WorklogToday --1",
        "WorklogToday +",
      }) do
        with_captured_notify(function(messages)
          vim.cmd(command)

          t.eq(messages, {
            {
              message = "worklog: day offset must be an integer",
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

          with_mocked_time(now, function()
            vim.cmd("WorklogToday -1")
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

  t.test("next day steps forward relative to the open journal file", function()
    local root = vim.fn.tempname()
    local opened = os.time({
      year = 2026,
      month = 5,
      day = 10,
      hour = 12,
      min = 0,
      sec = 0,
    })
    local next_day = os.time({
      year = 2026,
      month = 5,
      day = 11,
      hour = 12,
      min = 0,
      sec = 0,
    })

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local open_path = write_journal_file(root, "%Y", opened, {
        "--- worklog ---",
        "08:00 plan",
      })
      vim.cmd("edit " .. vim.fn.fnameescape(open_path))
      vim.bo.modified = false

      vim.cmd("WorklogNextDay")

      local path = root
        .. "/"
        .. os.date("%Y", next_day)
        .. "/"
        .. os.date("%Y-%m-%d", next_day)
        .. ".wkl"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      -- Navigation only: empty, unmodified, nothing written to disk.
      t.eq(t.get_lines(), { "" })
      t.eq(vim.bo.modified, false)
      t.eq(vim.fn.filereadable(path), 0)
    end)
  end)

  t.test("prev day count steps backward relative to the open journal file", function()
    local root = vim.fn.tempname()
    local opened = os.time({
      year = 2026,
      month = 5,
      day = 10,
      hour = 12,
      min = 0,
      sec = 0,
    })
    local target = os.time({
      year = 2026,
      month = 5,
      day = 8,
      hour = 12,
      min = 0,
      sec = 0,
    })

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local open_path = write_journal_file(root, "%Y", opened, {
        "--- worklog ---",
      })
      vim.cmd("edit " .. vim.fn.fnameescape(open_path))
      vim.bo.modified = false

      vim.cmd("WorklogPrevDay 2")

      local path = root
        .. "/"
        .. os.date("%Y", target)
        .. "/"
        .. os.date("%Y-%m-%d", target)
        .. ".wkl"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      t.eq(t.get_lines(), { "" })
      t.eq(vim.bo.modified, false)
      t.eq(vim.fn.filereadable(path), 0)
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
    local yesterday = os.time({
      year = 2026,
      month = 5,
      day = 17,
      hour = 12,
      min = 0,
      sec = 0,
    })

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      vim.cmd("enew!")
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("WorklogPrevDay")
      end)

      local path = root
        .. "/"
        .. os.date("%Y", yesterday)
        .. "/"
        .. os.date("%Y-%m-%d", yesterday)
        .. ".wkl"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      t.eq(t.get_lines(), { "" })
      t.eq(vim.bo.modified, false)
      t.eq(vim.fn.filereadable(path), 0)
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

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      local open_path = write_journal_file(root, "%Y", yesterday, {
        "--- worklog ---",
      })
      vim.cmd("edit " .. vim.fn.fnameescape(open_path))
      vim.bo.modified = false

      with_mocked_time(now, function()
        vim.cmd("WorklogNextDay")
      end)

      local path = root .. "/" .. os.date("%Y", now) .. "/" .. os.date("%Y-%m-%d", now) .. ".wkl"
      t.eq(vim.api.nvim_buf_get_name(0), path)
      -- Navigation onto today opens an empty, unmodified buffer (no current time).
      t.eq(t.get_lines(), { "" })
      t.eq(vim.bo.modified, false)
      t.eq(vim.fn.filereadable(path), 0)
    end)
  end)

  t.test("step commands reject invalid counts and leave the current buffer unchanged", function()
    local root = vim.fn.tempname()

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y",
      },
    }, function()
      t.reset({ "scratch" })

      for _, command in ipairs({
        "WorklogNextDay nope",
        "WorklogPrevDay 0",
        "WorklogNextDay 1.5",
        "WorklogPrevDay -1",
      }) do
        with_captured_notify(function(messages)
          vim.cmd(command)

          t.eq(messages, {
            {
              message = "worklog: days count must be a positive integer",
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
      t.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "worklog-week-2026-W21.wkl")
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
      "--- worklog #ClientA @office quantize=30 ---",
      "08:00 plan",
      "09:00 done",
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

      with_mocked_time(now, function()
        vim.cmd("WorklogWeek!")
      end)

      t.eq(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
        "worklog-week-summary-2026-W21.wkl"
      )
      t.eq(t.get_lines(), {
        "--- week summary quantized 2026-W21 ---",
        "1:00 (+0m) plan",
        "",
        "--- week tags quantized 2026-W21 ---",
        "1:00 (+0m) #ClientA",
        "",
        "--- week locations quantized 2026-W21 ---",
        "1:00 (+0m) @office",
        "",
        "--- week totals quantized 2026-W21 ---",
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
        "--- worklog ---",
        "08:00 plan",
        "09:00 done",
      })

      with_worklog_setup({
        journal = {
          root = relative_root,
          directory = "%Y/%V",
        },
      }, function()
        vim.cmd("silent! only!")
        t.reset({ "notes" })

        with_mocked_time(now, function()
          vim.cmd("WorklogWeek")
        end)

        t.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "worklog-week-2026-W21.wkl")
        t.eq(t.get_lines()[1], "--- day summary quantized 2026-05-18 ---")

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
            message = "worklog: no journal worklogs found",
            level = vim.log.levels.WARN,
          },
        })
      end)
    end)
  end)

  t.test("days validates the requested count", function()
    with_worklog_setup({}, function()
      t.reset({ "scratch" })

      local ok, err = pcall(vim.cmd, "WorklogDays")
      t.ok(not ok)
      t.ok(tostring(err):match("E471") ~= nil)

      for _, command in ipairs({
        "WorklogDays nope",
        "WorklogDays 0",
        "WorklogDays -1",
        "WorklogDays 1.5",
      }) do
        with_captured_notify(function(messages)
          vim.cmd(command)

          t.eq(messages, {
            {
              message = "worklog: days count must be a positive integer",
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
      "--- worklog #ClientA @office quantize=30 ---",
      "08:00 plan",
      "08:20 implementation @home",
      "09:00 done",
      "",
      "--- summary exact ---",
      "stale",
    })
    write_journal_file(root, "%Y/%V", thursday, {})
    write_journal_file(root, "%Y/%V", friday, {
      "--- worklog #internal @home quantize=60 ---",
      "10:00 retro",
      "10:40 done",
      "",
      "--- summary quantized ---",
      "stale",
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

      with_mocked_time(now, function()
        vim.cmd("WorklogDays 4")
      end)

      t.eq(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
        "worklog-days-2026-05-19..2026-05-22.wkl"
      )
      t.eq(t.get_lines(), {
        "--- day summary quantized 2026-05-20 ---",
        "0:30 (+10m) implementation",
        "0:30 (-10m) plan",
        "",
        "--- day tags quantized 2026-05-20 ---",
        "1:00 (+0m) #ClientA",
        "",
        "--- day locations quantized 2026-05-20 ---",
        "0:30 (+10m) @home",
        "0:30 (-10m) @office",
        "",
        "--- day totals quantized 2026-05-20 ---",
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
        "--- range summary quantized 2026-05-19..2026-05-22 ---",
        "1:00 (-20m) retro",
        "0:30 (+10m) implementation",
        "0:30 (-10m) plan",
        "",
        "--- range tags quantized 2026-05-19..2026-05-22 ---",
        "1:00 (+0m) #ClientA",
        "1:00 (-20m) #internal",
        "",
        "--- range locations quantized 2026-05-19..2026-05-22 ---",
        "1:30 (-10m) @home",
        "0:30 (-10m) @office",
        "",
        "--- range totals quantized 2026-05-19..2026-05-22 ---",
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
      "--- worklog #internal @home quantize=60 ---",
      "10:00 retro",
      "11:00 done",
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

      with_mocked_time(now, function()
        vim.cmd("WorklogDays! 3")
      end)

      t.eq(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
        "worklog-days-summary-2026-05-20..2026-05-22.wkl"
      )
      t.eq(t.get_lines(), {
        "--- range summary quantized 2026-05-20..2026-05-22 ---",
        "1:00 (+0m) retro",
        "",
        "--- range tags quantized 2026-05-20..2026-05-22 ---",
        "1:00 (+0m) #internal",
        "",
        "--- range locations quantized 2026-05-20..2026-05-22 ---",
        "1:00 (+0m) @home",
        "",
        "--- range totals quantized 2026-05-20..2026-05-22 ---",
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
          vim.cmd("WorklogDays 3")
        end)

        t.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
        t.eq(vim.api.nvim_buf_get_name(0), "")
        t.eq(t.get_lines(), { "scratch" })
        t.eq(messages, {
          {
            message = "worklog: no journal worklogs found",
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
      "--- worklog ---",
      "09:00 done",
      "08:00 plan",
    })

    with_worklog_setup({
      journal = {
        root = root,
        directory = "%Y/%V",
      },
    }, function()
      t.reset({ "scratch" })

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("WorklogDays 3")
        end)

        t.eq(vim.api.nvim_buf_get_name(0), "")
        t.eq(t.get_lines(), { "scratch" })
        t.eq(messages, {
          {
            message = "worklog: "
              .. bad_path
              .. ": unordered timestamps near lines 2 and 3; fix manually or run :WorklogOrder",
            level = vim.log.levels.WARN,
          },
        })
      end)
    end)
  end)

  t.test("insert refuses to stamp the current time into a non-today journal file", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 9, min = 0, sec = 0 })
    local past = os.time({ year = 2026, month = 5, day = 19, hour = 12, min = 0, sec = 0 })
    local path = write_journal_file(root, "%Y", past, {
      "--- worklog ---",
      "08:00 plan",
    })

    with_worklog_setup({
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      t.set_cursor(2, 0)

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("WorklogInsert")
        end)

        t.eq(messages, {
          {
            message = "worklog: this file is dated 2026-05-19, not today (2026-05-22); "
              .. "refusing to insert the current time",
            level = vim.log.levels.WARN,
          },
        })
      end)

      t.eq(t.get_lines(), {
        "--- worklog ---",
        "08:00 plan",
      })
    end)
  end)

  t.test("insert proceeds on a buffer that is not a journal file", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 9, min = 0, sec = 0 })

    with_worklog_setup({
      journal = { root = root, directory = "%Y" },
    }, function()
      t.reset({
        "--- worklog ---",
        "08:00 plan",
      })

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("WorklogInsert")
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
      "--- worklog ---",
      "08:00 plan",
    })

    with_worklog_setup({
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      t.set_cursor(2, 0)

      with_captured_notify(function(messages)
        with_mocked_time(now, function()
          vim.cmd("WorklogInsert")
        end)

        t.eq(messages, {})
      end)

      -- The inserted clock time comes from the real wall clock, so assert shape
      -- rather than an exact value: one fresh empty timestamp line was added.
      local lines = t.get_lines()
      t.eq(#lines, 3)
      t.eq(lines[1], "--- worklog ---")
      local inserted = 0
      for _, line in ipairs(lines) do
        if line:match("^%d%d:%d%d $") then
          inserted = inserted + 1
        end
      end
      t.eq(inserted, 1)
    end)
  end)

  t.test("insert past midnight carries the running task into today", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_journal_file(root, "%Y", yesterday, {
      "--- worklog #ClientA @office ---",
      "22:30 writing report",
    })
    local today_path = root .. "/2026/2026-05-22.wkl"

    with_worklog_setup({
      defaults = { tag = "ClientA", location = "office" },
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_mocked_confirm(1, function()
        with_mocked_time(now, function()
          vim.cmd("WorklogInsert")
        end)
      end)

      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      t.eq(t.get_lines(), {
        "--- worklog #ClientA @office ---",
        "00:00 writing report",
        "00:47 ",
      })
      t.eq(vim.fn.readfile(yesterday_path), {
        "--- worklog #ClientA @office ---",
        "22:30 writing report",
        "24:00",
      })
    end)
  end)

  t.test("repeat past midnight carries the running task and repeats the cursor entry", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_journal_file(root, "%Y", yesterday, {
      "--- worklog #ClientA @office ---",
      "20:00 standup",
      "22:30 writing report",
    })
    local today_path = root .. "/2026/2026-05-22.wkl"

    with_worklog_setup({
      defaults = { tag = "ClientA", location = "office" },
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_mocked_confirm(1, function()
        with_mocked_time(now, function()
          vim.cmd("WorklogRepeat")
        end)
      end)

      t.eq(vim.api.nvim_buf_get_name(0), today_path)
      t.eq(t.get_lines(), {
        "--- worklog #ClientA @office ---",
        "00:00 writing report",
        "00:47 standup",
      })
      t.eq(vim.fn.readfile(yesterday_path), {
        "--- worklog #ClientA @office ---",
        "20:00 standup",
        "22:30 writing report",
        "24:00",
      })
    end)
  end)

  t.test("insert past midnight leaves both days untouched when declined", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_journal_file(root, "%Y", yesterday, {
      "--- worklog #ClientA @office ---",
      "22:30 writing report",
    })
    local today_path = root .. "/2026/2026-05-22.wkl"

    with_worklog_setup({
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_mocked_confirm(2, function()
        with_mocked_time(now, function()
          vim.cmd("WorklogInsert")
        end)
      end)

      t.eq(vim.api.nvim_buf_get_name(0), yesterday_path)
      t.eq(t.get_lines(), {
        "--- worklog #ClientA @office ---",
        "22:30 writing report",
      })
      t.eq(vim.fn.filereadable(today_path), 0)
    end)
  end)

  t.test("insert past midnight refuses when today's worklog already exists", function()
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 22, hour = 0, min = 47, sec = 0 })
    local yesterday = os.time({ year = 2026, month = 5, day = 21, hour = 12, min = 0, sec = 0 })
    local yesterday_path = write_journal_file(root, "%Y", yesterday, {
      "--- worklog #ClientA @office ---",
      "22:30 writing report",
    })
    write_journal_file(root, "%Y", now, {
      "--- worklog ---",
      "00:10 already here",
    })

    with_worklog_setup({
      journal = { root = root, directory = "%Y" },
    }, function()
      vim.cmd("edit " .. vim.fn.fnameescape(yesterday_path))
      t.set_cursor(2, 0)

      with_captured_notify(function(messages)
        with_mocked_confirm(1, function()
          with_mocked_time(now, function()
            vim.cmd("WorklogInsert")
          end)
        end)

        t.eq(messages, {
          {
            message = "worklog: today's worklog already exists; open it with :WorklogToday",
            level = vim.log.levels.WARN,
          },
        })
      end)

      t.eq(vim.api.nvim_buf_get_name(0), yesterday_path)
      t.eq(t.get_lines(), {
        "--- worklog #ClientA @office ---",
        "22:30 writing report",
      })
    end)
  end)
end
