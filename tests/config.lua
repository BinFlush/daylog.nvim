return function(t)
  local config = require("daylog.config")

  t.test("config setup normalizes defaults and resets cleanly", function()
    config.setup({
      defaults = {
        tag = "ClientA",
        location = "office",
        quantize_minutes = 30,
        duration_format = "hm",
      },
      daybook = {
        root = "~/timereg",
        directory = "%Y/%V",
      },
    })

    t.eq(config.get(), {
      defaults = {
        tag = "ClientA",
        location = "office",
        quantize_minutes = 30,
        duration_format = "hm",
      },
      daybook = {
        root = "~/timereg",
        directory = "%Y/%V",
      },
      auto_summary = "change",
      active_indicator = true,
      auto_timezone = true,
    })

    config.setup()
    t.eq(config.get(), {
      defaults = {},
      auto_summary = "change",
      active_indicator = true,
      auto_timezone = true,
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
    t.ok(tostring(err):match("defaults.duration_format must be dec or hm") ~= nil)

    config.setup()
  end)

  t.test("config setup validates daybook settings", function()
    local ok, err = pcall(config.setup, {
      daybook = "bad",
    })
    t.ok(not ok)
    t.ok(tostring(err):match("setup daybook must be a table") ~= nil)

    ok, err = pcall(config.setup, {
      daybook = {
        root = "",
      },
    })
    t.ok(not ok)
    t.ok(tostring(err):match("daybook.root must be a non%-empty string") ~= nil)

    ok, err = pcall(config.setup, {
      daybook = {
        root = "~/timereg",
        directory = 15,
      },
    })
    t.ok(not ok)
    t.ok(tostring(err):match("daybook.directory must be a string") ~= nil)

    config.setup({
      daybook = {
        root = "~/timereg",
      },
    })
    t.eq(config.get(), {
      defaults = {},
      daybook = {
        root = "~/timereg",
        directory = "",
      },
      auto_summary = "change",
      active_indicator = true,
      auto_timezone = true,
    })

    config.setup()
  end)

  t.test("config setup normalizes and validates auto_summary", function()
    config.setup({ auto_summary = "idle" })
    t.eq(config.get().auto_summary, "idle")

    config.setup({ auto_summary = false })
    t.eq(config.get().auto_summary, "off")

    config.setup()
    t.eq(config.get().auto_summary, "change")

    local ok, err = pcall(config.setup, { auto_summary = "live" })
    t.ok(not ok)
    t.ok(tostring(err):match("auto_summary must be one of off, change, idle, save") ~= nil)

    config.setup()
  end)

  t.test("config setup normalizes and validates active_indicator", function()
    -- On by default, and an explicit toggle is preserved.
    t.eq(config.get().active_indicator, true)

    config.setup({ active_indicator = false })
    t.eq(config.get().active_indicator, false)

    config.setup({ active_indicator = true })
    t.eq(config.get().active_indicator, true)

    config.setup()
    t.eq(config.get().active_indicator, true)

    local ok, err = pcall(config.setup, { active_indicator = "yes" })
    t.ok(not ok)
    t.ok(tostring(err):match("active_indicator must be a boolean") ~= nil)

    config.setup()
  end)

  t.test("config setup normalizes and validates auto_timezone", function()
    -- On by default, and an explicit toggle is preserved.
    t.eq(config.get().auto_timezone, true)

    config.setup({ auto_timezone = false })
    t.eq(config.get().auto_timezone, false)

    config.setup({ auto_timezone = true })
    t.eq(config.get().auto_timezone, true)

    config.setup()
    t.eq(config.get().auto_timezone, true)

    local ok, err = pcall(config.setup, { auto_timezone = "yes" })
    t.ok(not ok)
    t.ok(tostring(err):match("auto_timezone must be a boolean") ~= nil)

    config.setup()
  end)

  t.test("config setup normalizes and validates defaults.utc", function()
    config.setup({ defaults = { utc = "+2" } })
    t.eq(config.get().defaults.utc, 120)

    config.setup({ defaults = { utc = "-3:30" } })
    t.eq(config.get().defaults.utc, -210)

    -- The "auto" sentinel is stored verbatim; the shell resolves it at file creation.
    config.setup({ defaults = { utc = "auto" } })
    t.eq(config.get().defaults.utc, "auto")

    -- A sign is required, and a non-string offset is rejected.
    local ok, err = pcall(config.setup, { defaults = { utc = "2" } })
    t.ok(not ok)
    t.ok(tostring(err):match("defaults%.utc") ~= nil)

    ok, err = pcall(config.setup, { defaults = { utc = 120 } })
    t.ok(not ok)
    t.ok(tostring(err):match("defaults%.utc") ~= nil)

    config.setup()
  end)

  t.test("config normalizes and validates picker", function()
    config.setup({ picker = { frecency_days = 14 } })
    local picker = config.get().picker
    t.eq(picker.frecency_days, 14)

    -- The retired duration-frecency knobs are no longer normalized -- silently ignored, not
    -- carried onto the config.
    config.setup({ picker = { half_life_days = 3, base = 10 } })
    picker = config.get().picker
    t.eq(picker.half_life_days, nil)
    t.eq(picker.base, nil)

    local function bad(p, pattern)
      local ok, err = pcall(config.setup, { picker = p })
      t.ok(not ok)
      t.ok(tostring(err):match(pattern) ~= nil, tostring(err))
    end

    bad("x", "setup picker must be a table")
    bad({ rank = 1 }, "picker%.rank must be a function")
    bad({ frecency_days = 0 }, "frecency_days must be a positive integer")

    config.setup()
  end)
end
