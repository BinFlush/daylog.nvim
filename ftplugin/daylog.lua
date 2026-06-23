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
end
