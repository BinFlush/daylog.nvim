return function(t)
  local worklog = require("worklog")

  worklog.setup()

  t.test("summarize blocks on unordered worklog", function()
    t.reset({
      "--- worklog default=#ProjectOrion ---",
      "08:30 later",
      "08:00 earlier",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")
    t.eq(t.get_lines(), {
      "--- worklog default=#ProjectOrion ---",
      "08:30 later",
      "08:00 earlier",
      "09:00 done",
    })
  end)

  t.test("equal timestamps are allowed in summarize", function()
    t.reset({
      "--- worklog default=#ProjectOrion ---",
      "08:00 same",
      "08:00 same again",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")
    local lines = t.get_lines()

    t.eq(lines[6], "--- summary exact ---")
    t.eq(lines[7], "0.00h same")
    t.eq(lines[8], "1.00h same again")
    t.eq(lines[10], "--- labels exact ---")
    t.eq(lines[11], "1.00h #ProjectOrion")
    t.eq(lines[14], "1.00h activity")
  end)

  t.test("worklog order rewrites all worklog blocks", function()
    t.reset({
      "--- worklog default=#ProjectOrion ---",
      "08:30 later #ProjectOrion",
      "note a",
      "08:00 earlier",
      "note b",
      "",
      "--- summary exact ---",
      "x",
      "",
      "--- worklog ---",
      "11:00 tea #ProjectOrion",
      "10:00 coffee",
      "12:00",
    })

    vim.cmd("WorklogOrder")
    t.eq(t.get_lines(), {
      "--- worklog default=#ProjectOrion ---",
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
      "--- worklog default=#ProjectOrion ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- summary exact ---",
      "x",
      "",
      "--- worklog ---",
      "11:00 tea #ProjectOrion",
      "note tea",
      "",
      "12:00",
    })

    vim.cmd("WorklogCopy")
    t.eq(t.get_lines(), {
      "--- worklog default=#ProjectOrion ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- summary exact ---",
      "x",
      "",
      "--- worklog ---",
      "11:00 tea #ProjectOrion",
      "note tea",
      "",
      "12:00",
      "",
      "--- worklog ---",
      "11:00 tea",
      "note tea",
      "12:00",
    })
  end)

  t.test("repeat inserts into explicit worklog block containing cursor", function()
    t.reset({
      "--- worklog default=#ProjectOrion ---",
      "08:04 bake strudel",
      "08:21 negotiate with goose",
      "10:00 done",
      "",
      "--- summary exact ---",
      "1.93h activity",
      "",
      "--- worklog ---",
      "11:00 tea #sales",
      "12:00",
    })
    t.set_cursor(10, 0)

    local old_date = os.date
    os.date = function()
      return "14:37"
    end

    vim.cmd("WorklogRepeat")
    os.date = old_date

    t.eq(t.get_lines()[12], "14:37 tea #sales")
  end)

  t.test("repeat normalizes redundant default label away", function()
    t.reset({
      "--- worklog default=#ProjectOrion ---",
      "08:00 first #ProjectOrion",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    local old_date = os.date
    os.date = function()
      return "08:30"
    end

    vim.cmd("WorklogRepeat")
    os.date = old_date

    t.eq(t.get_lines(), {
      "--- worklog default=#ProjectOrion ---",
      "08:00 first #ProjectOrion",
      "08:30 first",
      "09:00 done",
    })
  end)

  t.test("insert orders into explicit worklog block after equal timestamps", function()
    t.reset({
      "--- worklog default=#ProjectOrion ---",
      "08:00 first",
      "08:00 second",
      "09:00 done",
    })
    t.set_cursor(2, 0)

    local old_date = os.date
    os.date = function()
      return "08:00"
    end

    vim.cmd("WorklogInsert")
    os.date = old_date

    t.eq(t.get_lines(), {
      "--- worklog default=#ProjectOrion ---",
      "08:00 first",
      "08:00 second",
      "08:00 ",
      "09:00 done",
    })
  end)

  t.test("insert warns when no explicit worklog exists", function()
    t.reset({
      "08:00 raw",
      "09:00 done",
    })
    t.set_cursor(1, 0)

    vim.cmd("WorklogInsert")
    t.eq(t.get_lines(), {
      "08:00 raw",
      "09:00 done",
    })
  end)

  t.test("summaries allow unlabeled final closing line without a default label", function()
    t.reset({
      "--- worklog ---",
      "08:00 plan #sales",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 plan #sales",
      "09:00 done",
      "",
      "--- summary exact ---",
      "1.00h plan #sales",
      "",
      "--- labels exact ---",
      "1.00h #sales",
      "",
      "--- totals exact ---",
      "1.00h activity",
      "1.00h workday",
    })
  end)

  t.test("missing labels without a default block commands", function()
    t.reset({
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")
    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 plan",
      "09:00 done",
    })
  end)

  t.test("repeat ignores non-worklog lines", function()
    t.reset({
      "--- worklog default=#ProjectOrion ---",
      "08:00 task",
      "09:00",
      "",
      "--- summary exact ---",
      "0.00h task",
    })
    t.set_cursor(5, 0)

    vim.cmd("WorklogRepeat")
    t.eq(t.get_lines(), {
      "--- worklog default=#ProjectOrion ---",
      "08:00 task",
      "09:00",
      "",
      "--- summary exact ---",
      "0.00h task",
    })
  end)

  t.test("summaries keep exact label totals and omit the default label on item rows", function()
    t.reset({
      "--- worklog default=#ProjectOrion ---",
      "08:00 plan",
      "08:30 plan #sales",
      "09:00 break #ooo",
      "09:15 done",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog default=#ProjectOrion ---",
      "08:00 plan",
      "08:30 plan #sales",
      "09:00 break #ooo",
      "09:15 done",
      "",
      "--- summary exact ---",
      "0.50h plan",
      "0.50h plan #sales",
      "0.25h break (ooo)",
      "",
      "--- labels exact ---",
      "0.50h #ProjectOrion",
      "0.50h #sales",
      "0.25h #ooo",
      "",
      "--- totals exact ---",
      "1.25h activity",
      "1.00h workday",
    })
  end)

  t.test("quantsum shows signed exact deltas and explicit labels", function()
    t.reset({
      "--- worklog default=#ProjectOrion ---",
      "08:04 bake strudel",
      "08:21 negotiate with goose #sales",
      "08:33 bake strudel",
      "08:52 coffee with ghost #ooo",
      "09:11 polish trombone",
      "09:36 bake strudel",
      "10:00 done",
    })

    vim.cmd("WorklogQuantSum")

    t.eq(t.get_lines(), {
      "--- worklog default=#ProjectOrion ---",
      "08:04 bake strudel",
      "08:21 negotiate with goose #sales",
      "08:33 bake strudel",
      "08:52 coffee with ghost #ooo",
      "09:11 polish trombone",
      "09:36 bake strudel",
      "10:00 done",
      "",
      "--- summary quantized ---",
      "1.00h (+0m) bake strudel",
      "0.25h (-3m) negotiate with goose #sales",
      "0.25h (+4m) coffee with ghost (ooo)",
      "0.50h (-5m) polish trombone",
      "",
      "--- labels quantized ---",
      "1.50h (-5m) #ProjectOrion",
      "0.25h (-3m) #sales",
      "0.25h (+4m) #ooo",
      "",
      "--- totals quantized ---",
      "2.00h (-4m) activity",
      "1.75h (-8m) workday",
    })
  end)

  t.test("invalid multiple trailing labels block commands", function()
    t.reset({
      "--- worklog default=#ProjectOrion ---",
      "08:00 plan #sales #meeting",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")
    t.eq(t.get_lines(), {
      "--- worklog default=#ProjectOrion ---",
      "08:00 plan #sales #meeting",
      "09:00 done",
    })
  end)
end
