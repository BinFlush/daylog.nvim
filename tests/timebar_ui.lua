-- Shell test for the time bar's strip open (timebar_ui). Opening the reserved bottom split sets
-- `eventignore` to a list of window/buffer transition events, and that list must hold only events
-- the running Neovim knows: WinResized is 0.9+, and an unknown name makes the `eventignore` set
-- throw E474, which crashed the bar render on the 0.8 floor. Enabling the bar and driving one
-- highlight pass exercises that set on every CI Neovim.
return function(t)
  local daylog = require("daylog")
  local config = require("daylog.config")
  local timebar_ui = require("daylog.timebar_ui")

  t.test("bar_virt_lines mirrors a mapped log into two bars (four rows)", function()
    -- A mapped log renders raw labels / raw bar / resolved bar / resolved labels, so the hover can
    -- report the raw item on the top bar and the mapped label on the bottom.
    local mapped = {
      raw_labels = { { col = 1, text = "fix", color_index = 1, swatch = 2 } },
      raw_segments = { { width = 20, color_index = 1, start = 0, stop = 1200 } },
      segments = { { width = 20, color_index = 2, start = 0, stop = 1200 } },
      labels = { { col = 1, text = "Feature", color_index = 2, swatch = 2 } },
    }
    local rows, bars = timebar_ui.bar_virt_lines(mapped, 20)
    t.eq(#rows, 4)
    t.eq(#bars, 2)
    t.eq(bars[1].row, 2) -- top bar = raw items
    t.eq(bars[2].row, 3) -- bottom bar = resolved labels

    local unmapped = {
      segments = { { width = 20, color_index = 1, start = 0, stop = 1200 } },
      labels = { { col = 1, text = "work", color_index = 1, swatch = 2 } },
    }
    local urows, ubars = timebar_ui.bar_virt_lines(unmapped, 20)
    t.eq(#urows, 2)
    t.eq(#ubars, 1)
    t.eq(ubars[1].row, 2)
  end)

  t.test("label_row draws each placement's swatch at its own width", function()
    -- A label on a segment thinner than the full swatch carries `swatch = 1`; the row must render that
    -- one cell of colour (and budget the item one cell narrower), not a hardcoded two.
    local rows = timebar_ui.bar_virt_lines({
      segments = { { width = 20, color_index = 1, start = 0, stop = 1200 } },
      labels = {
        { col = 1, text = "a", color_index = 1, swatch = 1 },
        { col = 8, text = "b", color_index = 2, swatch = 2 },
      },
    }, 20)
    t.eq(rows[1][1], { " ", "DaylogBar1" }) -- the narrowed swatch: one cell
    t.eq(rows[1][2], { " a  ", "DaylogBarLabel" })
    t.eq(rows[1][3], { "  ", "DaylogBarLabel" }) -- pad from col 5 (1 + 1 + 3) to col 8
    t.eq(rows[1][4], { "  ", "DaylogBar2" }) -- the full swatch: two cells
  end)

  t.test("build_bar_row draws the now-marker glyph only when now_col is set", function()
    local segments = { { width = 10, color_index = 1, start = 0, stop = 600 } }
    local function has_marker(bar)
      for _, chunk in ipairs(bar) do
        if chunk[1] == "▏" then
          return true
        end
      end
      return false
    end
    t.ok(has_marker(timebar_ui.build_bar_row(segments, 5)), "now-marker present at now_col")
    t.ok(not has_marker(timebar_ui.build_bar_row(segments, nil)), "no marker without now_col")
  end)

  t.test("time bar: opening the strip never feeds eventignore an unknown event", function()
    config.setup({ time_bar = true })
    vim.cmd("only")
    t.reset({
      "--- log ---",
      "08:00 stand",
      "09:00 work",
      "10:00 done",
    })
    local buf = vim.api.nvim_get_current_buf()
    t.ok(timebar_ui.enabled(), "the bar is enabled for the pass")

    local saved = vim.o.eventignore
    -- On the 0.8 floor an unguarded WinResized in the strip's eventignore list throws E474 here.
    local ok, err = pcall(daylog.highlight_buffer, buf)
    t.ok(ok, "the bar render did not error: " .. tostring(err))
    -- The strip opened in its own split, so the eventignore path actually ran, and the transient
    -- eventignore was restored afterwards.
    t.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
    t.eq(vim.o.eventignore, saved)

    vim.cmd("only")
    config.setup()
  end)
end
