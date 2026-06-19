-- ftplugin for worklog buffers (shell): attach the parser-driven highlighter and
-- keep it current as the buffer changes. Requiring the core here means
-- highlighting works on any worklog file, with or without a prior
-- require("blotter").setup() -- the same way the old syntax file did, but driven
-- from the parser (see lua/worklog/highlight.lua) instead of duplicated regexes.

local worklog = require("blotter")

worklog.highlight_buffer(0)

-- Programmatic edits from the worklog commands refresh highlights themselves; this
-- buffer-local autocmd covers ordinary typing. The guard keeps a re-sourced
-- ftplugin (e.g. :edit) from stacking duplicate autocmds.
if not vim.b.worklog_highlight_attached then
  vim.b.worklog_highlight_attached = true

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = 0,
    callback = function(args)
      worklog.highlight_buffer(args.buf)
    end,
  })
end
