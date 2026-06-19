return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_mocked_date = helpers.with_mocked_date
  local with_captured_notify = helpers.with_captured_notify
  local registry = require("blotter.sources.registry")
  local sync = require("blotter.sources.sync")

  helpers.setup_worklog()

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

  t.test("WorklogInsert <source> inserts the picked item at the current time", function()
    register_fake()
    t.reset({
      "--- blots ---",
      "08:00 first",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    with_stubbed_picker(true, function()
      with_mocked_date("11:30", function()
        vim.cmd("WorklogInsert FAKE")
      end)
    end)

    t.eq(t.get_lines(), {
      "--- blots ---",
      "08:00 first",
      "09:00 done",
      "11:30 1 Item one",
    })
  end)

  t.test("WorklogInsert <source> falls back to a bare timestamp on cancel", function()
    register_fake()
    t.reset({
      "--- blots ---",
      "08:00 first",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    with_stubbed_picker(false, function()
      with_mocked_date("11:30", function()
        vim.cmd("WorklogInsert FAKE")
      end)
    end)

    t.eq(t.get_lines(), {
      "--- blots ---",
      "08:00 first",
      "09:00 done",
      "11:30 ",
    })
  end)

  t.test("WorklogInsert <source> errors without opening the picker outside a worklog", function()
    register_fake()
    t.reset({
      "--- blots #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h first",
    })
    t.set_cursor(5, 0) -- on the summary header, outside the worklog block

    -- Detect whether the (stubbed) picker is ever reached. The fix must bail
    -- before this, just like a bare :WorklogInsert outside a worklog.
    local picker_opened = false
    local old_ensure = sync.ensure_fresh
    sync.ensure_fresh = function()
      picker_opened = true
    end

    local captured
    local ok, err = xpcall(function()
      with_captured_notify(function(messages)
        vim.cmd("WorklogInsert FAKE")
        captured = messages
      end)
    end, debug.traceback)

    sync.ensure_fresh = old_ensure
    if not ok then
      error(err, 0)
    end

    t.ok(not picker_opened, "picker must not open when the cursor is outside a worklog")
    t.eq(captured, {
      {
        message = "worklog: current line is not inside a worklog block",
        level = vim.log.levels.WARN,
      },
    })
    t.eq(t.get_lines(), {
      "--- blots #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h first",
    })
  end)

  t.test("WorklogInsert with an unknown source warns and inserts nothing", function()
    t.reset({
      "--- blots ---",
      "08:00 first",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    with_captured_notify(function(messages)
      vim.cmd("WorklogInsert NOPE")
      t.eq(messages, {
        { message = "worklog: unknown source 'NOPE'", level = vim.log.levels.WARN },
      })
    end)

    t.eq(t.get_lines(), {
      "--- blots ---",
      "08:00 first",
      "09:00 done",
    })
  end)

  t.test("WorklogInsert with no argument keeps the plain bare-timestamp behavior", function()
    t.reset({
      "--- blots ---",
      "08:00 first",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    with_mocked_date("11:30", function()
      vim.cmd("WorklogInsert")
    end)

    t.eq(t.get_lines(), {
      "--- blots ---",
      "08:00 first",
      "09:00 done",
      "11:30 ",
    })
  end)

  -- Put the cursor on the active worklog's "review" main summary row (its line ends
  -- with ") review"; the entry "08:00 review" does not), after a refresh.
  local function on_review_summary_row()
    t.reset({ "--- blots ---", "08:00 review", "09:00 done" })
    vim.cmd("WorklogRefresh")
    for i, line in ipairs(t.get_lines()) do
      if line:find("%) review$") then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
    error("review summary row not found")
  end

  t.test("WorklogRename replaces an activity with a source item (single source)", function()
    registry.clear()
    register_fake()
    on_review_summary_row()

    -- One activity, so it has no merge candidates; the first picker choice is the
    -- source item, which the stub selects.
    with_stubbed_picker(true, function()
      vim.cmd("WorklogRename")
    end)

    t.eq(t.get_lines()[2], "08:00 1 Item one")
    local renamed = false
    for _, line in ipairs(t.get_lines()) do
      if line:find("%) 1 Item one$") then
        renamed = true
      end
    end
    t.ok(renamed, "the summary row should be rebuilt to the work item")
  end)

  t.test("WorklogRename arg names a source, otherwise renames directly", function()
    registry.clear()
    register_fake()

    -- A non-source argument renames the activity to that literal text.
    on_review_summary_row()
    vim.cmd("WorklogRename ship the release")
    t.eq(t.get_lines()[2], "08:00 ship the release")

    -- A source-name argument opens that source's picker instead.
    on_review_summary_row()
    with_stubbed_picker(true, function()
      vim.cmd("WorklogRename FAKE")
    end)
    t.eq(t.get_lines()[2], "08:00 1 Item one")
  end)

  t.test("WorklogRename refuses a source on a non-activity row", function()
    registry.clear()
    register_fake()
    -- Two tags so the #ClientA tag-total row has a merge candidate: after the source
    -- is refused, the normal merge picker opens (and the stub cancels it) rather than
    -- falling through to a blocking input prompt.
    t.reset({ "--- blots ---", "08:00 a #ClientA", "09:00 b #other", "10:00 done" })
    vim.cmd("WorklogRefresh")
    for i, line in ipairs(t.get_lines()) do
      if line:find("%) #ClientA$") then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
      end
    end

    with_captured_notify(function(messages)
      with_stubbed_picker(false, function() -- cancel, so nothing is mutated
        vim.cmd("WorklogRename FAKE")
      end)
      local refused = false
      for _, message in ipairs(messages) do
        if message.message:find("a source can only replace an activity") then
          refused = true
        end
      end
      t.ok(refused, "naming a source on a tag row should be refused")
    end)
  end)
end
