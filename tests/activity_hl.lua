-- Shell test for the per-activity highlight groups: each is defined lazily from the generated
-- palette on first use. (The ColorScheme re-creation is verified by hand -- it needs a real
-- :colorscheme to clear the default groups.)
return function(t)
  local activity_hl = require("daylog.activity_hl")

  t.test("activity_hl lazily defines a bar group from the palette", function()
    t.eq(activity_hl.bar_group(1), "DaylogBar1")
    t.ok(vim.api.nvim_get_hl(0, { name = "DaylogBar1" }).bg ~= nil, "DaylogBar1 has a background")
  end)

  t.test("activity_hl lazily defines a sign and its colour group", function()
    t.eq(activity_hl.activity_sign(2), "DaylogActivitySign2")
    t.ok(vim.api.nvim_get_hl(0, { name = "DaylogSign2" }).fg ~= nil, "DaylogSign2 has a foreground")
    t.ok(vim.fn.sign_getdefined("DaylogActivitySign2")[1] ~= nil, "the sign is defined")
  end)
end
