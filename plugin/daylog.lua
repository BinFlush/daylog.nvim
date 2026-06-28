require("daylog.filetype").register()

-- <Plug> mappings for the frequent verbs, so a user can bind their own keys regardless of
-- whether setup() ran (lazy-require keeps startup cheap). Each is normal-mode and side-effect
-- free at the cursor. The argument-heavy verbs (day, report) stay typed :Daylog commands.
-- The opt-in default key set (setup({ keymaps = true })) is expressed in terms of these.
local plug = {
  ["today"] = function()
    require("daylog").today()
  end,
  ["next-day"] = function()
    require("daylog").next_day()
  end,
  ["prev-day"] = function()
    require("daylog").prev_day()
  end,
  ["insert"] = function()
    require("daylog").insert()
  end,
  ["insert-pick"] = function()
    require("daylog").insert({ pick = true })
  end,
  ["repeat"] = function()
    require("daylog").repeat_()
  end,
  ["new"] = function()
    require("daylog").new_log()
  end,
  ["copy"] = function()
    require("daylog").copy()
  end,
  ["order"] = function()
    require("daylog").order()
  end,
  ["log"] = function()
    require("daylog").log()
  end,
  ["balance-up"] = function()
    require("daylog").balance("+1")
  end,
  ["balance-down"] = function()
    require("daylog").balance("-1")
  end,
  ["split"] = function()
    require("daylog").split({})
  end,
  ["map"] = function()
    require("daylog").map({})
  end,
  ["map-clear"] = function()
    require("daylog").map({ clear = true })
  end,
  ["rename"] = function()
    require("daylog").rename({})
  end,
  ["refresh"] = function()
    require("daylog").refresh()
  end,
  ["sync"] = function()
    require("daylog").sync()
  end,
}

for name, fn in pairs(plug) do
  vim.keymap.set("n", "<Plug>(daylog-" .. name .. ")", fn, { desc = "daylog " .. name })
end
