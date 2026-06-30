return function(t)
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")
  local timebar = require("daylog.timebar")

  local function entries(lines)
    return analyze.get_active_log(analyze.analyze(document.parse(lines))).entries
  end

  t.test("time_at_column maps bar columns back to clock minutes", function()
    -- 08:00 (480) -> 12:00 (720) over 80 cells: 3 minutes per cell, at each cell's left edge.
    t.eq(timebar.time_at_column(480, 720, 80, 1), 480) -- the first cell -> the start
    t.eq(timebar.time_at_column(480, 720, 80, 41), 600) -- 40 cells in -> +120m -> 10:00
    t.eq(timebar.time_at_column(480, 720, 80, 100), 720) -- past the end clamps to the last entry
    t.eq(timebar.time_at_column(480, 720, 0, 5), 480) -- a zero width never divides
  end)

  t.test("segment_label_at finds the activity under a column", function()
    local segs = { { width = 40, label = "a" }, { width = 40, label = "b" } }
    t.eq(timebar.segment_label_at(segs, 1), "a")
    t.eq(timebar.segment_label_at(segs, 40), "a") -- the boundary belongs to the left segment
    t.eq(timebar.segment_label_at(segs, 41), "b")
    t.eq(timebar.segment_label_at(segs, 80), "b")
    t.eq(timebar.segment_label_at(segs, 81), nil) -- past the last segment
  end)

  t.test("fit_legend leaves labels whole when they all fit", function()
    t.eq(
      timebar.fit_legend({
        { label = "plan", color_index = 1 },
        { label = "review", color_index = 2 },
      }, 100),
      {
        { text = "plan", color_index = 1 },
        { text = "review", color_index = 2 },
      }
    )
  end)

  t.test("fit_legend shaves the longest label first, keeping short ones whole", function()
    -- "ab" stays full; "refactoring" is the longest, so it carries the abbreviation + ellipsis.
    t.eq(
      timebar.fit_legend({
        { label = "ab", color_index = 1 },
        { label = "refactoring", color_index = 2 },
      }, 18),
      {
        { text = "ab", color_index = 1 },
        { text = "refac…", color_index = 2 },
      }
    )
  end)

  t.test("fit_legend keeps a prefix label whole and marks the longer one", function()
    -- "PR" is a prefix of "PRrev": it must stay full (a 2-char truncation of "PRrev" would collide),
    -- so the longer one carries the ellipsis.
    t.eq(
      timebar.fit_legend({
        { label = "PR", color_index = 1 },
        { label = "PRrev", color_index = 2 },
      }, 16),
      {
        { text = "PR", color_index = 1 },
        { text = "PRr…", color_index = 2 },
      }
    )
  end)

  t.test("fit_legend floors abbreviation at 3 chars, evicting rather than going shorter", function()
    -- "m" vs "r" would distinguish in one char, but the floor keeps >= 3...
    t.eq(
      timebar.fit_legend({
        { label = "meeting", color_index = 1 },
        { label = "review", color_index = 2 },
      }, 18),
      {
        { text = "mee…", color_index = 1 },
        { text = "rev…", color_index = 2 },
      }
    )
    -- ...and one cell tighter, the second is dropped whole rather than shrunk below the floor.
    t.eq(
      timebar.fit_legend({
        { label = "meeting", color_index = 1 },
        { label = "review", color_index = 2 },
      }, 17),
      {
        { text = "meeting", color_index = 1 },
      }
    )
  end)

  t.test("fit_legend truncates on UTF-8 character boundaries", function()
    -- both share "café " and differ at the 6th char, so each shows six characters (the accented "é"
    -- kept whole, never split mid-byte) plus the ellipsis.
    t.eq(
      timebar.fit_legend({
        { label = "café latte", color_index = 1 },
        { label = "café mocha", color_index = 2 },
      }, 24),
      {
        { text = "café l…", color_index = 1 },
        { text = "café m…", color_index = 2 },
      }
    )
  end)

  t.test("layout fills the width with segments proportional to real duration", function()
    -- a: 08:00-10:00 (120) + 10:30-12:00 (90) = 210; b: 10:00-10:30 (30). total 240.
    local layout = timebar.layout(
      entries({
        "--- log ---",
        "08:00 a",
        "10:00 b",
        "10:30 a",
        "12:00 done",
      }),
      40
    )
    t.eq(#layout.segments, 3) -- three intervals (a, b, a) in chronological order
    local total = 0
    for _, seg in ipairs(layout.segments) do
      total = total + seg.width
    end
    t.eq(total, 40) -- fills the width exactly
    t.eq(layout.segments[1].label, "a")
    t.eq(layout.segments[1].color_index, 1) -- a appears first -> colour 1
    t.eq(layout.segments[2].label, "b")
    t.eq(layout.segments[2].color_index, 2)
  end)

  t.test("colours are assigned by first appearance, not duration", function()
    local layout = timebar.layout(
      entries({
        "--- log ---",
        "08:00 small",
        "08:30 big",
        "11:00 done",
      }),
      30
    )
    -- small appears first (even though big is longer), so it keeps colour 1 -- the order is stable.
    t.eq(layout.legend[1].label, "small")
    t.eq(layout.legend[1].color_index, 1)
    t.eq(layout.legend[2].label, "big")
    t.eq(layout.legend[2].color_index, 2)
  end)

  t.test("an aliased entry colours by its resolved label", function()
    local layout = timebar.layout(
      entries({
        "--- log ---",
        "08:00 work => Project",
        "09:00 Project",
        "10:00 done",
      }),
      20
    )
    t.eq(#layout.legend, 1) -- both intervals resolve to one activity
    t.eq(layout.legend[1].label, "Project")
  end)

  t.test("nothing to show yields nil", function()
    local ok = entries({ "--- log ---", "08:00 only", "09:00 done" })
    t.eq(timebar.layout(ok, 0), nil) -- zero width
    t.eq(timebar.layout({}, 40), nil) -- no entries
    t.eq(timebar.layout(entries({ "--- log ---", "08:00 alone" }), 40), nil) -- one entry, no interval
  end)

  t.test("an out-of-order (invalid) log yields nil", function()
    local invalid = entries({ "--- log ---", "10:00 a", "08:00 b", "12:00 done" })
    t.eq(timebar.layout(invalid, 40), nil)
  end)

  t.test("a now-marker column appears when the final entry is in the future", function()
    -- first 08:00 (480), last 12:00 (720); now 10:00 (600) is halfway -> floor(120/240 * 40) + 1.
    local L = timebar.layout(entries({ "--- log ---", "08:00 a", "12:00 done" }), 40, 600)
    t.eq(L.now_col, 21)
  end)

  t.test("no now-marker once now is at or past the final entry", function()
    local log = { "--- log ---", "08:00 a", "12:00 done" }
    t.eq(timebar.layout(entries(log), 40, 720).now_col, nil) -- now == last
    t.eq(timebar.layout(entries(log), 40, 800).now_col, nil) -- now > last
  end)

  t.test("no now-marker without a current time", function()
    t.eq(timebar.layout(entries({ "--- log ---", "08:00 a", "12:00 done" }), 40).now_col, nil)
  end)

  t.test(":Daylog bar opens and closes a reserved bottom strip", function()
    local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
    helpers.with_daylog_setup({}, function()
      t.reset({ "--- log ---", "08:00 a", "10:00 b", "12:00 done" })
      vim.bo.filetype = "daylog"
      local dwin = vim.api.nvim_get_current_win()

      -- The bar lives in its own split below the log window; find that other window.
      local function strip_win()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if w ~= dwin then
            return w
          end
        end
        return nil
      end

      t.ok(strip_win() == nil, "no strip by default (time_bar is off)")

      require("daylog").bar()
      local sw = strip_win()
      t.ok(sw ~= nil, "a strip window opens after toggling on")
      t.eq(#vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sw), 0, -1, false), 2) -- legend + bar

      require("daylog").bar()
      t.ok(strip_win() == nil, "the strip is gone after toggling off")
    end)
  end)

  t.test(":q on the log window tears down the strip in one press", function()
    local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
    helpers.with_daylog_setup({}, function()
      -- a second window so :quit closes the log window without exiting the test runner
      vim.cmd("enew")
      vim.cmd("split")
      t.reset({ "--- log ---", "08:00 a", "10:00 b", "12:00 done" })
      vim.bo.filetype = "daylog"
      local dwin = vim.api.nvim_get_current_win()

      require("daylog").bar()
      t.eq(#vim.api.nvim_list_wins(), 3) -- other window + log window + its strip

      vim.api.nvim_set_current_win(dwin)
      vim.cmd("quit") -- QuitPre drops the strip first, so one :q closes the log window too
      t.eq(#vim.api.nvim_list_wins(), 1)
    end)
  end)

  t.test("the bar strip closes when its window stops showing a daylog", function()
    local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
    local timebar_ui = require("daylog.timebar_ui")
    helpers.with_daylog_setup({}, function()
      t.reset({ "--- log ---", "08:00 a", "10:00 done" })
      vim.bo.filetype = "daylog"
      local dwin = vim.api.nvim_get_current_win()

      -- Make sure the bar is on for this test, restoring the global toggle afterwards.
      local turned_on = not timebar_ui.enabled()
      if turned_on then
        require("daylog").bar()
      end
      require("daylog").refresh_indicators(0)

      local function strip()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if w ~= dwin then
            return w
          end
        end
      end
      t.ok(strip() ~= nil, "the strip is open with the bar on")

      vim.cmd("enew") -- the window now shows a non-daylog buffer -> BufWinEnter drops the strip
      t.ok(strip() == nil, "the strip closed when the window left the daylog buffer")

      if turned_on then
        timebar_ui.toggle()
      end
    end)
  end)
end
