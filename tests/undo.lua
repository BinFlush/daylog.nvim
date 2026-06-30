return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_daylog_setup = helpers.with_daylog_setup

  local function current()
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end

  -- A .day buffer with a real generated summary, snapshotted and sealed as its own undo block so
  -- the action under test is measured in isolation -- the suite runs synchronously, so without the
  -- seal there is no u_sync between setup and the action and undo would not separate them.
  local function staged(lines, cursor)
    t.reset(lines)
    vim.bo.filetype = "daylog"
    vim.bo.undolevels = 1000
    vim.cmd("Daylog refresh")
    if cursor then
      vim.api.nvim_win_set_cursor(0, cursor)
    end
    local before = current()
    vim.cmd("let &undolevels = &undolevels")
    return before
  end

  local function undos_to_revert(before)
    for done = 0, 8 do
      if vim.deep_equal(before, current()) then
        return done
      end
      pcall(vim.cmd, "silent undo")
    end
    return 99
  end

  -- An action's whole edit script (source rewrite + summary rebuild) must be one undo block.
  local function reverts_in_one(name, lines, cursor, action)
    with_daylog_setup({ auto_summary = "off" }, function()
      local before = staged(lines, cursor)
      action()
      t.ok(not vim.deep_equal(before, current()), name .. " should change the buffer")
      t.eq(undos_to_revert(before), 1)
    end)
  end

  t.test("a reorder reverts in one undo", function()
    reverts_in_one(
      "order",
      { "--- log ---", "10:00 b", "08:00 a", "12:00 done" },
      { 2, 0 },
      function()
        vim.cmd("Daylog order")
      end
    )
  end)

  t.test("a ranged rename reverts in one undo", function()
    reverts_in_one(
      "rename",
      { "--- log ---", "08:00 fix", "10:00 review", "12:00 done" },
      nil,
      function()
        vim.cmd("2,3Daylog rename meeting")
      end
    )
  end)

  t.test("a map reverts in one undo", function()
    reverts_in_one("map", { "--- log ---", "08:00 fix", "10:00 done" }, { 2, 0 }, function()
      vim.cmd("Daylog map alias")
    end)
  end)

  t.test("a balance reverts in one undo", function()
    reverts_in_one("balance", { "--- log ---", "08:00 a", "08:50 done" }, { 2, 0 }, function()
      vim.cmd("Daylog balance +1")
    end)
  end)

  t.test("an auto_summary refresh undojoins into the triggering edit", function()
    with_daylog_setup({ auto_summary = "off" }, function()
      local before = staged({ "--- log ---", "08:00 fix", "10:00 done" })
      -- A "manual" edit that stales the summary, sealed as its own block to force the u_sync the
      -- real autocmd-driven refresh crosses; apply_refresh(true) must undojoin back into it (without
      -- the join this reverts in 2 undos, so the assertion genuinely guards undojoin).
      vim.api.nvim_buf_set_lines(0, 2, 2, false, { "09:00 newtask" })
      vim.cmd("let &undolevels = &undolevels")
      require("daylog.buffer").apply_refresh(true)
      t.ok(not vim.deep_equal(before, current()), "the edit + refresh changed the buffer")
      t.eq(undos_to_revert(before), 1)
    end)
  end)
end
