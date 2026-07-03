return function(t)
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")
  local timebar = require("daylog.timebar")

  local function entries(lines)
    return analyze.get_active_log(analyze.analyze(document.parse(lines))).entries
  end

  t.test("time_at_column maps bar columns back to clock minutes", function()
    -- one segment 08:00 (480) -> 12:00 (720) over 80 cells: 3 minutes per cell, at each cell's left edge.
    local segs = { { width = 80, start = 480, stop = 720 } }
    t.eq(timebar.time_at_column(segs, 1), 480) -- the first cell -> the start
    t.eq(timebar.time_at_column(segs, 41), 600) -- 40 cells in -> +120m -> 10:00
    t.eq(timebar.time_at_column(segs, 100), 720) -- past the end clamps to the last segment's stop
  end)

  t.test("time_at_column reads clock time piecewise across a thin gap", function()
    -- 08:00-10:00 over 40 cells, a 1-cell gap for 10:00-11:00, then 11:00-12:00 over 40 cells.
    local segs = {
      { width = 40, start = 480, stop = 600 },
      { width = 1, gap = true, start = 600, stop = 660 },
      { width = 40, start = 660, stop = 720 },
    }
    t.eq(timebar.time_at_column(segs, 1), 480) -- first cell -> 08:00
    t.eq(timebar.time_at_column(segs, 41), 600) -- the gap cell reports its start, 10:00
    t.eq(timebar.time_at_column(segs, 42), 660) -- the first cell after the gap -> 11:00
    t.eq(timebar.time_at_column(segs, 82), 720) -- past the end clamps to the last stop, 12:00
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

  -- label_placements: place each distinct label once, centred over its widest segment, resolving
  -- overlaps optimally (isotonic regression / PAVA). Segments are hand-built; `col` is 1-based.
  local function mkseg(width, color_index, label)
    return { width = width, color_index = color_index, label = label }
  end
  local function mkgap(width)
    return { width = width, gap = true }
  end
  local function cols(placements)
    local out = {}
    for _, p in ipairs(placements) do
      out[#out + 1] = { p.text, p.color_index, p.col }
    end
    return out
  end

  t.test("label_placements centres a lone label over its segment", function()
    t.eq(cols(timebar.label_placements({ mkseg(10, 1, "a") }, 10)), { { "a", 1, 3 } })
  end)

  t.test("label_placements leaves well-separated labels each over their target", function()
    t.eq(
      cols(timebar.label_placements({ mkseg(10, 1, "a"), mkseg(10, 2, "b") }, 20)),
      { { "a", 1, 3 }, { "b", 2, 13 } }
    )
  end)

  t.test("label_placements pools crowded labels around their centroid", function()
    -- aa and bb sit close (cols 7-9, 10-12); their labels pool and spread abutting, not overlapping.
    t.eq(
      cols(
        timebar.label_placements({ mkgap(6), mkseg(3, 1, "aa"), mkseg(3, 2, "bb"), mkgap(8) }, 20)
      ),
      { { "aa", 1, 3 }, { "bb", 2, 10 } }
    )
  end)

  t.test("label_placements packs a pooled cluster from the edge when it must", function()
    -- aa + bb fill the whole width (Σ label widths == width): packed from col 1.
    t.eq(
      cols(timebar.label_placements({ mkseg(3, 1, "aa"), mkseg(3, 2, "bb"), mkgap(8) }, 14)),
      { { "aa", 1, 1 }, { "bb", 2, 8 } }
    )
  end)

  t.test("label_placements sits a label over its LARGEST segment", function()
    -- "a" appears as a width-2 and a width-5 segment; its label goes over the width-5 one.
    t.eq(
      cols(timebar.label_placements({ mkseg(2, 1, "a"), mkseg(10, 2, "b"), mkseg(5, 1, "a") }, 40)),
      { { "b", 2, 5 }, { "a", 1, 13 } }
    )
  end)

  t.test("label_placements abbreviates then drops the least-present when crowded", function()
    -- alpha (footprint 8) and beta (footprint 5) can't both fit in 13 cells; beta is dropped.
    t.eq(
      cols(timebar.label_placements({ mkseg(8, 1, "alpha"), mkseg(5, 2, "beta") }, 13)),
      { { "alpha", 1, 1 } }
    )
  end)

  t.test("label_placements shows a single over-long label truncated at col 1", function()
    t.eq(cols(timebar.label_placements({ mkseg(3, 1, "verylonglabel") }, 6)), { { "v…", 1, 1 } })
  end)

  t.test("label_placements ignores gap segments (no label for a dead period)", function()
    local placements =
      timebar.label_placements({ mkseg(10, 1, "a"), mkgap(4), mkseg(10, 1, "a") }, 24)
    t.eq(#placements, 1) -- one distinct label; the gap gets none
    t.eq(placements[1].text, "a")
  end)

  t.test("layout places labels for each bar independently", function()
    local layout = timebar.layout(
      entries({ "--- log ---", "08:00 fix => Feature", "10:00 standup", "11:00 done" }),
      40
    )
    local function texts(pl)
      local o = {}
      for _, p in ipairs(pl) do
        o[#o + 1] = p.text
      end
      table.sort(o)
      return o
    end
    t.eq(texts(layout.labels), { "Feature", "standup" }) -- resolved bar
    t.eq(texts(layout.raw_labels), { "fix", "standup" }) -- raw "before" bar
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

  t.test("a blank entry becomes a thin gap marker, not a dropped interval", function()
    -- 08:00 a (120), 10:00 blank -> 11:00 (a dead hour), 11:00 b (60). The gap is one marker cell; the
    -- two activities split the remaining width, so the dead period is visible without consuming the bar.
    local layout =
      timebar.layout(entries({ "--- log ---", "08:00 a", "10:00", "11:00 b", "12:00 done" }), 41)
    t.eq(#layout.segments, 3) -- a, gap, b in time order
    t.eq(layout.segments[1].label, "a")
    t.eq(layout.segments[2].gap, true)
    t.eq(layout.segments[2].label, nil) -- a gap has no activity label
    t.eq(layout.segments[2].width, 1)
    t.eq(layout.segments[2].start, 600) -- 10:00
    t.eq(layout.segments[2].stop, 660) -- 11:00
    t.eq(layout.segments[3].label, "b")
    t.eq(layout.segments[1].width + layout.segments[3].width, 40) -- the gap is not time-proportional
    local total = 0
    for _, seg in ipairs(layout.segments) do
      total = total + seg.width
    end
    t.eq(total, 41) -- still fills the width exactly
    -- the legend lists only real activities, never the gap
    t.eq(#layout.legend, 2)
  end)

  t.test("consecutive blanks collapse into one gap marker", function()
    local layout = timebar.layout(
      entries({ "--- log ---", "08:00 a", "10:00", "10:30", "11:00 b", "12:00 done" }),
      41
    )
    t.eq(#layout.segments, 3) -- a, one gap (spanning 10:00-11:00), b
    t.eq(layout.segments[2].gap, true)
    t.eq(layout.segments[2].start, 600) -- 10:00
    t.eq(layout.segments[2].stop, 660) -- 11:00, the run of two blanks is one marker
  end)

  t.test("gap markers are dropped when the bar is too narrow to hold them", function()
    -- width 1, one gap: width - gaps = 0 < 1, so the markers are dropped and the counted bar fills.
    local layout =
      timebar.layout(entries({ "--- log ---", "08:00 a", "10:00", "11:00 b", "12:00 done" }), 1)
    for _, seg in ipairs(layout.segments) do
      t.eq(seg.gap, nil)
    end
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

  t.test("a mapped entry adds a raw 'before' bar with its own legend", function()
    local layout = timebar.layout(
      entries({
        "--- log ---",
        "08:00 work => Project",
        "09:00 Project",
        "10:00 done",
      }),
      20
    )
    -- resolved (after) bar: both intervals resolve to Project.
    t.eq(layout.segments[1].label, "Project")
    t.eq(layout.segments[2].label, "Project")
    -- raw (before) bar: the => left-hand sides, same widths index-for-index.
    t.eq(layout.raw_segments[1].label, "work")
    t.eq(layout.raw_segments[2].label, "Project")
    t.eq(layout.raw_segments[1].width, layout.segments[1].width)
    t.eq(layout.raw_segments[2].width, layout.segments[2].width)
    -- Each bar names only its own activities: the resolved bar's legend is just Project; the raw bar's
    -- legend is work then Project (its two distinct raw sides).
    t.eq(layout.legend, { { label = "Project", color_index = 1 } })
    t.eq(layout.raw_legend, {
      { label = "work", color_index = 2 },
      { label = "Project", color_index = 1 },
    })
    -- 'work' (raw) gets its own colour; the bare 'Project' interval shares Project's colour in both bars.
    t.eq(layout.segments[1].color_index, 1)
    t.eq(layout.raw_segments[1].color_index, 2)
    t.eq(layout.raw_segments[2].color_index, 1)
  end)

  t.test("each bar's legend names only its own activities, in appearance order", function()
    local layout = timebar.layout(
      entries({
        "--- log ---",
        "08:00 fix login => Feature A",
        "10:00 standup",
        "11:00 write tests => Feature A",
        "13:00 done",
      }),
      60
    )
    -- after: Feature A / standup / Feature A;  before: the three source items.
    t.eq(layout.segments[1].label, "Feature A")
    t.eq(layout.segments[2].label, "standup")
    t.eq(layout.segments[3].label, "Feature A")
    t.eq(layout.raw_segments[1].label, "fix login")
    t.eq(layout.raw_segments[2].label, "standup")
    t.eq(layout.raw_segments[3].label, "write tests")
    -- Colours are one shared map (Feature A=1, standup=2, fix login=3, write tests=4), but each bar's
    -- legend lists only its own distinct labels: the resolved bar, then the raw bar.
    t.eq(layout.legend, {
      { label = "Feature A", color_index = 1 },
      { label = "standup", color_index = 2 },
    })
    t.eq(layout.raw_legend, {
      { label = "fix login", color_index = 3 },
      { label = "standup", color_index = 2 },
      { label = "write tests", color_index = 4 },
    })
    -- standup (unmapped) shares one colour across both bars; both Feature A intervals share index 1.
    t.eq(layout.segments[2].color_index, 2)
    t.eq(layout.raw_segments[2].color_index, 2)
    t.eq(layout.segments[1].color_index, 1)
    t.eq(layout.segments[3].color_index, 1)
  end)

  t.test("an unmapped log has no raw bar (single bar as before)", function()
    local layout =
      timebar.layout(entries({ "--- log ---", "08:00 a", "09:00 b", "10:00 done" }), 40)
    t.eq(layout.raw_segments, nil)
    t.eq(#layout.legend, 2)
    t.eq(layout.legend[1].label, "a")
    t.eq(layout.legend[2].label, "b")
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
      t.eq(#vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sw), 0, -1, false), 2) -- labels + bar

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
