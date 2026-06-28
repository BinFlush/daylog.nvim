return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_mocked_date = helpers.with_mocked_date
  local with_captured_notify = helpers.with_captured_notify
  local registry = require("daylog.sources.registry")
  local sync = require("daylog.sources.sync")

  helpers.setup_daylog()

  local FAKE_ITEMS = {
    { id = "1", title = "Item one", type = "Bug", state = "Active" },
    { id = "2", title = "Item two", type = "Task", state = "New" },
  }

  local function register_fake()
    registry.register("FAKE", {
      fetch = function(cb)
        cb(FAKE_ITEMS, nil)
      end,
      format_item = function(item)
        return item.id .. " " .. item.title
      end,
      to_entry_text = function(item)
        return item.id .. " " .. item.title
      end,
    })
  end

  -- Drive the async picker synchronously: ensure_fresh hands over the items and
  -- vim.ui.select immediately invokes its callback (with the first item, or nil to
  -- model a cancel).
  local function with_stubbed_picker(pick, fn)
    local old_ensure = sync.ensure_fresh
    local old_select = vim.ui.select

    sync.ensure_fresh = function(_name, _ttl, on_ready)
      on_ready(FAKE_ITEMS)
    end
    vim.ui.select = function(items, _, on_choice)
      on_choice(pick and items[1] or nil)
    end

    local ok, err = xpcall(fn, debug.traceback)

    sync.ensure_fresh = old_ensure
    vim.ui.select = old_select

    if not ok then
      error(err, 0)
    end
  end

  -- Stub the unified picker's synchronous reads + vim.ui.select. `pick` selects the top pool
  -- row; otherwise it cancels. Shared by :Daylog! insert / :Daylog rename / :Daylog map.
  local function with_stubbed_unified(pick, fn)
    local old_read = sync.read_items
    local old_refresh = sync.refresh_if_stale
    local old_select = vim.ui.select

    sync.read_items = function(name)
      return name == "FAKE" and FAKE_ITEMS or {}
    end
    sync.refresh_if_stale = function() end
    vim.ui.select = function(items, _, on_choice)
      on_choice(pick and items[1] or nil)
    end

    local ok, err = xpcall(fn, debug.traceback)

    sync.read_items = old_read
    sync.refresh_if_stale = old_refresh
    vim.ui.select = old_select

    if not ok then
      error(err, 0)
    end
  end

  t.test("Daylog insert <source> inserts the picked item at the current time", function()
    register_fake()
    t.reset({
      "--- log ---",
      "08:00 first",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    with_stubbed_picker(true, function()
      with_mocked_date("11:30", function()
        vim.cmd("Daylog insert FAKE")
      end)
    end)

    t.eq(t.get_lines(), {
      "--- log ---",
      "08:00 first",
      "09:00 done",
      "11:30 1 Item one",
    })
  end)

  t.test("Daylog insert <source> falls back to a bare timestamp on cancel", function()
    register_fake()
    t.reset({
      "--- log ---",
      "08:00 first",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    with_stubbed_picker(false, function()
      with_mocked_date("11:30", function()
        vim.cmd("Daylog insert FAKE")
      end)
    end)

    t.eq(t.get_lines(), {
      "--- log ---",
      "08:00 first",
      "09:00 done",
      "11:30 ",
    })
  end)

  t.test("Daylog insert <source> errors without opening the picker outside a log", function()
    register_fake()
    t.reset({
      "--- log #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h first",
    })
    t.set_cursor(5, 0) -- on the summary header, outside the log block

    -- Detect whether the (stubbed) picker is ever reached. The fix must bail
    -- before this, just like a bare :Daylog insert outside a log.
    local picker_opened = false
    local old_ensure = sync.ensure_fresh
    sync.ensure_fresh = function()
      picker_opened = true
    end

    local captured
    local ok, err = xpcall(function()
      with_captured_notify(function(messages)
        vim.cmd("Daylog insert FAKE")
        captured = messages
      end)
    end, debug.traceback)

    sync.ensure_fresh = old_ensure
    if not ok then
      error(err, 0)
    end

    t.ok(not picker_opened, "picker must not open when the cursor is outside a log")
    t.eq(captured, {
      {
        message = "daylog: current line is not inside a log block",
        level = vim.log.levels.WARN,
      },
    })
    t.eq(t.get_lines(), {
      "--- log #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h first",
    })
  end)

  t.test("Daylog insert with an unknown source warns and inserts nothing", function()
    t.reset({
      "--- log ---",
      "08:00 first",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    with_captured_notify(function(messages)
      vim.cmd("Daylog insert NOPE")
      t.eq(messages, {
        { message = "daylog: unknown source 'NOPE'", level = vim.log.levels.WARN },
      })
    end)

    t.eq(t.get_lines(), {
      "--- log ---",
      "08:00 first",
      "09:00 done",
    })
  end)

  t.test("Daylog insert with no argument keeps the plain bare-timestamp behavior", function()
    t.reset({
      "--- log ---",
      "08:00 first",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    with_mocked_date("11:30", function()
      vim.cmd("Daylog insert")
    end)

    t.eq(t.get_lines(), {
      "--- log ---",
      "08:00 first",
      "09:00 done",
      "11:30 ",
    })
  end)

  -- Put the cursor on the active log's "review" main summary row (its line ends
  -- with ") review"; the entry "08:00 review" does not), after a refresh.
  local function on_review_summary_row()
    t.reset({ "--- log ---", "08:00 review", "09:00 done" })
    vim.cmd("Daylog refresh")
    for i, line in ipairs(t.get_lines()) do
      if line:find("%) review$") then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
    error("review summary row not found")
  end

  t.test("Daylog rename refuses an activity row, with or without a source arg", function()
    registry.clear()
    register_fake()

    -- Relabeling an activity for the report is :Daylog map's job (it can map onto a source
    -- item); rename refuses the activity row -- a bare name and a source arg alike.
    on_review_summary_row()
    with_captured_notify(function(messages)
      vim.cmd("Daylog rename ship the release")
      vim.cmd("Daylog rename FAKE")
      local refused = 0
      for _, message in ipairs(messages) do
        if message.message:find(":Daylog map to relabel") then
          refused = refused + 1
        end
      end
      t.eq(refused, 2)
    end)

    t.eq(t.get_lines()[2], "08:00 review")
  end)

  t.test(
    "Daylog rename refuses a source on a non-activity row, then opens the merge picker",
    function()
      registry.clear()
      register_fake()
      t.reset({ "--- log ---", "08:00 a #ClientA", "09:00 b #other", "10:00 done" })
      vim.cmd("Daylog refresh")
      for i, line in ipairs(t.get_lines()) do
        if line:find("%) #ClientA$") then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
        end
      end

      -- A source can only replace an activity; on a tag row it is reported, then the normal
      -- candidate (merge) picker opens -- here cancelled, so nothing is mutated.
      local old_select = vim.ui.select
      vim.ui.select = function(_, _, on_choice)
        on_choice(nil)
      end

      with_captured_notify(function(messages)
        local ok, err = xpcall(function()
          vim.cmd("Daylog rename FAKE")
        end, debug.traceback)
        vim.ui.select = old_select
        if not ok then
          error(err, 0)
        end
        local refused = false
        for _, message in ipairs(messages) do
          if message.message:find("a source can only replace an activity") then
            refused = true
          end
        end
        t.ok(refused, "naming a source on a tag row should be refused")
      end)

      t.eq(t.get_lines()[2], "08:00 a #ClientA")
    end
  )

  t.test("Daylog map maps the cursor entry onto a pool item", function()
    registry.clear()
    register_fake()
    t.reset({ "--- log ---", "08:00 review", "09:00 done" })
    t.set_cursor(2, 0)

    with_stubbed_unified(true, function()
      vim.cmd("Daylog map")
    end)

    t.eq(t.get_lines()[2], "08:00 review => 1 Item one")
  end)

  t.test("Daylog map <source> maps the cursor entry onto a scoped source item", function()
    registry.clear()
    register_fake()
    t.reset({ "--- log ---", "08:00 review", "09:00 done" })
    t.set_cursor(2, 0)

    -- A named source scopes to that one tracker's items (live-search-capable), like Insert.
    with_stubbed_picker(true, function()
      vim.cmd("Daylog map FAKE")
    end)

    t.eq(t.get_lines()[2], "08:00 review => 1 Item one")
  end)

  t.test("Daylog! insert pools sources and inserts the picked row", function()
    registry.clear()
    register_fake()
    t.reset({ "--- log ---", "08:00 first", "09:00 done" })
    t.set_cursor(2, 0)

    with_stubbed_unified(true, function()
      with_mocked_date("11:30", function()
        vim.cmd("Daylog! insert")
      end)
    end)

    t.eq(t.get_lines(), {
      "--- log ---",
      "08:00 first",
      "09:00 done",
      "11:30 1 Item one",
    })
  end)

  t.test("Daylog! insert falls back to a bare timestamp on cancel", function()
    registry.clear()
    register_fake()
    t.reset({ "--- log ---", "08:00 first", "09:00 done" })
    t.set_cursor(2, 0)

    with_stubbed_unified(false, function()
      with_mocked_date("11:30", function()
        vim.cmd("Daylog! insert")
      end)
    end)

    t.eq(t.get_lines()[4], "11:30 ")
  end)
end
