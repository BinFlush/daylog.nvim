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
      -- ]d / [d + a 12-key <leader>d cluster + g? = 15 normal maps; dm / dR also bind visual mode.
      t.eq(#buffer_maps(), 15)
      local nav = buffer_map("]d")
      t.ok(nav ~= nil and nav.callback ~= nil, "]d should map to a callback")
      t.ok(nav.desc ~= nil and nav.desc:match("next day") ~= nil, "]d should carry a per-key desc")
      t.ok(buffer_map("[d") ~= nil, "[d should be mapped")
      t.ok(buffer_map("g?") ~= nil, "g? should open the keys popup")

      -- <leader>d expands with the configured leader, so assert by description, not lhs. rename
      -- took dR (refresh moved to df); map + rename also bind a visual-mode <leader>d map.
      local function any_desc(maps, needle)
        for _, map in ipairs(maps) do
          if map.desc ~= nil and map.desc:match(needle) ~= nil then
            return true
          end
        end
        return false
      end
      local visual = vim.api.nvim_buf_get_keymap(0, "x")
      t.ok(any_desc(buffer_maps(), "rename the entry"), "rename is bound on dR")
      t.eq(#visual, 2)
      t.ok(any_desc(visual, "map the selection"), "visual map is bound")
      t.ok(any_desc(visual, "rename the selection"), "visual rename is bound")
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

  t.test("re-setup with keymaps off removes the maps from open daylog buffers", function()
    with_daylog_setup({ keymaps = true }, function()
      as_daylog_buffer()
      t.ok(#buffer_maps() > 0, "the default set is applied first")

      require("daylog").setup({})
      t.eq(#buffer_maps(), 0)
      t.eq(#vim.api.nvim_buf_get_keymap(0, "x"), 0)
    end)
  end)

  t.test("re-setup with a custom table replaces the default set, never stacking", function()
    with_daylog_setup({ keymaps = true }, function()
      as_daylog_buffer()
      t.ok(buffer_map("]d") ~= nil, "the default set is applied first")

      require("daylog").setup({ keymaps = { ["<C-n>"] = "<Cmd>Daylog new<CR>" } })
      t.eq(#buffer_maps(), 1)
      t.ok(buffer_map("]d") == nil, "the default ]d is removed on re-setup")
      t.eq(#vim.api.nvim_buf_get_keymap(0, "x"), 0)
    end)
  end)

  t.test("re-running setup with keymaps = true does not stack duplicates", function()
    with_daylog_setup({ keymaps = true }, function()
      as_daylog_buffer()
      local normal_count = #buffer_maps()

      require("daylog").setup({ keymaps = true })
      t.eq(#buffer_maps(), normal_count)
      t.eq(#vim.api.nvim_buf_get_keymap(0, "x"), 2)
    end)
  end)

  t.test("the keymaps table is copied: post-setup mutation cannot bypass validation", function()
    local user = { ["<C-n>"] = "<Cmd>Daylog new<CR>" }
    with_daylog_setup({ keymaps = user }, function()
      user["<C-x>"] = 42 -- invalid rhs; setup would have rejected it
      t.eq(require("daylog.config").get().keymaps, { ["<C-n>"] = "<Cmd>Daylog new<CR>" })
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
