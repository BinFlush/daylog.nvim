return function(t)
  local filetype = require("daylog.filetype")

  filetype.register()

  t.test("entry files map to the daylog filetype", function()
    t.eq(vim.filetype.match({ filename = "today.day" }), "daylog")
  end)
end
