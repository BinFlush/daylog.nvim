return function(t)
  local config = require("worklog.config")

  t.test("config setup normalizes defaults and resets cleanly", function()
    config.setup({
      defaults = {
        tag = "ClientA",
        location = "office",
        quantize_minutes = 30,
        duration_format = "hhmm",
      },
      journal = {
        root = "~/timereg",
        directory = "%Y/%V",
      },
    })

    t.eq(config.get(), {
      defaults = {
        tag = "ClientA",
        location = "office",
        quantize_minutes = 30,
        duration_format = "hhmm",
      },
      journal = {
        root = "~/timereg",
        directory = "%Y/%V",
      },
      auto_summary = "off",
    })

    config.setup()
    t.eq(config.get(), {
      defaults = {},
      auto_summary = "off",
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

    ok, err = pcall(config.setup, {
      defaults = {
        duration_format = "clock",
      },
    })
    t.ok(not ok)
    t.ok(tostring(err):match("defaults.duration_format must be decimal or hhmm") ~= nil)

    config.setup()
  end)

  t.test("config setup validates journal settings", function()
    local ok, err = pcall(config.setup, {
      journal = "bad",
    })
    t.ok(not ok)
    t.ok(tostring(err):match("setup journal must be a table") ~= nil)

    ok, err = pcall(config.setup, {
      journal = {
        root = "",
      },
    })
    t.ok(not ok)
    t.ok(tostring(err):match("journal.root must be a non%-empty string") ~= nil)

    ok, err = pcall(config.setup, {
      journal = {
        root = "~/timereg",
        directory = 15,
      },
    })
    t.ok(not ok)
    t.ok(tostring(err):match("journal.directory must be a string") ~= nil)

    config.setup({
      journal = {
        root = "~/timereg",
      },
    })
    t.eq(config.get(), {
      defaults = {},
      journal = {
        root = "~/timereg",
        directory = "",
      },
      auto_summary = "off",
    })

    config.setup()
  end)

  t.test("config setup normalizes and validates auto_summary", function()
    config.setup({ auto_summary = "idle" })
    t.eq(config.get().auto_summary, "idle")

    config.setup({ auto_summary = false })
    t.eq(config.get().auto_summary, "off")

    config.setup()
    t.eq(config.get().auto_summary, "off")

    local ok, err = pcall(config.setup, { auto_summary = "live" })
    t.ok(not ok)
    t.ok(tostring(err):match("auto_summary must be one of off, change, idle, save") ~= nil)

    config.setup()
  end)
end
