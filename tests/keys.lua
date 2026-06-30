return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local keys = require("daylog.keys")

  local function joined(entries)
    return table.concat(keys.format(entries), "\n")
  end

  t.test("keys.format lists each lhs with its description", function()
    local out = joined({
      { lhs = "]d", desc = "next day" },
      { lhs = "\\i", desc = "insert" },
    })
    t.ok(out:match("daylog keys") ~= nil, "has a title")
    t.ok(out:match("%]d%s+next day") ~= nil, "lists ]d -> next day")
    t.ok(out:match("\\i%s+insert") ~= nil, "lists \\i -> insert")
    t.ok(out:match(":Daylog <Tab>") ~= nil, "footer points at the full command set")
  end)

  t.test("keys.format guides when no keymaps are set", function()
    local out = joined({})
    t.ok(out:match("No keymaps set") ~= nil, "explains there are no keys")
    t.ok(out:match("keymaps = true") ~= nil, "points at the opt-in")
    t.ok(out:match(":Daylog") ~= nil, "still shows how to open today")
  end)

  t.test("require('daylog').keys() opens a float without error", function()
    helpers.with_daylog_setup({}, function()
      t.reset({ "--- log ---" })
      vim.bo.filetype = "daylog"
      require("daylog").keys()

      local float
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(win).relative ~= "" then
          float = win
        end
      end
      t.ok(float ~= nil, "a floating window opened")
      if float then
        vim.api.nvim_win_close(float, true)
      end
    end)
  end)
end
