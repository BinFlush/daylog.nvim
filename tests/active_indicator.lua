-- Shell tests for the active-log awareness layer: refresh_indicators places a soft-green
-- bar down the active log (body + summary) on a clean 2+-log file, and render_stray places a
-- soft-red bar on the cursor's line when it strays above the active log. A diagnostic in any
-- log, a single log, or the disabled option suppresses the whole layer. Drives the
-- 0 = current-buffer path, guarding the sign_* buffer resolution too.
return function(t)
  local daylog = require("daylog")
  local config = require("daylog.config")

  local function sign_lnums(group)
    local buf = vim.api.nvim_get_current_buf()
    local placed = vim.fn.sign_getplaced(buf, { group = group })
    local lnums = {}
    for _, sign in ipairs(placed[1] and placed[1].signs or {}) do
      lnums[#lnums + 1] = sign.lnum
    end
    table.sort(lnums)
    return lnums
  end
  local function active_lnums()
    return sign_lnums("daylog_active")
  end
  local function stray_lnums()
    return sign_lnums("daylog_stray")
  end

  -- A clean file with two logs; the active (second) log spans rows 11-13.
  local two_logs = {
    "--- log ---",
    "08:00 a",
    "09:00 done",
    "",
    "--- summary q=15 d=dec ---",
    "1.00h (+0m) a",
    "",
    "--- totals ---",
    "1.00h (+0m) workday",
    "",
    "--- log ---",
    "10:00 b",
    "11:00 done",
  }

  t.test("awareness: the green bar spans the active log on a clean 2+-log file", function()
    config.setup()
    t.reset(two_logs)
    daylog.refresh_indicators(0)
    t.eq(active_lnums(), { 11, 12, 13 })
  end)

  t.test("awareness: the green bar marks a single-log file too (no stray possible)", function()
    config.setup()
    t.reset({ "--- log ---", "08:00 a", "09:00 done" })
    daylog.refresh_indicators(0)
    t.eq(active_lnums(), { 1, 2, 3 })
    t.eq(stray_lnums(), {})
  end)

  t.test("awareness: active_indicator = false shows nothing", function()
    config.setup({ active_indicator = false })
    t.reset(two_logs)
    daylog.refresh_indicators(0)
    t.eq(active_lnums(), {})
    config.setup()
  end)

  t.test("awareness: a diagnostic suppresses the whole layer", function()
    config.setup()
    t.reset({
      "--- log ---",
      "10:00 a",
      "09:00 b", -- out of order -> an "unordered timestamps" diagnostic
      "",
      "--- log ---",
      "12:00 c",
      "13:00 done",
    })
    t.set_cursor(2) -- cursor inside the first log
    daylog.refresh_indicators(0)
    t.eq(active_lnums(), {}) -- green suppressed by the warning
    t.eq(stray_lnums(), {}) -- and so is the stray mark
  end)

  t.test("awareness: a red mark tracks the cursor in a non-active log", function()
    config.setup()
    t.reset(two_logs)
    t.set_cursor(2) -- inside the first (stale) log
    daylog.refresh_indicators(0)
    t.eq(active_lnums(), { 11, 12, 13 })
    t.eq(stray_lnums(), { 2 })

    -- Moving into the active log clears the mark.
    t.set_cursor(12)
    daylog.render_stray(0)
    t.eq(stray_lnums(), {})

    -- ...and back into a stale log shows it again, on the new line.
    t.set_cursor(3)
    daylog.render_stray(0)
    t.eq(stray_lnums(), { 3 })
  end)

  t.test(
    "awareness: the live highlight pass re-places the bar after its signs are dropped",
    function()
      config.setup()
      t.reset(two_logs)
      daylog.refresh_indicators(0)
      t.eq(active_lnums(), { 11, 12, 13 })

      -- An edit (e.g. the auto-refresh regenerating a summary) can drop the bar's signs; the live
      -- highlight pass restores them from the cached clean flag, without re-checking warnings.
      vim.fn.sign_unplace("daylog_active", { buffer = vim.api.nvim_get_current_buf() })
      t.eq(active_lnums(), {})
      daylog.highlight_buffer(0)
      t.eq(active_lnums(), { 11, 12, 13 })
    end
  )

  t.test(
    "awareness: render_stray re-syncs the cursor mark, clearing a stale/shifted sign",
    function()
      config.setup()
      t.reset(two_logs)
      t.set_cursor(2)
      daylog.refresh_indicators(0)
      t.eq(stray_lnums(), { 2 })

      -- A sign shifted to the wrong line (an `O` above) or dropped (a regen replacing the line) must
      -- not stick: render_stray always clears the group and re-marks the current cursor line.
      local buf = vim.api.nvim_get_current_buf()
      vim.fn.sign_unplace("daylog_stray", { buffer = buf })
      vim.fn.sign_place(0, "daylog_stray", "DaylogStray", buf, { lnum = 5 })
      t.eq(stray_lnums(), { 5 })
      daylog.render_stray(0)
      t.eq(stray_lnums(), { 2 })
    end
  )
end
