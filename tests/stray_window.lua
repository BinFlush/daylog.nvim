-- Shell tests for render_stray's window resolution: the stray mark reads the cursor of a window
-- actually showing the target buffer, so a highlight pass over a non-current buffer (as
-- toggle_time_bar runs) never plants the sign at the current window's row -- and a buffer shown
-- in no window gets no mark at all.
return function(t)
  local daylog = require("daylog")
  local config = require("daylog.config")

  local function stray_lnums(buf)
    local placed = vim.fn.sign_getplaced(buf, { group = "daylog_stray" })
    local lnums = {}
    for _, sign in ipairs(placed[1] and placed[1].signs or {}) do
      lnums[#lnums + 1] = sign.lnum
    end
    table.sort(lnums)
    return lnums
  end

  -- A clean file with two logs; the active (second) log starts at row 11.
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

  t.test("stray: highlighting a non-current buffer reads that buffer's window cursor", function()
    config.setup()
    vim.cmd("only")
    t.reset(two_logs)
    local daylog_buf = vim.api.nvim_get_current_buf()
    t.set_cursor(2) -- strayed: above the active log
    daylog.refresh_indicators(daylog_buf) -- caches daylog_active_start
    t.eq(stray_lnums(daylog_buf), { 2 })

    -- Show a different buffer in a new current window, cursor on another (stray-range) row.
    vim.cmd("new")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three", "four", "five" })
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    t.ok(vim.api.nvim_get_current_buf() ~= daylog_buf, "the daylog buffer is not current")

    -- The mark must sit at the daylog window's cursor row, not the current window's.
    daylog.render_stray(daylog_buf)
    t.eq(stray_lnums(daylog_buf), { 2 })

    vim.cmd("only")
  end)

  t.test("stray: a buffer shown in no window gets no stray mark", function()
    config.setup()
    vim.cmd("only")
    t.reset(two_logs)
    local daylog_buf = vim.api.nvim_get_current_buf()
    t.set_cursor(2)
    daylog.refresh_indicators(daylog_buf)
    t.eq(stray_lnums(daylog_buf), { 2 })

    -- Hide the buffer behind a fresh one in the only window: no cursor to mark, and the pass
    -- clears the previous sign rather than leaving it stale.
    vim.cmd("enew")
    daylog.render_stray(daylog_buf)
    t.eq(stray_lnums(daylog_buf), {})
  end)
end
