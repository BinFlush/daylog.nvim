local M = {}

-- Filetype registration (shell): maps `.day` to the `daylog` filetype via vim.filetype.add, once.

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
