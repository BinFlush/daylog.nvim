return function(t)
  local summary = require("blotter.summary")

  local CASES = 500
  local SEED = 12345
  local NIL = {}
  local ACTIVITIES = {
    "plan",
    "write code",
    "review",
    "call",
    "coffee",
    "done",
  }
  local TAGS = {
    NIL,
    "ProjectOrion",
    "sales",
    "internal",
    "ooo",
  }
  local LOCATIONS = {
    NIL,
    "office",
    "home",
    "client",
  }
  local QUANTIZE_MINUTES = {
    5,
    15,
    30,
    60,
  }

  local function choice(items)
    return items[math.random(#items)]
  end

  local function denil(value)
    if value == NIL then
      return nil
    end

    return value
  end

  local function sum_durations(items)
    local total = 0

    for _, item in ipairs(items or {}) do
      total = total + item.duration
    end

    return total
  end

  local function case_context(case_number, entries, quantize_minutes)
    return string.format(
      "seed=%d case=%d q=%d\n%s",
      SEED,
      case_number,
      quantize_minutes,
      vim.inspect(entries)
    )
  end

  local function fail(context, message, payload)
    local lines = {
      context,
      message,
    }

    if payload then
      table.insert(lines, payload)
    end

    return table.concat(lines, "\n")
  end

  local function assert_non_negative(test, items, label, context)
    for index, item in ipairs(items or {}) do
      test.ok(
        item.duration >= 0,
        fail(
          context,
          string.format("%s[%d] has negative duration", label, index),
          vim.inspect(item)
        )
      )
    end
  end

  local function assert_unrounded_invariants(test, unrounded_summary, context)
    test.ok(
      sum_durations(unrounded_summary.summary_items) == unrounded_summary.activity_total,
      fail(
        context,
        "sum(summary_items.duration) must equal activity_total",
        vim.inspect(unrounded_summary)
      )
    )
    test.ok(
      sum_durations(unrounded_summary.tag_totals) == unrounded_summary.activity_total,
      fail(
        context,
        "sum(tag_totals.duration) must equal activity_total",
        vim.inspect(unrounded_summary)
      )
    )
    test.ok(
      sum_durations(unrounded_summary.location_totals) == unrounded_summary.activity_total,
      fail(
        context,
        "sum(location_totals.duration) must equal activity_total",
        vim.inspect(unrounded_summary)
      )
    )
    test.ok(
      unrounded_summary.workday_total <= unrounded_summary.activity_total,
      fail(
        context,
        "workday_total must be less than or equal to activity_total",
        vim.inspect(unrounded_summary)
      )
    )

    assert_non_negative(test, unrounded_summary.summary_items, "summary_items", context)
    assert_non_negative(test, unrounded_summary.tag_totals, "tag_totals", context)
    assert_non_negative(test, unrounded_summary.location_totals, "location_totals", context)
  end

  local function assert_bucket_value(test, value, bucket_minutes, label, context, payload)
    test.ok(
      value % bucket_minutes == 0,
      fail(context, string.format("%s must be a multiple of %d", label, bucket_minutes), payload)
    )
  end

  local function assert_quantized_invariants(
    test,
    unrounded_summary,
    quantized_summary,
    quantize_minutes,
    context
  )
    local payload = vim.inspect(quantized_summary)

    assert_bucket_value(
      test,
      quantized_summary.activity_total,
      quantize_minutes,
      "activity_total",
      context,
      payload
    )
    assert_bucket_value(
      test,
      quantized_summary.workday_total,
      quantize_minutes,
      "workday_total",
      context,
      payload
    )

    for index, item in ipairs(quantized_summary.summary_items or {}) do
      assert_bucket_value(
        test,
        item.duration,
        quantize_minutes,
        string.format("summary_items[%d].duration", index),
        context,
        vim.inspect(item)
      )
    end

    for index, item in ipairs(quantized_summary.tag_totals or {}) do
      assert_bucket_value(
        test,
        item.duration,
        quantize_minutes,
        string.format("tag_totals[%d].duration", index),
        context,
        vim.inspect(item)
      )
    end

    for index, item in ipairs(quantized_summary.location_totals or {}) do
      assert_bucket_value(
        test,
        item.duration,
        quantize_minutes,
        string.format("location_totals[%d].duration", index),
        context,
        vim.inspect(item)
      )
    end

    test.ok(
      sum_durations(quantized_summary.summary_items) == quantized_summary.activity_total,
      fail(context, "sum(summary_items.duration) must equal activity_total", payload)
    )
    test.ok(
      sum_durations(quantized_summary.tag_totals) == quantized_summary.activity_total,
      fail(context, "sum(tag_totals.duration) must equal activity_total", payload)
    )
    test.ok(
      sum_durations(quantized_summary.location_totals) == quantized_summary.activity_total,
      fail(context, "sum(location_totals.duration) must equal activity_total", payload)
    )
    test.ok(
      quantized_summary.workday_total <= quantized_summary.activity_total,
      fail(context, "workday_total must be less than or equal to activity_total", payload)
    )
    test.ok(
      quantized_summary.activity_error_minutes
        == unrounded_summary.activity_total - quantized_summary.activity_total,
      fail(
        context,
        "activity_error_minutes must match exact.activity_total - quantized.activity_total",
        string.format("exact=%s\nquantized=%s", vim.inspect(unrounded_summary), payload)
      )
    )
    test.ok(
      quantized_summary.workday_error_minutes
        == unrounded_summary.workday_total - quantized_summary.workday_total,
      fail(
        context,
        "workday_error_minutes must match exact.workday_total - quantized.workday_total",
        string.format("exact=%s\nquantized=%s", vim.inspect(unrounded_summary), payload)
      )
    )

    assert_non_negative(test, quantized_summary.summary_items, "summary_items", context)
    assert_non_negative(test, quantized_summary.tag_totals, "tag_totals", context)
    assert_non_negative(test, quantized_summary.location_totals, "location_totals", context)
  end

  local function generate_sorted_minutes(entry_count)
    local minutes = {}
    local current = math.random(0, 18 * 60)

    table.insert(minutes, current)

    for _ = 2, entry_count do
      current = math.min(current + choice({ 0, 1, 5, 10, 15, 30, 45, 60, 90 }), 23 * 60 + 59)
      table.insert(minutes, current)
    end

    return minutes
  end

  local function generate_entries()
    local entry_count = math.random(2, 12)
    local minutes = generate_sorted_minutes(entry_count)
    local entries = {}

    for index = 1, entry_count do
      local tag = denil(choice(TAGS))
      local location = denil(choice(LOCATIONS))

      table.insert(entries, {
        minutes = minutes[index],
        text = choice(ACTIVITIES),
        tag = tag,
        location = location,
        workday_excluded = tag == "ooo",
      })
    end

    return entries
  end

  t.test("random semantic summaries satisfy unrounded and quantized invariants", function()
    math.randomseed(SEED)

    for case_number = 1, CASES do
      local entries = generate_entries()
      local quantize_minutes = choice(QUANTIZE_MINUTES)
      local context = case_context(case_number, entries, quantize_minutes)
      local unrounded_summary = summary.summarize_entries(entries, 1)
      local quantized_summary = summary.summarize_entries(entries, quantize_minutes)

      assert_unrounded_invariants(t, unrounded_summary, context)
      assert_quantized_invariants(
        t,
        unrounded_summary,
        quantized_summary,
        quantize_minutes,
        context
      )
    end
  end)
end
