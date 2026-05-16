return function(t)
  local worklog = require("worklog")

  worklog.setup()

  t.test("summarize blocks on unordered worklog", function()
    t.reset({
      "--- worklog #ProjectOrion ---",
      "08:30 later",
      "08:00 earlier #sales",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion ---",
      "08:30 later",
      "08:00 earlier #sales",
      "09:00 done",
    })
  end)

  t.test("equal timestamps are allowed in summarize", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 same",
      "08:00 same again @client",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")
    local lines = t.get_lines()

    t.eq(lines[6], "--- summary exact ---")
    t.eq(lines[7], "1.00h same again")
    t.eq(lines[8], "0.00h same")
    t.eq(lines[10], "--- tags exact ---")
    t.eq(lines[11], "1.00h #ProjectOrion")
    t.eq(lines[13], "--- locations exact ---")
    t.eq(lines[14], "1.00h @client")
    t.eq(lines[15], "0.00h @office")
    t.eq(lines[18], "1.00h workday")
  end)

  t.test("worklog order rewrites all worklog blocks", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:30 later",
      "note a",
      "08:00 earlier #sales",
      "note b",
      "",
      "--- summary exact ---",
      "x",
      "",
      "--- worklog #internal @home ---",
      "11:00 tea",
      "10:00 coffee @client",
      "12:00 done #internal @home",
    })

    vim.cmd("WorklogOrder")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 earlier #sales",
      "note b",
      "08:30 later #ProjectOrion",
      "note a",
      "--- summary exact ---",
      "x",
      "",
      "--- worklog #internal @home ---",
      "10:00 coffee @client",
      "11:00 tea @home",
      "12:00 done",
    })
  end)

  t.test("copy uses latest active worklog and normalizes items", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- summary exact ---",
      "x",
      "",
      "--- worklog #sales @client ---",
      "11:00 tea #sales @client",
      "note tea",
      "",
      "12:00",
    })

    vim.cmd("WorklogCopy")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- summary exact ---",
      "x",
      "",
      "--- worklog #sales @client ---",
      "11:00 tea #sales @client",
      "note tea",
      "",
      "12:00",
      "",
      "--- worklog #sales @client ---",
      "11:00 tea",
      "note tea",
      "12:00",
      })
  end)

  t.test("copy preserves explicit quantize on the active worklog header", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- worklog #sales @client quantize=30 ---",
      "11:00 tea",
      "12:00",
    })

    vim.cmd("WorklogCopy")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "09:00 done",
      "",
      "--- worklog #sales @client quantize=30 ---",
      "11:00 tea",
      "12:00",
      "",
      "--- worklog #sales @client quantize=30 ---",
      "11:00 tea",
      "12:00",
    })
  end)

  t.test("copy preserves clear tokens needed to return to nil metadata", function()
    t.reset({
      "--- worklog ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
    })

    vim.cmd("WorklogCopy")
    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
      "",
      "--- worklog ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
    })
  end)

  t.test("copy does not preserve clear-only header metadata", function()
    t.reset({
      "--- worklog #- @- ---",
      "08:00 plan",
      "09:00 client #ClientA @home",
      "10:00 reset #- @-",
      "11:00 done",
    })

    vim.cmd("WorklogCopy")
    t.eq(t.get_lines(), {
      "--- worklog #- @- ---",
      "08:00 plan",
      "09:00 client #ClientA @home",
      "10:00 reset #- @-",
      "11:00 done",
      "",
      "--- worklog ---",
      "08:00 plan",
      "09:00 client #ClientA @home",
      "10:00 reset #- @-",
      "11:00 done",
    })
  end)

  t.test("repeat inserts into explicit worklog block containing cursor", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:04 bake strudel",
      "08:21 negotiate with goose",
      "10:00 done",
      "",
      "--- summary exact ---",
      "1.93h activity",
      "",
      "--- worklog #sales @client ---",
      "11:00 tea",
      "12:00",
    })
    t.set_cursor(10, 0)

    local old_date = os.date
    os.date = function()
      return "14:37"
    end

    vim.cmd("WorklogRepeat")
    os.date = old_date

    t.eq(t.get_lines()[12], "14:37 tea")
  end)

  t.test("repeat re-emits sticky metadata when insertion state changed", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "08:15 break #ooo",
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
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "08:15 break #ooo",
      "08:30 first #ProjectOrion",
      "09:00 done",
    })
  end)

  t.test("repeat keeps untagged entries untagged without sticky header metadata", function()
    t.reset({
      "--- worklog ---",
      "08:00 first",
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
      "--- worklog ---",
      "08:00 first",
      "08:30 first",
      "09:00 done",
    })
  end)

  t.test("repeat emits clear tokens when replaying nil metadata after sticky values were set", function()
    t.reset({
      "--- worklog ---",
      "08:00 first",
      "08:15 break #ooo @home",
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
      "--- worklog ---",
      "08:00 first",
      "08:15 break #ooo @home",
      "08:30 first #- @-",
      "09:00 done",
    })
  end)

  t.test("insert orders into explicit worklog block after equal timestamps", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "08:00 second",
      "09:00 done",
    })
    t.set_cursor(1, 0)

    local old_date = os.date
    os.date = function()
      return "08:00"
    end

    vim.cmd("WorklogInsert")
    os.date = old_date

    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 first",
      "08:00 second",
      "08:00 ",
      "09:00 done",
    })
  end)

  t.test("insert works from a later worklog header", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 raw",
      "09:00 done",
      "",
      "--- worklog #sales @client ---",
      "10:00 first",
      "11:00 done",
    })
    t.set_cursor(5, 0)

    local old_date = os.date
    os.date = function()
      return "10:30"
    end

    vim.cmd("WorklogInsert")
    os.date = old_date

    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 raw",
      "09:00 done",
      "",
      "--- worklog #sales @client ---",
      "10:00 first",
      "10:30 ",
      "11:00 done",
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

  t.test("summaries show untagged and no location buckets without header metadata", function()
    t.reset({
      "--- worklog ---",
      "08:00 plan",
      "08:15 call #sales @client",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 plan",
      "08:15 call #sales @client",
      "09:00 done",
      "",
      "--- summary exact ---",
      "0.75h call",
      "0.25h plan",
      "",
      "--- tags exact ---",
      "0.75h #sales",
      "0.25h (untagged)",
      "",
      "--- locations exact ---",
      "0.75h @client",
      "0.25h (no location)",
      "",
      "--- totals exact ---",
      "1.00h workday",
    })
  end)

  t.test("summaries keep same-text different-tag rows adjacent and sort by combined duration", function()
    t.reset({
      "--- worklog ---",
      "08:00 meeting #ClientA",
      "09:00 implementation #ClientA",
      "12:00 meeting #internal",
      "14:00 done",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 meeting #ClientA",
      "09:00 implementation #ClientA",
      "12:00 meeting #internal",
      "14:00 done",
      "",
      "--- summary exact ---",
      "2.00h meeting #internal",
      "1.00h meeting #ClientA",
      "3.00h implementation",
      "",
      "--- tags exact ---",
      "4.00h #ClientA",
      "2.00h #internal",
      "",
      "--- totals exact ---",
      "6.00h workday",
    })
  end)

  t.test("summaries omit placeholder-only metadata sections", function()
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
      "",
      "--- summary exact ---",
      "1.00h plan",
      "",
      "--- totals exact ---",
      "1.00h workday",
    })
  end)

  t.test("summaries show cleared metadata as placeholder buckets", function()
    t.reset({
      "--- worklog ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 break #ooo @home",
      "09:00 resume #- @-",
      "10:00 done",
      "",
      "--- summary exact ---",
      "1.00h break",
      "1.00h resume",
      "",
      "--- tags exact ---",
      "1.00h #ooo",
      "1.00h (untagged)",
      "",
      "--- locations exact ---",
      "1.00h @home",
      "1.00h (no location)",
      "",
      "--- totals exact ---",
      "2.00h activity",
      "1.00h workday",
    })
  end)

  t.test("active summaries ignore unrelated invalid older worklog blocks", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 broken #sales #meeting",
      "09:00 done",
      "",
      "--- worklog #sales @client ---",
      "10:00 plan",
      "11:00 done",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 broken #sales #meeting",
      "09:00 done",
      "",
      "--- worklog #sales @client ---",
      "10:00 plan",
      "11:00 done",
      "",
      "--- summary exact ---",
      "1.00h plan",
      "",
      "--- tags exact ---",
      "1.00h #sales",
      "",
      "--- locations exact ---",
      "1.00h @client",
      "",
      "--- totals exact ---",
      "1.00h workday",
    })
  end)

  t.test("summaries ignore attached note lines", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "note about planning",
      "08:30 call #sales @client",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "note about planning",
      "08:30 call #sales @client",
      "09:00 done",
      "",
      "--- summary exact ---",
      "0.50h plan",
      "0.50h call",
      "",
      "--- tags exact ---",
      "0.50h #ProjectOrion",
      "0.50h #sales",
      "",
      "--- locations exact ---",
      "0.50h @office",
      "0.50h @client",
      "",
      "--- totals exact ---",
      "1.00h workday",
    })
  end)

  t.test("quantized summaries show untagged and no location buckets without header metadata", function()
    t.reset({
      "--- worklog quantize=30 ---",
      "08:00 plan",
      "08:12 call #sales @client",
      "08:30 done",
    })

    vim.cmd("WorklogQuantSum")

    t.eq(t.get_lines(), {
      "--- worklog quantize=30 ---",
      "08:00 plan",
      "08:12 call #sales @client",
      "08:30 done",
      "",
      "--- summary quantized ---",
      "0.50h (-12m) call",
      "0.00h (+12m) plan",
      "",
      "--- tags quantized ---",
      "0.50h (-12m) #sales",
      "0.00h (+12m) (untagged)",
      "",
      "--- locations quantized ---",
      "0.50h (-12m) @client",
      "0.00h (+12m) (no location)",
      "",
      "--- totals quantized ---",
      "0.50h (+0m) workday",
    })
  end)

  t.test("quantized summaries omit placeholder-only metadata sections", function()
    t.reset({
      "--- worklog quantize=30 ---",
      "08:00 plan",
      "08:30 done",
    })

    vim.cmd("WorklogQuantSum")

    t.eq(t.get_lines(), {
      "--- worklog quantize=30 ---",
      "08:00 plan",
      "08:30 done",
      "",
      "--- summary quantized ---",
      "0.50h (+0m) plan",
      "",
      "--- totals quantized ---",
      "0.50h (+0m) workday",
    })
  end)

  t.test("quantized summaries honor active worklog quantization", function()
    t.reset({
      "--- worklog @office quantize=30 ---",
      "08:00 earlier",
      "08:30 done",
      "",
      "--- worklog @office quantize=60 ---",
      "09:00 plan",
      "09:20 call #sales @client",
      "10:00 done",
    })

    vim.cmd("WorklogQuantSum")

    t.eq(t.get_lines(), {
      "--- worklog @office quantize=30 ---",
      "08:00 earlier",
      "08:30 done",
      "",
      "--- worklog @office quantize=60 ---",
      "09:00 plan",
      "09:20 call #sales @client",
      "10:00 done",
      "",
      "--- summary quantized ---",
      "1.00h (-20m) call",
      "0.00h (+20m) plan",
      "",
      "--- tags quantized ---",
      "1.00h (-20m) #sales",
      "0.00h (+20m) (untagged)",
      "",
      "--- locations quantized ---",
      "1.00h (-20m) @client",
      "0.00h (+20m) @office",
      "",
      "--- totals quantized ---",
      "1.00h (+0m) workday",
    })
  end)

  t.test("repeat ignores non-worklog lines", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 task",
      "09:00",
      "",
      "--- summary exact ---",
      "0.00h task",
    })
    t.set_cursor(5, 0)

    vim.cmd("WorklogRepeat")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 task",
      "09:00",
      "",
      "--- summary exact ---",
      "0.00h task",
    })
  end)

  t.test("summaries keep exact tag and location totals and render ooo explicitly", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "08:30 plan #sales @client",
      "09:00 break #ooo",
      "09:15 done #ProjectOrion @office",
    })

    vim.cmd("WorklogSummarize")

    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan",
      "08:30 plan #sales @client",
      "09:00 break #ooo",
      "09:15 done #ProjectOrion @office",
      "",
      "--- summary exact ---",
      "0.50h plan #ProjectOrion",
      "0.50h plan #sales",
      "0.25h break",
      "",
      "--- tags exact ---",
      "0.50h #ProjectOrion",
      "0.50h #sales",
      "0.25h #ooo",
      "",
      "--- locations exact ---",
      "0.75h @client",
      "0.50h @office",
      "",
      "--- totals exact ---",
      "1.25h activity",
      "1.00h workday",
    })
  end)

  t.test("quantsum shows signed exact deltas and explicit metadata", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:04 bake strudel",
      "08:21 negotiate with goose #sales @client",
      "08:33 bake strudel #ProjectOrion @office",
      "08:52 coffee with ghost #ooo @home",
      "09:11 polish trombone #ProjectOrion @office",
      "09:36 bake strudel",
      "10:00 done",
    })

    vim.cmd("WorklogQuantSum")

    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:04 bake strudel",
      "08:21 negotiate with goose #sales @client",
      "08:33 bake strudel #ProjectOrion @office",
      "08:52 coffee with ghost #ooo @home",
      "09:11 polish trombone #ProjectOrion @office",
      "09:36 bake strudel",
      "10:00 done",
      "",
      "--- summary quantized ---",
      "1.00h (+0m) bake strudel",
      "0.50h (-5m) polish trombone",
      "0.25h (+4m) coffee with ghost",
      "0.25h (-3m) negotiate with goose",
      "",
      "--- tags quantized ---",
      "1.50h (-5m) #ProjectOrion",
      "0.25h (+4m) #ooo",
      "0.25h (-3m) #sales",
      "",
      "--- locations quantized ---",
      "1.50h (-5m) @office",
      "0.25h (+4m) @home",
      "0.25h (-3m) @client",
      "",
      "--- totals quantized ---",
      "2.00h (-4m) activity",
      "1.75h (-8m) workday",
    })
  end)

  t.test("invalid multiple trailing tags block commands", function()
    t.reset({
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan #sales #meeting",
      "09:00 done",
    })

    vim.cmd("WorklogSummarize")
    t.eq(t.get_lines(), {
      "--- worklog #ProjectOrion @office ---",
      "08:00 plan #sales #meeting",
      "09:00 done",
    })
  end)

  t.test("worklog order emits clear tokens when sorting needs them", function()
    t.reset({
      "--- worklog ---",
      "09:00 done",
      "08:00 plan #sales",
    })

    vim.cmd("WorklogOrder")

    t.eq(t.get_lines(), {
      "--- worklog ---",
      "08:00 plan #sales",
      "09:00 done #-",
    })
  end)
end
