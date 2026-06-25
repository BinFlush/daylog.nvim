return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")
  local render = require("daylog.render")
  local summary = require("daylog.summary")
  local with_captured_notify = helpers.with_captured_notify
  local with_mocked_confirm = helpers.with_mocked_confirm
  local with_mocked_time = helpers.with_mocked_time
  local with_daylog_setup = helpers.with_daylog_setup
  local write_daybook_file = helpers.write_daybook_file

  helpers.setup_daylog()

  -- A complete day file: the given header + entries followed by a blank line and the
  -- generated summary, the way a real daybook day exists on disk (every valid
  -- log carries a summary). run_by_value needs that summary region to rewrite.
  local function with_summary(source_lines)
    local block = analyze.get_active_log(analyze.analyze(document.parse(source_lines)))
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

  -- Monday and Wednesday of the same week; an explicit range covers
  -- both. directory "%Y/%V" places them under the same week folder.
  local d1 = os.time({ year = 2026, month = 5, day = 18, hour = 12, min = 0, sec = 0 })
  local d2 = os.time({ year = 2026, month = 5, day = 20, hour = 12, min = 0, sec = 0 })
  local week_time = os.time({ year = 2026, month = 5, day = 21, hour = 10, min = 0, sec = 0 })

  -- The 1-based report-buffer row of an activity line, in the aggregate section
  -- (after "--- range summary ---") or, when aggregate is false, the first per-day
  -- occurrence.
  local function activity_row(text, aggregate)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local in_aggregate = false
    for i, line in ipairs(lines) do
      if line:match("^%-%-%- range summary ") then
        in_aggregate = true
      end
      if in_aggregate == aggregate and line:match("%) " .. text .. "$") then
        return i
      end
    end
  end

  local function open_report()
    local p1 = write_daybook_file(
      vim.g._entry_root,
      "%Y/%V",
      d1,
      with_summary({
        "--- log #ClientA ---",
        "08:00 implementation",
        "10:00 meeting",
        "11:00 done",
      })
    )
    local p2 = write_daybook_file(
      vim.g._entry_root,
      "%Y/%V",
      d2,
      with_summary({
        "--- log #ClientA ---",
        "09:00 implementation",
        "12:00 review",
        "13:00 done",
      })
    )

    with_mocked_time(week_time, function()
      vim.cmd("DaylogDays 2026-05-18..2026-05-20")
    end)

    return p1, p2
  end

  -- The 1-based report-buffer row of a tag total line in the aggregate section.
  local function tag_row(tag)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local in_aggregate = false
    for i, line in ipairs(lines) do
      if line:match("^%-%-%- range summary ") then
        in_aggregate = true
      end
      if in_aggregate and line:match("%) #" .. tag .. "$") then
        return i
      end
    end
  end

  t.test("rename refuses an activity row in a report -- :DaylogMap relabels it", function()
    vim.g._entry_root = vim.fn.tempname()

    with_daylog_setup({
      daybook = { root = vim.g._entry_root, directory = "%Y/%V" },
    }, function()
      local p1, p2 = open_report()

      -- Both an aggregate row and a per-day row of an activity refuse, leaving every file
      -- untouched (rename a single entry, or :DaylogMap, to act on an activity).
      for _, aggregate in ipairs({ true, false }) do
        vim.api.nvim_win_set_cursor(0, { activity_row("implementation", aggregate), 0 })
        with_captured_notify(function(messages)
          vim.cmd("DaylogRename coding")
          t.ok(#messages == 1 and messages[1].message:match("^daylog:"), "one daylog warning")
        end)
      end

      t.ok(vim.tbl_contains(vim.fn.readfile(p1), "08:00 implementation"), "day 1 unchanged")
      t.ok(vim.tbl_contains(vim.fn.readfile(p2), "09:00 implementation"), "day 2 unchanged")
    end)
  end)

  t.test("renaming an aggregate tag from a range report rewrites every day file", function()
    vim.g._entry_root = vim.fn.tempname()

    with_daylog_setup({
      daybook = { root = vim.g._entry_root, directory = "%Y/%V" },
    }, function()
      local p1, p2 = open_report()

      local row = tag_row("ClientA")
      t.ok(row ~= nil, "aggregate #ClientA row found")
      vim.api.nvim_win_set_cursor(0, { row, 0 })

      with_mocked_confirm(1, function()
        vim.cmd("DaylogRename ClientB")
      end)

      -- A tag is a single unambiguous token, so a cross-day rename applies to it.
      t.ok(vim.tbl_contains(vim.fn.readfile(p1), "--- log #ClientB ---"), "day 1 header renamed")
      t.ok(vim.tbl_contains(vim.fn.readfile(p2), "--- log #ClientB ---"), "day 2 header renamed")
      t.ok(tag_row("ClientB") ~= nil, "aggregate row now shows #ClientB")
    end)
  end)

  t.test("a report header row reports it is not renamable", function()
    vim.g._entry_root = vim.fn.tempname()

    with_daylog_setup({
      daybook = { root = vim.g._entry_root, directory = "%Y/%V" },
    }, function()
      open_report()

      -- The first line is a labeled section header.
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      with_captured_notify(function(messages)
        vim.cmd("DaylogRename coding")
        t.ok(#messages == 1, "one warning")
        t.ok(messages[1].message:match("^daylog:"), "log-prefixed warning")
      end)
    end)
  end)
end
