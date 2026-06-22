-- ftplugin for daylog buffers (shell): attach the parser-driven highlighter and
-- keep it current as the buffer changes. Requiring the core here means
-- highlighting works on any daylog file, with or without a prior
-- require("daylog").setup() -- the same way the old syntax file did, but driven
-- from the parser (see lua/daylog/highlight.lua) instead of duplicated regexes.

local daylog = require("daylog")

daylog.highlight_buffer(0)

-- Programmatic edits from the daylog commands refresh highlights themselves; this
-- buffer-local autocmd covers ordinary typing. The guard keeps a re-sourced
-- ftplugin (e.g. :edit) from stacking duplicate autocmds.
if not vim.b.daylog_highlight_attached then
  vim.b.daylog_highlight_attached = true

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = 0,
    callback = function(args)
      daylog.highlight_buffer(args.buf)
    end,
  })
end
