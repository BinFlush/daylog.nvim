-- ftplugin for daylog buffers (shell): attach the parser-driven highlighter and
-- keep it current as the buffer changes. Requiring the core here means
-- highlighting works on any daylog file, with or without a prior
-- require("daylog").setup() -- the same way the old syntax file did, but driven
-- from the parser (see lua/daylog/highlight.lua) instead of duplicated regexes.

local daylog = require("daylog")

daylog.refresh_indicators(0)

-- The buffer-local autocmds below keep the highlights + active-log bars current as you edit
-- (programmatic edits from the commands refresh themselves). The guard keeps a re-sourced
-- ftplugin (e.g. :edit) from stacking duplicate autocmds.
if not vim.b.daylog_highlight_attached then
  vim.b.daylog_highlight_attached = true

  -- Live render, including mid-insert: token spans, plus the bars track the buffer/cursor. The
  -- clean/dirty gate stays frozen here (cached), so the bars follow your edits without flicker.
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = 0,
    callback = function(args)
      daylog.highlight_buffer(args.buf)
    end,
  })

  -- Settle: re-evaluate the gate (any diagnostic hides the bars) and render -- the moments the
  -- diagnostics themselves refresh (normal-mode edits, leaving insert).
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    buffer = 0,
    callback = function(args)
      daylog.refresh_indicators(args.buf)
    end,
  })

  -- The stray-cursor mark follows the cursor in any mode (it reads the cached boundary).
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = 0,
    callback = function(args)
      daylog.render_stray(args.buf)
    end,
  })

  -- The time bar lives in a reserved bottom split sized to the window's width, so redraw it when the
  -- buffer is shown in a window and when the terminal is resized, to re-fit its contents.
  vim.api.nvim_create_autocmd({ "VimResized", "BufWinEnter" }, {
    buffer = 0,
    callback = function(args)
      daylog.highlight_buffer(args.buf)
    end,
  })

  -- WinResized (Neovim 0.9+) re-fits the bar after a split resize; pcall keeps the 0.8 floor, where
  -- the event does not exist and registering it would error.
  pcall(vim.api.nvim_create_autocmd, "WinResized", {
    buffer = 0,
    callback = function(args)
      daylog.highlight_buffer(args.buf)
    end,
  })

  -- Mouse-hover tooltip over the time bar (opt-in via `time_bar_hover`; also needs `:set
  -- mousemoveevent`, which daylog never sets for you). Buffer-local so it only fires while a daylog
  -- file is focused; the handler hit-tests the bar strip and shows/hides the time + activity popup.
  if require("daylog.config").get().time_bar_hover then
    vim.keymap.set({ "n", "i" }, "<MouseMove>", function()
      require("daylog.timebar_ui").on_mouse_move()
    end, { buffer = 0 })
  end
end
