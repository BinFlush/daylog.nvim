-- Shell test for the per-activity highlight groups: each is defined lazily from the generated
-- palette on first use. (The ColorScheme re-creation is verified by hand -- it needs a real
-- :colorscheme to clear the default groups.)
return function(t)
  local activity_hl = require("daylog.activity_hl")

  -- nvim_get_hl is 0.9+; fall back to nvim_get_hl_by_name on the 0.8.0 floor (its keys
  -- differ -- background/foreground -- so normalize to the modern shape).
  local function get_hl(name)
    if vim.api.nvim_get_hl then
      return vim.api.nvim_get_hl(0, { name = name })
    end
    local hl = vim.api.nvim_get_hl_by_name(name, true)
    return { bg = hl.background, fg = hl.foreground }
  end

  t.test("activity_hl lazily defines a bar group from the palette", function()
    t.eq(activity_hl.bar_group(1), "DaylogBar1")
    t.ok(get_hl("DaylogBar1").bg ~= nil, "DaylogBar1 has a background")
  end)

  t.test("activity_hl lazily defines a sign and its colour group", function()
    t.eq(activity_hl.activity_sign(2), "DaylogActivitySign2")
    t.ok(get_hl("DaylogSign2").fg ~= nil, "DaylogSign2 has a foreground")
    t.ok(vim.fn.sign_getdefined("DaylogActivitySign2")[1] ~= nil, "the sign is defined")
  end)
end
