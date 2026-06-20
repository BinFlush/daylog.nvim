return function(t)
  local filetype = require("blotter.filetype")

  filetype.register()

  t.test("blot files map to the blotter filetype", function()
    t.eq(vim.filetype.match({ filename = "today.blot" }), "blotter")
  end)
end
