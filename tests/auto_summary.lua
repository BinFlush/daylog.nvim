-- Tests for the auto-summary autocmd wiring per mode. Mirrors tests/autosave.lua: assert the right
-- events are registered (and that `off` clears them) rather than driving live timers.
return function(t)
  local auto_summary = require("daylog.auto_summary")

  local function registered(event)
    return #vim.api.nvim_get_autocmds({ group = "DaylogAutoSummary", event = event })
  end

  t.test("each mode wires its own autocmds and off clears them", function()
    auto_summary.setup("change")
    t.ok(registered({ "TextChanged", "TextChangedI" }) >= 1, "change wires TextChanged")

    auto_summary.setup("idle")
    t.ok(registered({ "CursorHold", "CursorHoldI", "InsertLeave" }) >= 1, "idle wires CursorHold")
    -- switching modes clears the previous mode's events (the group is cleared on setup)
    t.eq(registered({ "TextChanged", "TextChangedI" }), 0, "idle does not keep change's autocmd")

    auto_summary.setup("save")
    t.ok(registered("BufWritePre") >= 1, "save wires BufWritePre")

    auto_summary.setup("off")
    t.eq(#vim.api.nvim_get_autocmds({ group = "DaylogAutoSummary" }), 0, "off installs nothing")

    auto_summary.setup("change") -- restore the harness default so later tests see live wiring
  end)
end
