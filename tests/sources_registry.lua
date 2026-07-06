return function(t)
  local registry = require("daylog.sources.registry")

  local function valid_source()
    return {
      fetch = function(cb)
        cb({})
      end,
      format_item = function(item)
        return item.id
      end,
      to_entry_text = function(item)
        return item.id
      end,
    }
  end

  t.test("register accepts a valid source", function()
    local ok = pcall(registry.register, "REG_OK", valid_source())
    t.ok(ok)
    t.ok(registry.get("REG_OK") ~= nil)
    registry.clear()
  end)

  t.test("register rejects a non-table source", function()
    local ok, err = pcall(registry.register, "REG_BAD", "nope")
    t.ok(not ok)
    t.ok(tostring(err):match("must be a table") ~= nil, tostring(err))
  end)

  t.test("register rejects a source missing a contract function", function()
    local source = valid_source()
    source.to_entry_text = nil
    local ok, err = pcall(registry.register, "REG_MISSING", source)
    t.ok(not ok)
    t.ok(tostring(err):match("is missing to_entry_text") ~= nil, tostring(err))
  end)

  t.test("register raises the clean user-facing message, without a file:line prefix", function()
    local ok, err = pcall(registry.register, "REG_LEVEL", "nope")
    t.ok(not ok)
    t.eq(err, "daylog: source 'REG_LEVEL' must be a table")
  end)

  t.test("register rejects a non-function search", function()
    local source = valid_source()
    source.search = "nope"
    local ok, err = pcall(registry.register, "REG_SEARCH", source)
    t.ok(not ok)
    t.ok(tostring(err):match("search must be a function") ~= nil, tostring(err))
  end)

  registry.clear()
end
