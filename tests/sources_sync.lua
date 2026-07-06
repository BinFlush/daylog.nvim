return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_captured_notify = helpers.with_captured_notify
  local registry = require("daylog.sources.registry")
  local sync = require("daylog.sources.sync")

  -- Stub the cache write so these tests never touch the real stdpath("cache") tree.
  local function with_stubbed_write_cache(fn)
    local old_write = sync.write_cache
    sync.write_cache = function()
      return true
    end

    local ok, err = xpcall(fn, debug.traceback)
    sync.write_cache = old_write

    if not ok then
      error(err, 0)
    end
  end

  local function register_source(name, fetch)
    registry.register(name, {
      fetch = fetch,
      format_item = function(item)
        return item.id
      end,
      to_entry_text = function(item)
        return item.id
      end,
    })
  end

  t.test("sync calls back exactly once when the caller's callback throws", function()
    -- A synchronous fetch means the callback body runs inside sync's pcall; an error
    -- raised by the caller's cb must not trigger the error branch's second cb(false).
    register_source("SYNC_THROW", function(cb)
      cb({ { id = "1", title = "Item one" } }, nil)
    end)

    local calls = 0
    with_stubbed_write_cache(function()
      with_captured_notify(function()
        sync.sync("SYNC_THROW", { silent = true }, function()
          calls = calls + 1
          error("caller callback failure")
        end)
      end)
    end)

    t.eq(calls, 1)
    t.eq(sync.is_in_flight("SYNC_THROW"), false)
    registry.clear()
  end)

  t.test("a sync while one is already in flight warns instead of failing silently", function()
    local pending
    register_source("SYNC_SLOW", function(cb)
      pending = cb
    end)

    with_stubbed_write_cache(function()
      with_captured_notify(function(messages)
        sync.sync("SYNC_SLOW", { silent = true })
        t.eq(sync.is_in_flight("SYNC_SLOW"), true)

        local second_result
        sync.sync("SYNC_SLOW", { silent = true }, function(ok)
          second_result = ok
        end)

        t.eq(second_result, false)
        local warned = false
        for _, message in ipairs(messages) do
          if message.message == "daylog: sync already running for SYNC_SLOW" then
            warned = true
            t.eq(message.level, vim.log.levels.WARN)
          end
        end
        t.ok(warned, "expected an already-running warning")

        -- Complete the first sync so in_flight does not leak into other tests.
        pending({}, nil)
      end)
    end)

    t.eq(sync.is_in_flight("SYNC_SLOW"), false)
    registry.clear()
  end)
end
