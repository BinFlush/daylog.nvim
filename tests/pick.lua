return function(t)
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_daylog_setup = helpers.with_daylog_setup
  local pick = require("daylog.pick")

  local function corpus_names(level)
    local names = {}
    for _, row in ipairs(pick.name_corpus(level)) do
      names[#names + 1] = row.name
    end
    return names
  end

  t.test("the log-names corpus always includes the current buffer's own log", function()
    -- Regression: name_corpus scanned only the trailing daybook files, so with no daybook (or an
    -- out-of-tree .day file) the names in the log you are editing were never offered by the picker.
    with_daylog_setup({}, function()
      t.reset({
        "--- log q=15 d=dec ---",
        "08:00 task",
        "09:00 task !S[,hey]60",
        "10:00 done",
      })
      t.eq(corpus_names("s"), { "hey" }) -- offered; the unnamed "" is never a corpus name
      t.eq(corpus_names("t"), {}) -- a level with no names stays empty
    end)
  end)
end
