local M = {}

-- Filetype registration (shell). Maps the `.day` extension to the `daylog` filetype via
-- vim.filetype.add, once, so the rest of the plugin can key off the filetype.

local registered = false

function M.register()
  if registered then
    return
  end

  vim.filetype.add({
    extension = {
      day = "daylog",
    },
  })

  registered = true
end

return M
