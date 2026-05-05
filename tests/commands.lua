return function(t)
  local worklog = require("worklog")

  worklog.setup()

  t.test("summarize blocks on unordered worklog", function()
    t.reset({
      "08:30 later",
      "08:00 earlier",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")
    t.eq(t.get_lines(), {
      "08:30 later",
      "08:00 earlier",
      "09:00 done",
    })
  end)

  t.test("equal timestamps are allowed in summarize", function()
    t.reset({
      "08:00 same",
      "08:00 same again",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")
    local lines = t.get_lines()

    t.eq(lines[5], "--- summary exact ---")
    t.eq(lines[6], "0.00h same")
    t.eq(lines[7], "1.00h same again")
    t.eq(lines[10], "1.00h activity")
  end)

  t.test("worklog order rewrites all worklog blocks", function()
    t.reset({
      "08:30 later",
      "note a",
      "08:00 earlier",
      "note b",
      "",
      "--- summary exact ---",
      "x",
      "",
      "--- worklog ---",
      "11:00 tea",
      "10:00 coffee",
      "12:00",
    })

    vim.cmd("WorklogOrder")
    t.eq(t.get_lines(), {
      "08:00 earlier",
      "note b",
      "08:30 later",
      "note a",
      "--- summary exact ---",
      "x",
      "",
      "--- worklog ---",
      "10:00 coffee",
      "11:00 tea",
      "12:00",
    })
  end)

  t.test("copy uses latest active worklog and normalizes items", function()
    t.reset({
      "08:00 first",
      "note a",
      "",
      "08:30 second",
      "09:00",
      "",
      "--- summary exact ---",
      "x",
      "",
      "--- worklog ---",
      "11:00 tea",
      "note tea",
      "",
      "12:00",
    })

    vim.cmd("WorklogCopy")
    local lines = t.get_lines()

    t.eq(lines[16], "--- worklog ---")
    t.eq(lines[17], "11:00 tea")
    t.eq(lines[18], "note tea")
    t.eq(lines[19], "12:00")
  end)

  t.test("repeat inserts into explicit worklog block containing cursor", function()
    t.reset({
      "08:04 bake strudel",
      "08:21 negotiate with goose",
      "10:00",
      "",
      "--- summary exact ---",
      "1.93h activity",
      "",
      "--- worklog ---",
      "11:00 tea",
      "12:00",
    })
    t.set_cursor(9, 0)

    local old_date = os.date
    os.date = function()
      return "14:37"
    end

    vim.cmd("WorklogRepeat")
    os.date = old_date

    t.eq(t.get_lines()[11], "14:37 tea")
  end)

  t.test("insert orders into implicit worklog block", function()
    t.reset({
      "08:00 first",
      "09:00 done",
    })
    t.set_cursor(1, 0)

    local old_date = os.date
    os.date = function()
      return "08:30"
    end

    vim.cmd("WorklogInsert")
    os.date = old_date

    t.eq(t.get_lines(), {
      "08:00 first",
      "08:30 ",
      "09:00 done",
    })
  end)

  t.test("insert orders into explicit worklog block after equal timestamps", function()
    t.reset({
      "08:00 raw",
      "09:00",
      "",
      "--- worklog ---",
      "08:00 first",
      "08:00 second",
      "09:00 done",
    })
    t.set_cursor(5, 0)

    local old_date = os.date
    os.date = function()
      return "08:00"
    end

    vim.cmd("WorklogInsert")
    os.date = old_date

    t.eq(t.get_lines(), {
      "08:00 raw",
      "09:00",
      "",
      "--- worklog ---",
      "08:00 first",
      "08:00 second",
      "08:00 ",
      "09:00 done",
    })
  end)

  t.test("insert warns outside worklog block", function()
    t.reset({
      "08:00 raw",
      "09:00",
      "",
      "--- summary exact ---",
      "0.00h raw",
    })
    t.set_cursor(4, 0)

    vim.cmd("WorklogInsert")
    t.eq(t.get_lines(), {
      "08:00 raw",
      "09:00",
      "",
      "--- summary exact ---",
      "0.00h raw",
    })
  end)

  t.test("repeat orders into implicit worklog block", function()
    t.reset({
      "08:00 first",
      "09:00 second",
      "10:00 done",
    })
    t.set_cursor(1, 0)

    local old_date = os.date
    os.date = function()
      return "08:30"
    end

    vim.cmd("WorklogRepeat")
    os.date = old_date

    t.eq(t.get_lines(), {
      "08:00 first",
      "08:30 first",
      "09:00 second",
      "10:00 done",
    })
  end)

  t.test("repeat orders into explicit block after equal timestamps", function()
    t.reset({
      "08:00 raw",
      "09:00",
      "",
      "--- worklog ---",
      "08:00 tea",
      "08:00 coffee",
      "09:00 done",
    })
    t.set_cursor(5, 0)

    local old_date = os.date
    os.date = function()
      return "08:00"
    end

    vim.cmd("WorklogRepeat")
    os.date = old_date

    t.eq(t.get_lines(), {
      "08:00 raw",
      "09:00",
      "",
      "--- worklog ---",
      "08:00 tea",
      "08:00 coffee",
      "08:00 tea",
      "09:00 done",
    })
  end)

  t.test("repeat ignores non-worklog lines", function()
    t.reset({
      "08:00 task",
      "09:00",
      "",
      "--- summary exact ---",
      "0.00h task",
    })
    t.set_cursor(4, 0)

    vim.cmd("WorklogRepeat")
    t.eq(t.get_lines(), {
      "08:00 task",
      "09:00",
      "",
      "--- summary exact ---",
      "0.00h task",
    })
  end)

  t.test("summarize and quantsum succeed after ordering", function()
    t.reset({
      "08:30 later",
      "note later",
      "08:00 earlier",
      "09:00 done",
      "",
      "--- summary exact ---",
      "x",
    })

    vim.cmd("WorklogOrder")
    vim.cmd("WorklogSummarize")
    vim.cmd("WorklogQuantSum")

    local lines = t.get_lines()
    t.eq(lines[8], "--- summary exact ---")
    t.eq(lines[9], "0.50h earlier")
    t.eq(lines[10], "0.50h later")
    t.eq(lines[16], "--- summary quantized ---")
    t.eq(lines[17], "0.50h (+0m) earlier")
    t.eq(lines[18], "0.50h (+0m) later")
  end)

  t.test("quantsum shows signed exact deltas", function()
    t.reset({
      "08:04 bake strudel",
      "08:21 negotiate with goose",
      "08:33 bake strudel",
      "08:52 coffee with ghost #ooo",
      "09:11 polish trombone",
      "09:36 bake strudel",
      "10:00 done",
    })

    vim.cmd("WorklogQuantSum")

    t.eq(t.get_lines(), {
      "08:04 bake strudel",
      "08:21 negotiate with goose",
      "08:33 bake strudel",
      "08:52 coffee with ghost #ooo",
      "09:11 polish trombone",
      "09:36 bake strudel",
      "10:00 done",
      "",
      "--- summary quantized ---",
      "1.00h (+0m) bake strudel",
      "0.25h (-3m) negotiate with goose",
      "0.25h (+4m) coffee with ghost (ooo)",
      "0.50h (-5m) polish trombone",
      "",
      "--- totals quantized ---",
      "2.00h activity",
      "1.75h workday",
    })
  end)
end
