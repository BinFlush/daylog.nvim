return function(t)
  local analyze = require("daylog.analyze")
  local document = require("daylog.document")
  local render = require("daylog.render")
  local summary = require("daylog.summary")
  local report_cursor = require("daylog.usecases.report_cursor")
  local rename_summary = require("daylog.usecases.rename_summary")

  -- Build a single day's summary the way the report pipeline (week.lua) does.
  local function day_summary(lines)
    local analysis = analyze.analyze(document.parse(lines))
    local block = analyze.get_active_log(analysis)
    return summary.summarize_block(block), block.quantize_minutes
  end

  -- A two-day range report whose days both carry "implementation" under #ClientA.
  local function sample_report()
    local s1, q1 = day_summary({
      "--- log #ClientA ---",
      "08:00 implementation",
      "10:00 meeting",
      "11:00 done",
    })
    local s2, q2 = day_summary({
      "--- log #ClientA ---",
      "09:00 implementation",
      "12:00 review",
      "13:00 done",
    })

    return {
      days = {
        {
          date_label = "2026-05-18",
          path = "/j/2026-05-18.day",
          summary = s1,
          quantize_minutes = q1,
        },
        {
          date_label = "2026-05-19",
          path = "/j/2026-05-19.day",
          summary = s2,
          quantize_minutes = q2,
        },
      },
      summary = summary.combine_summaries({ s1, s2 }),
      period_label = "2026-W21",
    }
  end

  local function find(layout, predicate)
    for i, row in ipairs(layout) do
      if predicate(row) then
        return i
      end
    end
  end

  t.test("report_cursor refuses an activity row (aggregate and per-day)", function()
    local layout = render.days_report_layout(sample_report(), "dec", {})

    -- An activity row is not renamable (use :Daylog map); both scopes refuse, so a report
    -- rename never reaches a day file.
    for _, scope in ipairs({ "aggregate", "day" }) do
      local index = find(layout, function(row)
        return row.scope == scope
          and row.kind == render.LAYOUT_KIND.SUMMARY_ITEM
          and row.item.text == "implementation"
      end)

      local resolved, err = report_cursor.resolve(layout, index)
      t.eq(resolved, nil)
      t.eq(err, rename_summary.REFUSE_ACTIVITY_ROW)
    end
  end)

  t.test("report_cursor resolves an aggregate tag row to a tag target", function()
    local layout = render.days_report_layout(sample_report(), "dec", {})
    local index = find(layout, function(row)
      return row.scope == "aggregate" and row.kind == render.LAYOUT_KIND.TAG_TOTAL
    end)

    local resolved = report_cursor.resolve(layout, index)
    t.eq(resolved.target, { kind = "tag", current = "ClientA" })
  end)

  t.test("report_cursor honors a passed classifier (log accepts activity rows)", function()
    local log_current = require("daylog.usecases.log_current")
    local layout = render.days_report_layout(sample_report(), "dec", {})
    local index = find(layout, function(row)
      return row.scope == "aggregate"
        and row.kind == render.LAYOUT_KIND.SUMMARY_ITEM
        and row.item.text == "implementation"
    end)

    -- Rename's default classifier refuses this activity row; log's classifier resolves it.
    local resolved = report_cursor.resolve(layout, index, log_current.classify_report_row)
    t.eq(resolved.scope, "aggregate")
    t.eq(resolved.target.level, "s")
    t.eq(resolved.target.value, "implementation")
    t.eq(resolved.target.tag, "ClientA")
    t.eq(resolved.target.names_key, "")
  end)

  t.test("report_cursor refuses header, totals, blank, and out-of-range rows", function()
    local layout = render.days_report_layout(sample_report(), "dec", {})

    local header = find(layout, function(row)
      return row.kind == render.LAYOUT_KIND.HEADER
    end)
    local total = find(layout, function(row)
      return row.kind == render.LAYOUT_KIND.TOTAL
    end)
    local blank = find(layout, function(row)
      return row.kind == render.LAYOUT_KIND.BLANK
    end)

    local _, header_err = report_cursor.resolve(layout, header)
    t.ok(header_err ~= nil, "a header row is not renamable")

    local _, total_err = report_cursor.resolve(layout, total)
    t.ok(total_err ~= nil, "a totals row is not renamable")

    local _, blank_err = report_cursor.resolve(layout, blank)
    t.ok(blank_err ~= nil, "a blank row is not renamable")

    local _, oob_err = report_cursor.resolve(layout, #layout + 100)
    t.eq(oob_err, report_cursor.NOT_A_ROW)
  end)
end
