return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local analyze = require("blotter.analyze")
  local document = require("blotter.document")
  local render = require("blotter.render")
  local summary = require("blotter.summary")
  local with_captured_notify = helpers.with_captured_notify
  local with_mocked_confirm = helpers.with_mocked_confirm
  local with_mocked_time = helpers.with_mocked_time
  local with_worklog_setup = helpers.with_worklog_setup
  local write_journal_file = helpers.write_journal_file

  helpers.setup_worklog()

  -- A complete day file: the given header + blots followed by a blank line and the
  -- generated summary, the way a real journal day exists on disk (every valid
  -- worklog carries a summary). run_by_value needs that summary region to rewrite.
  local function with_summary(source_lines)
    local block = analyze.get_active_worklog(analyze.analyze(document.parse(source_lines)))
    local rendered = render.summary_lines(summary.summarize_block(block), block.duration_format, {
      leading_blank = false,
      quantize_minutes = block.quantize_minutes,
    })

    local out = {}
    for _, line in ipairs(source_lines) do
      out[#out + 1] = line
    end
    out[#out + 1] = ""
    for _, line in ipairs(rendered) do
      out[#out + 1] = line
    end
    return out
  end

  -- Monday/Wednesday of ISO week 21, with a Thursday anchor so :BlotterWeek covers
  -- both. directory "%Y/%V" places them under the same week folder.
  local d1 = os.time({ year = 2026, month = 5, day = 18, hour = 12, min = 0, sec = 0 })
  local d2 = os.time({ year = 2026, month = 5, day = 20, hour = 12, min = 0, sec = 0 })
  local week_time = os.time({ year = 2026, month = 5, day = 21, hour = 10, min = 0, sec = 0 })

  -- The 1-based report-buffer row of an activity line, in the aggregate section
  -- (after "--- week summary ---") or, when aggregate is false, the first per-day
  -- occurrence.
  local function activity_row(text, aggregate)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local in_aggregate = false
    for i, line in ipairs(lines) do
      if line:match("^%-%-%- week summary ") then
        in_aggregate = true
      end
      if in_aggregate == aggregate and line:match("%) " .. text .. "$") then
        return i
      end
    end
  end

  local function open_week()
    local p1 = write_journal_file(
      vim.g._wkl_root,
      "%Y/%V",
      d1,
      with_summary({
        "--- blots #ClientA ---",
        "08:00 implementation",
        "10:00 meeting",
        "11:00 done",
      })
    )
    local p2 = write_journal_file(
      vim.g._wkl_root,
      "%Y/%V",
      d2,
      with_summary({
        "--- blots #ClientA ---",
        "09:00 implementation",
        "12:00 review",
        "13:00 done",
      })
    )

    with_mocked_time(week_time, function()
      vim.cmd("BlotterWeek")
    end)

    return p1, p2
  end

  t.test("renaming an aggregate activity from a week report rewrites every day file", function()
    vim.g._wkl_root = vim.fn.tempname()

    with_worklog_setup({
      journal = { root = vim.g._wkl_root, directory = "%Y/%V" },
    }, function()
      local p1, p2 = open_week()

      local row = activity_row("implementation", true)
      t.ok(row ~= nil, "aggregate implementation row found")
      vim.api.nvim_win_set_cursor(0, { row, 0 })

      with_mocked_confirm(1, function()
        vim.cmd("BlotRename coding")
      end)

      -- Both day files on disk are rewritten, summaries included.
      t.ok(vim.tbl_contains(vim.fn.readfile(p1), "08:00 coding"), "day 1 blot renamed")
      t.ok(vim.tbl_contains(vim.fn.readfile(p2), "09:00 coding"), "day 2 blot renamed")
      t.ok(not vim.tbl_contains(vim.fn.readfile(p1), "08:00 implementation"), "day 1 old gone")

      -- The report itself reflects the rename.
      t.ok(activity_row("coding", true) ~= nil, "aggregate row now shows coding")
    end)
  end)

  t.test("renaming a per-day row from a week report touches only that day", function()
    vim.g._wkl_root = vim.fn.tempname()

    with_worklog_setup({
      journal = { root = vim.g._wkl_root, directory = "%Y/%V" },
    }, function()
      local p1, p2 = open_week()

      local row = activity_row("implementation", false)
      t.ok(row ~= nil, "per-day implementation row found")
      vim.api.nvim_win_set_cursor(0, { row, 0 })

      with_mocked_confirm(1, function()
        vim.cmd("BlotRename coding")
      end)

      -- Only day 1 (the cursor's day) changed; day 2 is untouched.
      t.ok(vim.tbl_contains(vim.fn.readfile(p1), "08:00 coding"), "day 1 blot renamed")
      t.ok(vim.tbl_contains(vim.fn.readfile(p2), "09:00 implementation"), "day 2 untouched")
    end)
  end)

  t.test("declining the confirmation leaves every day file untouched", function()
    vim.g._wkl_root = vim.fn.tempname()

    with_worklog_setup({
      journal = { root = vim.g._wkl_root, directory = "%Y/%V" },
    }, function()
      local p1, p2 = open_week()

      vim.api.nvim_win_set_cursor(0, { activity_row("implementation", true), 0 })

      with_mocked_confirm(2, function() -- No
        vim.cmd("BlotRename coding")
      end)

      t.ok(vim.tbl_contains(vim.fn.readfile(p1), "08:00 implementation"), "day 1 unchanged")
      t.ok(vim.tbl_contains(vim.fn.readfile(p2), "09:00 implementation"), "day 2 unchanged")
    end)
  end)

  t.test("a report header row reports it is not renamable", function()
    vim.g._wkl_root = vim.fn.tempname()

    with_worklog_setup({
      journal = { root = vim.g._wkl_root, directory = "%Y/%V" },
    }, function()
      open_week()

      -- The first line is a labeled section header.
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      with_captured_notify(function(messages)
        vim.cmd("BlotRename coding")
        t.ok(#messages == 1, "one warning")
        t.ok(messages[1].message:match("^worklog:"), "worklog-prefixed warning")
      end)
    end)
  end)
end
