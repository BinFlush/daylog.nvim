return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_daylog_setup = helpers.with_daylog_setup

  -- Buffer-local normal-mode maps in the current buffer.
  local function buffer_maps()
    return vim.api.nvim_buf_get_keymap(0, "n")
  end

  local function buffer_map(lhs)
    for _, map in ipairs(buffer_maps()) do
      if map.lhs == lhs then
        return map
      end
    end
    return nil
  end

  local function as_daylog_buffer()
    t.reset({ "--- log ---" })
    vim.bo.filetype = "daylog"
  end

  t.test("keymaps default off applies no buffer-local maps", function()
    with_daylog_setup({}, function()
      as_daylog_buffer()
      t.eq(#buffer_maps(), 0)
    end)
  end)

  t.test("keymaps = true applies the default set buffer-locally, as callbacks", function()
    with_daylog_setup({ keymaps = true }, function()
      as_daylog_buffer()
      -- ]d / [d + an 8-key <localleader> cluster = 10 maps, each a Lua callback (not a string).
      t.eq(#buffer_maps(), 10)
      local nav = buffer_map("]d")
      t.ok(nav ~= nil and nav.callback ~= nil, "]d should map to a callback")
      t.ok(buffer_map("[d") ~= nil, "[d should be mapped")
    end)
  end)

  t.test("a keymaps table replaces the default set (string or function rhs)", function()
    with_daylog_setup({
      keymaps = {
        ["<C-n>"] = "<Cmd>Daylog new<CR>",
        ["<C-r>"] = function() end,
      },
    }, function()
      as_daylog_buffer()
      t.eq(#buffer_maps(), 2)
      t.ok(buffer_map("]d") == nil, "the default ]d is not applied with a custom table")
    end)
  end)

  t.test("keymaps are not applied outside a daylog buffer", function()
    with_daylog_setup({ keymaps = true }, function()
      t.reset({ "scratch" })
      vim.bo.filetype = "text"
      t.eq(#buffer_maps(), 0)
    end)
  end)
end
