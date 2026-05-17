return function(t)
  local config = require("worklog.config")

  t.test("config setup normalizes defaults and resets cleanly", function()
    config.setup({
      defaults = {
        tag = "ClientA",
        location = "office",
        quantize_minutes = 30,
      },
    })

    t.eq(config.get(), {
      defaults = {
        tag = "ClientA",
        location = "office",
        quantize_minutes = 30,
      },
    })

    config.setup()
    t.eq(config.get(), {
      defaults = {},
    })
  end)

  t.test("config setup validates defaults", function()
    local ok, err = pcall(config.setup, {
      defaults = "bad",
    })
    t.ok(not ok)
    t.ok(tostring(err):match("setup defaults must be a table") ~= nil)

    ok, err = pcall(config.setup, {
      defaults = {
        tag = "Client A",
      },
    })
    t.ok(not ok)
    t.ok(
      tostring(err):match("defaults.tag must use only letters, digits, underscores, or hyphens")
        ~= nil
    )

    ok, err = pcall(config.setup, {
      defaults = {
        location = "home office",
      },
    })
    t.ok(not ok)
    t.ok(
      tostring(err):match(
        "defaults.location must use only letters, digits, underscores, or hyphens"
      ) ~= nil
    )

    ok, err = pcall(config.setup, {
      defaults = {
        quantize_minutes = 1.5,
      },
    })
    t.ok(not ok)
    t.ok(tostring(err):match("defaults.quantize_minutes must be a positive integer") ~= nil)

    config.setup()
  end)
end
