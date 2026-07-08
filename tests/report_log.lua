return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")
  local render = require("daylog.render")
  local summary = require("daylog.summary")
  local with_captured_notify = helpers.with_captured_notify
  local with_mocked_confirm = helpers.with_mocked_confirm
  local with_mocked_input = helpers.with_mocked_input
  local with_mocked_time = helpers.with_mocked_time
  local with_daylog_setup = helpers.with_daylog_setup
  local write_daybook_file = helpers.write_daybook_file

  helpers.setup_daylog()

  -- A complete day file (header + entries + blank + generated summary), as it exists on disk.
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

  -- Monday and Wednesday of the same week; an explicit range covers both.
  local d1 = os.time({ year = 2026, month = 5, day = 18, hour = 12, min = 0, sec = 0 })
  local d2 = os.time({ year = 2026, month = 5, day = 20, hour = 12, min = 0, sec = 0 })
  local week_time = os.time({ year = 2026, month = 5, day = 21, hour = 10, min = 0, sec = 0 })

  -- The 1-based report-buffer row whose text matches `pattern`, in the aggregate (range) section when
  -- `aggregate`, else the first per-day occurrence.
  local function report_row(pattern, aggregate)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local in_aggregate = false
    for i, line in ipairs(lines) do
      if line:match("^%-%-%- range ") then
        in_aggregate = true
      end
      if in_aggregate == aggregate and line:match(pattern) then
        return i
      end
    end
  end

  local function file_has(path, pattern)
    for _, line in ipairs(vim.fn.readfile(path)) do
      if line:match(pattern) then
        return true
      end
    end
    return false
  end

  -- "implementation" is on both days; "meeting" only day 1; "review" only day 2. All #ClientA @office.
  local function open_report()
    vim.cmd("silent! only") -- each report opens a split; collapse leftovers so the suite doesn't E36

    local p1 = write_daybook_file(
      vim.g._entry_root,
      "%Y/%V",
      d1,
      with_summary({
        "--- log #ClientA @office ---",
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
        "--- log #ClientA @office ---",
        "09:00 implementation",
        "12:00 review",
        "13:00 done",
      })
    )

    with_mocked_time(week_time, function()
      vim.cmd("Daylog report 2026-05-18..2026-05-20")
    end)

    return p1, p2
  end

  local function log_at(row, confirm, before)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    with_mocked_input(before or "", function()
      with_mocked_confirm(confirm, function()
        vim.cmd("Daylog log")
      end)
    end)
  end

  t.test("logging an aggregate activity from a range report marks every day file", function()
    vim.g._entry_root = vim.fn.tempname()
    with_daylog_setup({ daybook = { root = vim.g._entry_root, directory = "%Y/%V" } }, function()
      local p1, p2 = open_report()

      log_at(report_row("%) implementation$", true), 1)

      t.ok(file_has(p1, "^08:00 implementation !S%[%]"), "day 1 implementation logged")
      t.ok(file_has(p2, "^09:00 implementation !S%[%]"), "day 2 implementation logged")
    end)
  end)

  t.test("logging a per-day activity row marks only that day", function()
    vim.g._entry_root = vim.fn.tempname()
    with_daylog_setup({ daybook = { root = vim.g._entry_root, directory = "%Y/%V" } }, function()
      local p1, p2 = open_report()

      -- The first per-day "implementation" is day 1's.
      log_at(report_row("%) implementation$", false), 1)

      t.ok(file_has(p1, "^08:00 implementation !S%[%]"), "day 1 logged")
      t.ok(not file_has(p2, "!S"), "day 2 untouched")
    end)
  end)

  t.test("logging an aggregate #tag marks every day file", function()
    vim.g._entry_root = vim.fn.tempname()
    with_daylog_setup({ daybook = { root = vim.g._entry_root, directory = "%Y/%V" } }, function()
      local p1, p2 = open_report()

      log_at(report_row("%) #ClientA$", true), 1)

      t.ok(file_has(p1, "!T%[%]"), "day 1 tag logged")
      t.ok(file_has(p2, "!T%[%]"), "day 2 tag logged")
    end)
  end)

  t.test("logging an aggregate @location marks every day file", function()
    vim.g._entry_root = vim.fn.tempname()
    with_daylog_setup({ daybook = { root = vim.g._entry_root, directory = "%Y/%V" } }, function()
      local p1, p2 = open_report()

      log_at(report_row("%) @office$", true), 1)

      t.ok(file_has(p1, "!L%[%]"), "day 1 location logged")
      t.ok(file_has(p2, "!L%[%]"), "day 2 location logged")
    end)
  end)

  t.test("a day without the item is skipped", function()
    vim.g._entry_root = vim.fn.tempname()
    with_daylog_setup({ daybook = { root = vim.g._entry_root, directory = "%Y/%V" } }, function()
      local p1, p2 = open_report()

      -- "meeting" only exists on day 1; the aggregate row logs only that file.
      log_at(report_row("%) meeting$", true), 1)

      t.ok(file_has(p1, "^10:00 meeting !S%[%]"), "day 1 meeting logged")
      t.ok(not file_has(p2, "!S"), "day 2 has no meeting, untouched")
    end)
  end)

  t.test("declining the confirmation writes nothing", function()
    vim.g._entry_root = vim.fn.tempname()
    with_daylog_setup({ daybook = { root = vim.g._entry_root, directory = "%Y/%V" } }, function()
      local p1, p2 = open_report()

      log_at(report_row("%) implementation$", true), 2) -- &No

      t.ok(not file_has(p1, "!S"), "day 1 unchanged")
      t.ok(not file_has(p2, "!S"), "day 2 unchanged")
    end)
  end)

  t.test("the report buffer carries the daylog keymaps so log works by shortcut", function()
    vim.g._entry_root = vim.fn.tempname()
    with_daylog_setup(
      { daybook = { root = vim.g._entry_root, directory = "%Y/%V" }, keymaps = true },
      function()
        open_report()

        local function mapped(suffix)
          for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
            if m.lhs:sub(-#suffix) == suffix then
              return true
            end
          end
          return false
        end

        -- Without these the read-only report has no `<leader>dl`, so the key falls through to `dl`
        -- (delete char) and errors with E21; report.lua applies the keymaps directly.
        t.ok(mapped("dl"), "the report has the log keymap")
        t.ok(mapped("dL"), "the report has the unlog keymap")
      end
    )
  end)

  t.test("edit commands on the read-only report warn instead of raising E21", function()
    vim.g._entry_root = vim.fn.tempname()
    with_daylog_setup({ daybook = { root = vim.g._entry_root, directory = "%Y/%V" } }, function()
      open_report()

      -- None of these apply to a report; each must fail gracefully, never raise E21.
      for _, verb in ipairs({ "insert", "order", "new", "copy", "repeat" }) do
        local ok = pcall(function()
          with_captured_notify(function()
            vim.cmd("Daylog " .. verb)
          end)
        end)
        t.ok(ok, "Daylog " .. verb .. " does not raise on a report")
      end
    end)
  end)

  t.test("apply_result refuses a read-only buffer with a warning, not E21", function()
    vim.cmd("enew")
    vim.bo.modifiable = false

    with_captured_notify(function(messages)
      require("daylog.buffer").apply_result({
        edits = { { start_index = 0, end_index = 0, lines = { "x" } } },
      })
      t.ok(
        #messages == 1 and messages[1].message:match("read%-only"),
        "a read-only buffer warns instead of editing"
      )
    end)

    t.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "" }) -- unchanged
    vim.bo.modifiable = true
  end)

  t.test("unlogging an aggregate row clears the marker across day files", function()
    vim.g._entry_root = vim.fn.tempname()
    with_daylog_setup({ daybook = { root = vim.g._entry_root, directory = "%Y/%V" } }, function()
      local p1, p2 = open_report()

      log_at(report_row("%) implementation$", true), 1)
      t.ok(file_has(p1, "!S") and file_has(p2, "!S"), "logged on both days first")

      -- The report refreshed; the row now shows the marker. Unlog it (one unnamed name -> clears
      -- outright, no picker), confirming the fan-out.
      vim.api.nvim_win_set_cursor(0, { report_row("%) implementation !S", true), 0 })
      with_mocked_confirm(1, function()
        vim.cmd("Daylog! log")
      end)

      t.ok(not file_has(p1, "!S"), "day 1 marker cleared")
      t.ok(not file_has(p2, "!S"), "day 2 marker cleared")
    end)
  end)
end
