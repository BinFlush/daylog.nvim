return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_mocked_date = helpers.with_mocked_date
  local with_captured_notify = helpers.with_captured_notify
  local registry = require("worklog.sources.registry")
  local sync = require("worklog.sources.sync")

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
      "--- worklog ---",
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
      "--- worklog ---",
      "08:00 first",
      "09:00 done",
      "11:30 1 Item one",
    })
  end)

  t.test("WorklogInsert <source> falls back to a bare timestamp on cancel", function()
    register_fake()
    t.reset({
      "--- worklog ---",
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
      "--- worklog ---",
      "08:00 first",
      "09:00 done",
      "11:30 ",
    })
  end)

  t.test("WorklogInsert with an unknown source warns and inserts nothing", function()
    t.reset({
      "--- worklog ---",
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
      "--- worklog ---",
      "08:00 first",
      "09:00 done",
    })
  end)

  t.test("WorklogInsert with no argument keeps the plain bare-timestamp behavior", function()
    t.reset({
      "--- worklog ---",
      "08:00 first",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    with_mocked_date("11:30", function()
      vim.cmd("WorklogInsert")
    end)

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 first",
      "09:00 done",
      "11:30 ",
    })
  end)
end
