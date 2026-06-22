return function(t)
  local context = require("daylog.context")
  local INVALID_FIRST_HEADER_MESSAGE = "daylog: first line must be a log header such as "
    .. "--- log --- or --- log #ClientA @office q=30 ---"
  local NO_LOG_ERROR = "daylog: no log block found; first line must be a "
    .. "log header such as --- log --- or "
    .. "--- log #ClientA @office q=30 ---"

  t.test("context selects the active log and preserves body lines", function()
    local ctx = context.get_active_log_context({
      "--- log #ProjectOrion @office q=30 ---",
      "08:00 raw",
      "09:00",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h raw",
      "",
      "--- log #internal @home ---",
      "10:00 tea",
      "11:00",
    })

    t.eq(ctx.header_tag, "internal")
    t.eq(ctx.header_location, "home")
    t.eq(ctx.block.start_row, 8)
    t.eq(ctx.block.body_start_row, 9)
    t.eq(ctx.block.end_row, 11)
    t.eq(ctx.block.quantize_minutes, 15)
    t.eq(ctx.block.duration_format, "dec")
  end)

  t.test("context includes header rows when selecting logs by cursor", function()
    local lines = {
      "--- log #ProjectOrion @office ---",
      "08:00 raw",
      "09:00",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h raw",
      "",
      "--- log #internal @home ---",
      "10:00 tea",
      "11:00",
    }

    t.eq(context.get_log_context_at_row(lines, 1).block.start_row, 1)
    t.eq(context.get_log_context_at_row(lines, 2).block.start_row, 1)
    t.eq(context.get_log_context_at_row(lines, 8).block.start_row, 8)
    t.eq(context.get_log_context_at_row(lines, 9).block.start_row, 8)
  end)

  t.test("context accepts first log headers without metadata", function()
    local ctx = context.get_active_log_context({
      "--- log ---",
      "08:00 raw #sales",
      "09:00 done",
    })

    t.eq(ctx.header_tag, nil)
    t.eq(ctx.header_location, nil)
    t.eq(ctx.block.start_row, 1)
  end)

  t.test("context surfaces structural header errors and missing logs", function()
    local ctx, err = context.get_active_log_context({
      "--- summary q=15 d=dec ---",
      "1.00h activity",
    })

    t.eq(ctx, nil)
    t.eq(err, INVALID_FIRST_HEADER_MESSAGE)

    ctx, err = context.get_active_log_context({
      "08:00 raw",
      "09:00 done",
    })
    t.eq(ctx, nil)
    t.eq(err, NO_LOG_ERROR)
  end)

  t.test("context rejects cursor rows outside log blocks", function()
    local ctx, err = context.get_log_context_at_row({
      "--- log #ProjectOrion @office ---",
      "08:00 raw",
      "09:00",
      "",
      "--- summary q=15 d=dec ---",
      "1.00h raw",
    }, 5)

    t.eq(ctx, nil)
    t.eq(err, "daylog: current line is not inside a log block")
  end)
end
