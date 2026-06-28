return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_daylog_setup = helpers.with_daylog_setup

  -- -u NONE does not load plugin/, so source it to define the <Plug> mappings the keymap set
  -- targets.
  dofile(vim.fn.getcwd() .. "/plugin/daylog.lua")

  -- The set of normal-mode rhs values mapped buffer-locally in the current buffer.
  local function buffer_rhs()
    local set = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      set[map.rhs or ""] = true
    end
    return set
  end

  local function as_daylog_buffer()
    t.reset({ "--- log ---" })
    vim.bo.filetype = "daylog"
  end

  t.test("<Plug> mappings are defined for the frequent verbs", function()
    for _, name in ipairs({ "today", "next-day", "prev-day", "insert", "repeat", "order", "log" }) do
      t.ok(
        vim.fn.maparg("<Plug>(daylog-" .. name .. ")", "n") ~= "",
        "<Plug>(daylog-" .. name .. ") should be mapped"
      )
    end
  end)

  t.test("keymaps default off applies no buffer-local daylog maps", function()
    with_daylog_setup({}, function()
      as_daylog_buffer()
      t.ok(not buffer_rhs()["<Plug>(daylog-next-day)"])
    end)
  end)

  t.test("keymaps = true applies the default set buffer-locally in daylog files", function()
    with_daylog_setup({ keymaps = true }, function()
      as_daylog_buffer()
      local rhs = buffer_rhs()
      t.ok(rhs["<Plug>(daylog-next-day)"])
      t.ok(rhs["<Plug>(daylog-prev-day)"])
      t.ok(rhs["<Plug>(daylog-insert)"])
      t.ok(rhs["<Plug>(daylog-order)"])
    end)
  end)

  t.test("a keymaps table replaces the default set", function()
    with_daylog_setup({ keymaps = { ["<C-n>"] = "<Plug>(daylog-new)" } }, function()
      as_daylog_buffer()
      local rhs = buffer_rhs()
      t.ok(rhs["<Plug>(daylog-new)"])
      -- the default ]d -> next-day is not applied when a custom table is given
      t.ok(not rhs["<Plug>(daylog-next-day)"])
    end)
  end)

  t.test("keymaps are not applied outside a daylog buffer", function()
    with_daylog_setup({ keymaps = true }, function()
      t.reset({ "scratch" })
      vim.bo.filetype = "text"
      t.ok(not buffer_rhs()["<Plug>(daylog-next-day)"])
    end)
  end)
end
