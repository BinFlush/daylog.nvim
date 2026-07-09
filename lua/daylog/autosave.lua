-- Debounced autosave for daylog buffers (shell): write a `.day` buffer to disk a configurable number of
-- seconds after its last edit. Sibling of auto_summary; refreshing the summary stays that module's job --
-- a normal `:write` here runs whatever BufWrite hooks (including auto_summary's `save` mode) the user has.

local buffer = require("daylog.buffer")

local M = {}

-- Write `buf` to disk iff it is a real, modified daylog file. Excludes the read-only report/export
-- scratch buffers (nofile, not filetype daylog) and unnamed buffers. Uses `:write` (never writefile) so
-- Neovim keeps the buffer<->file mapping, clears `modified`, and runs the user's BufWrite* autocmds.
function M.save(buf)
  if
    not vim.api.nvim_buf_is_valid(buf)
    or vim.bo[buf].filetype ~= "daylog"
    or vim.bo[buf].buftype ~= ""
    or vim.api.nvim_buf_get_name(buf) == ""
    or not vim.bo[buf].modified
  then
    return
  end

  local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("silent write")
  end)
  if not ok then
    buffer.warn("daylog: autosave failed: " .. tostring(err))
  end
end

-- Wire the debounced-autosave autocmd for `delay_seconds`; a falsy delay installs nothing but still
-- clears a previous setup()'s autocmds (teardown-safe re-setup).
function M.setup(delay_seconds)
  local group = vim.api.nvim_create_augroup("DaylogAutosave", { clear = true })
  if not delay_seconds then
    return
  end

  local delay_ms = math.floor(delay_seconds * 1000 + 0.5)

  -- Debounce per buffer: a newer edit bumps the generation so the older pending write no-ops (that IS
  -- "reset the timer"). The write persists the buffer even if the user has since switched away from it.
  local generations = {}
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(opts)
      if vim.bo[opts.buf].filetype ~= "daylog" then
        return
      end
      local buf = opts.buf
      generations[buf] = (generations[buf] or 0) + 1
      local scheduled = generations[buf]
      vim.defer_fn(function()
        if scheduled == generations[buf] then
          M.save(buf)
        end
      end, delay_ms)
    end,
  })
end

return M
