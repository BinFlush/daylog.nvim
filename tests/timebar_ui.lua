-- Shell test for the time bar's strip open (timebar_ui). Opening the reserved bottom split sets
-- `eventignore` to a list of window/buffer transition events, and that list must hold only events
-- the running Neovim knows: WinResized is 0.9+, and an unknown name makes the `eventignore` set
-- throw E474, which crashed the bar render on the 0.8 floor. Enabling the bar and driving one
-- highlight pass exercises that set on every CI Neovim.
return function(t)
  local daylog = require("daylog")
  local config = require("daylog.config")
  local timebar_ui = require("daylog.timebar_ui")

  t.test("time bar: opening the strip never feeds eventignore an unknown event", function()
    config.setup({ time_bar = true })
    vim.cmd("only")
    t.reset({
      "--- log ---",
      "08:00 stand",
      "09:00 work",
      "10:00 done",
    })
    local buf = vim.api.nvim_get_current_buf()
    t.ok(timebar_ui.enabled(), "the bar is enabled for the pass")

    local saved = vim.o.eventignore
    -- On the 0.8 floor an unguarded WinResized in the strip's eventignore list throws E474 here.
    local ok, err = pcall(daylog.highlight_buffer, buf)
    t.ok(ok, "the bar render did not error: " .. tostring(err))
    -- The strip opened in its own split, so the eventignore path actually ran, and the transient
    -- eventignore was restored afterwards.
    t.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
    t.eq(vim.o.eventignore, saved)

    vim.cmd("only")
    config.setup()
  end)
end
