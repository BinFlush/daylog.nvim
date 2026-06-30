return function(t)
  local colors = require("daylog.colors")
  local highlight = require("daylog.highlight")

  t.test("colours are assigned by first appearance", function()
    -- intervals carrying their resolved label as `.text`, in chronological order
    local index, order = colors.indices({
      { text = "a" },
      { text = "b" },
      { text = "a" },
      { text = "c" },
    })
    t.eq(index.a, 1) -- a appears first
    t.eq(index.b, 2)
    t.eq(index.c, 3)
    t.eq(order, { "a", "b", "c" })
  end)

  t.test("the indicator colours an entry and the notes beneath it as one activity", function()
    local ind = highlight.indicator_rows({
      "--- log ---",
      "08:00 fix login",
      "  a note",
      "  more notes",
      "10:00 review",
      "10:30 fix login",
      "12:00 done",
    })
    t.eq(ind.rows[2], 1) -- fix login (first activity)
    t.eq(ind.rows[3], 1) -- its note inherits the colour
    t.eq(ind.rows[4], 1) -- and the next note
    t.eq(ind.rows[5], 2) -- review (second activity)
    t.eq(ind.rows[6], 1) -- fix login again -> the same colour, stable across the day
    t.eq(ind.rows[7], nil) -- the closing "done" is not an activity
    t.eq(ind.rows[1], nil) -- nor the log header
    t.eq(ind.active_start, 1)
  end)

  t.test("the indicator colours the summary rows to match their activity", function()
    local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
    helpers.with_daylog_setup({}, function()
      t.reset({ "--- log ---", "08:00 fix login", "10:00 review", "10:30 fix login", "12:00 done" })
      vim.bo.filetype = "daylog"
      vim.cmd("Daylog refresh")
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      local ind = highlight.indicator_rows(lines)

      -- The summary rows live below the entries (rows > 5). Each must carry its activity's colour:
      -- fix login -> 1, review -> 2, the same as the entry rows.
      for row, line in ipairs(lines) do
        if row > 5 and line:match("fix login$") then
          t.eq(ind.rows[row], 1)
        elseif row > 5 and line:match("review$") then
          t.eq(ind.rows[row], 2)
        end
      end
      t.eq(ind.rows[2], 1) -- and the entry still matches
      t.eq(ind.rows[3], 2)
    end)
  end)
end
