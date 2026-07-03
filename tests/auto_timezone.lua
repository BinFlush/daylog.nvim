return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_mocked_time = helpers.with_mocked_time
  local with_mocked_date = helpers.with_mocked_date
  local with_mocked_utc_offset = helpers.with_mocked_utc_offset
  local with_captured_notify = helpers.with_captured_notify
  local with_daylog_setup = helpers.with_daylog_setup

  local insert_now = require("daylog.usecases.insert_now")
  local insert_entry = require("daylog.usecases.insert_entry")
  local repeat_current = require("daylog.usecases.repeat_current")

  helpers.setup_daylog()

  -- The lines an insert/repeat use case would write (these use cases return one edit).
  local function written(result)
    return result.edits[1].lines
  end

  -- Pure use-case stamping: a baseline header offset of utc+2 (120), a live offset of
  -- utc+1 (60) is the "DST fell back / travelled west" drift. Everything is passed in,
  -- so no clock mocking is needed.

  t.test("insert_entry stamps the drifted offset and reports the change", function()
    local lines = { "--- log utc+2 ---", "08:00 standup", "10:00 done" }
    -- 11:00 is past the last entry, so there is no follower to compensate.
    local result = insert_entry.run(lines, 2, "11:00", "meeting", 60)

    t.eq(written(result), { "11:00 meeting utc+1" })
    t.eq(result.offset_change, { from = 120, to = 60 })
  end)

  t.test("insert_entry adds no token when the live offset matches the baseline", function()
    local lines = { "--- log utc+2 ---", "08:00 standup", "10:00 done" }
    local result = insert_entry.run(lines, 2, "11:00", "meeting", 120)

    t.eq(written(result), { "11:00 meeting" })
    t.eq(result.offset_change, nil)
  end)

  t.test("insert_entry leaves an offset-naive log untouched (no baseline to drift from)", function()
    local lines = { "--- log ---", "08:00 standup", "10:00 done" }
    local result = insert_entry.run(lines, 2, "11:00", "meeting", 60)

    t.eq(written(result), { "11:00 meeting" })
    t.eq(result.offset_change, nil)
  end)

  t.test("insert_entry compensates a follower silently inheriting the old offset", function()
    local lines = { "--- log utc+2 ---", "08:00 standup", "10:00 done" }
    -- 09:00 lands before "10:00 done", which was inheriting utc+2; it must keep it.
    local result = insert_entry.run(lines, 2, "09:00", "meeting", 60)

    t.eq(written(result), { "09:00 meeting utc+1", "10:00 done utc+2" })
    t.eq(result.offset_change, { from = 120, to = 60 })
  end)

  t.test("insert_now (bare) records a drift with a two-space gutter and a gap cursor", function()
    local lines = { "--- log utc+2 ---", "08:00 standup", "10:00 done" }
    local result = insert_now.run(lines, 2, "11:00", 60)

    -- The activity is not typed yet, so the offset trails a two-space gutter; the cursor
    -- lands in the gap (#"11:00" + 1 = 6) so typing yields "11:00 <text> utc+1".
    t.eq(written(result), { "11:00  utc+1" })
    t.eq(result.cursor, { 4, 6 })
    -- "cursor" tells the shell to enter insert mode AT the gap (plain startinsert);
    -- a plain-true append (`startinsert!`) would jump past the utc token and corrupt it.
    t.eq(result.startinsert, "cursor")
    t.eq(result.offset_change, { from = 120, to = 60 })
  end)

  t.test("insert_now (bare) is unchanged with no drift", function()
    local lines = { "--- log utc+2 ---", "08:00 standup", "10:00 done" }

    local same = insert_now.run(lines, 2, "11:00", 120)
    t.eq(written(same), { "11:00 " })
    t.eq(same.offset_change, nil)

    local none = insert_now.run(lines, 2, "11:00", nil)
    t.eq(written(none), { "11:00 " })
    t.eq(none.offset_change, nil)
  end)

  t.test("repeat_current stamps the live offset onto the repeated activity", function()
    local lines = { "--- log utc+2 ---", "08:00 standup", "10:00 done" }
    local result = repeat_current.run(lines, 2, "11:00", 60)

    t.eq(written(result), { "11:00 standup utc+1" })
    t.eq(result.offset_change, { from = 120, to = 60 })
  end)

  -- Command wiring: the live offset is polled from os.date("%z"). with_mocked_utc_offset
  -- answers "%z" while with_mocked_date answers "%H:%M" (and with_mocked_time fixes the
  -- daybook date for the today cases).

  t.test("Daylog insert records an offset change and notifies", function()
    with_daylog_setup({}, function()
      t.reset({ "--- log utc+2 ---", "08:00 standup", "10:00 done" })

      with_captured_notify(function(messages)
        with_mocked_date("11:00", function()
          with_mocked_utc_offset("+0100", function()
            vim.cmd("Daylog insert")
          end)
        end)

        t.eq(t.get_lines()[4], "11:00  utc+1")
        t.eq(messages, {
          { message = "daylog: UTC offset utc+2 → utc+1 recorded", level = vim.log.levels.INFO },
        })
      end)
    end)
  end)

  t.test("Daylog insert adds nothing and stays silent when the zone is unchanged", function()
    with_daylog_setup({}, function()
      t.reset({ "--- log utc+2 ---", "08:00 standup", "10:00 done" })

      with_captured_notify(function(messages)
        with_mocked_date("11:00", function()
          with_mocked_utc_offset("+0200", function()
            vim.cmd("Daylog insert")
          end)
        end)

        t.eq(t.get_lines()[4], "11:00 ")
        t.eq(#messages, 0)
      end)
    end)
  end)

  t.test("auto_timezone = false suppresses per-insert stamping", function()
    with_daylog_setup({ auto_timezone = false }, function()
      t.reset({ "--- log utc+2 ---", "08:00 standup", "10:00 done" })

      with_mocked_date("11:00", function()
        with_mocked_utc_offset("+0100", function()
          vim.cmd("Daylog insert")
        end)
      end)

      t.eq(t.get_lines()[4], "11:00 ")
    end)
  end)

  -- New-day header baseline. os.time({...}) is the local-time inverse of os.date, so the
  -- stamped entry time is machine-independent; only the offset is mocked.
  local function today_header(setup, offset_string)
    local root = vim.fn.tempname()
    local now = os.time({ year = 2026, month = 5, day = 18, hour = 8, min = 45, sec = 0 })
    local header
    setup.daybook = { root = root, directory = "%Y/%V" }

    with_daylog_setup(setup, function()
      vim.cmd("enew!")
      vim.bo.modified = false
      with_mocked_time(now, function()
        with_mocked_utc_offset(offset_string, function()
          vim.cmd("Daylog today")
        end)
      end)
      header = t.get_lines()[1]
    end)

    return header
  end

  t.test("today stamps the live offset into a new header by default", function()
    t.eq(today_header({}, "+0200"), "--- log utc+2 ---")
  end)

  t.test("an explicit fixed defaults.utc still wins the header", function()
    t.eq(today_header({ defaults = { utc = "+5:30" } }, "+0200"), "--- log utc+5:30 ---")
  end)

  t.test("an unresolvable %z degrades to a header with no offset", function()
    t.eq(today_header({}, ""), "--- log ---")
  end)

  t.test("auto_timezone = false leaves a new header offsetless", function()
    t.eq(today_header({ auto_timezone = false }, "+0200"), "--- log ---")
  end)
end
