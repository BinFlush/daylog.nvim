return function(t)
  local filetype = require("worklog.filetype")

  filetype.register()

  t.test("wkl files map to the worklog filetype", function()
    t.eq(vim.filetype.match({ filename = "today.wkl" }), "worklog")
  end)
end
