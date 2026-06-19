local M = {}

local registered = false

function M.register()
  if registered then
    return
  end

  vim.filetype.add({
    extension = {
      wkl = "worklog",
    },
  })

  registered = true
end

return M
