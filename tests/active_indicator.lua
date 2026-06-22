-- Shell test for the active-log sign indicator: render_active_indicator places a
-- soft-green sign on every line of the active log (its body + summary) once a file
-- holds two or more logs. Drives highlight_buffer(0) -- the 0 = current-buffer path the
-- sign_* API rejects -- so it also guards that resolution.
return function(t)
  local daylog = require("daylog")
  local config = require("daylog.config")

  local function active_sign_lnums()
    local buf = vim.api.nvim_get_current_buf()
    local placed = vim.fn.sign_getplaced(buf, { group = "daylog_active" })
    local lnums = {}
    for _, sign in ipairs(placed[1] and placed[1].signs or {}) do
      lnums[#lnums + 1] = sign.lnum
    end
    table.sort(lnums)
    return lnums
  end

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

  t.test("active indicator: signs span the active log when a file has 2+ logs", function()
    config.setup()
    t.reset(two_logs)
    daylog.highlight_buffer(0)
    -- The active (second) log runs from its header (row 11) to EOF (row 13).
    t.eq(active_sign_lnums(), { 11, 12, 13 })
  end)

  t.test("active indicator: a single-log file places no signs", function()
    config.setup()
    t.reset({ "--- log ---", "08:00 a", "09:00 done" })
    daylog.highlight_buffer(0)
    t.eq(active_sign_lnums(), {})
  end)

  t.test("active indicator: active_indicator = false places no signs", function()
    config.setup({ active_indicator = false })
    t.reset(two_logs)
    daylog.highlight_buffer(0)
    t.eq(active_sign_lnums(), {})
    config.setup()
  end)
end
