-- Automatic summary-refresh autocmds for the configured mode (shell).

local buffer = require("daylog.buffer")
local report_buffers = require("daylog.report")

local M = {}

-- Wire the autocmds that drive automatic summary refresh for the configured
-- mode. `off` installs nothing (manual :Daylog refresh still works) but still
-- clears any autocmds a previous setup() left behind.
function M.setup(mode)
  local group = vim.api.nvim_create_augroup("DaylogAutoSummary", { clear = true })
  if mode == "off" then
    return
  end

  local function on_daylog_buffer(opts, action)
    if vim.bo[opts.buf].filetype == "daylog" then
      action()
    end
  end

  local function refresh(opts)
    on_daylog_buffer(opts, function()
      buffer.apply_refresh(true)
      report_buffers.refresh_report_windows()
    end)
  end

  if mode == "save" then
    vim.api.nvim_create_autocmd("BufWritePre", { group = group, callback = refresh })
  elseif mode == "idle" then
    vim.api.nvim_create_autocmd(
      { "CursorHold", "CursorHoldI", "InsertLeave" },
      { group = group, callback = refresh }
    )
  elseif mode == "change" then
    -- Debounce per buffer so the last change in a burst refreshes, and a burst in one daylog
    -- never cancels another daylog's pending refresh. The deferred refresh re-checks at fire
    -- time (not just at schedule) that this is still the buffer's last change and that the
    -- buffer is still current -- apply_refresh acts on the current buffer -- so switching away
    -- within the 200ms window never refreshes the wrong buffer.
    local generations = {}
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      callback = function(opts)
        on_daylog_buffer(opts, function()
          local buf = opts.buf
          generations[buf] = (generations[buf] or 0) + 1
          local scheduled = generations[buf]
          vim.defer_fn(function()
            if scheduled ~= generations[buf] or vim.api.nvim_get_current_buf() ~= buf then
              return
            end
            on_daylog_buffer({ buf = buf }, function()
              buffer.apply_refresh(true)
              report_buffers.refresh_report_windows()
            end)
          end, 200)
        end)
      end,
    })
  end
end

return M
