return function(t)
  local append_copy = require("blotter.usecases.append_copy")
  local order_blotters = require("blotter.usecases.order_blotters")
  local refresh_summaries = require("blotter.usecases.refresh_summaries")

  -- The summary refresh creates a summary for a blotter that lacks one, so it
  -- produces the canonical summary for a v0.1.0 fixture.
  local function summarize(lines)
    return refresh_summaries.run(lines)
  end

  local root = vim.fn.getcwd()
  local base_dir = root .. "/tests/compat/v0.1.0"
  local fixtures = {
    {
      name = "basic",
      run = summarize,
      expected_suffix = ".summary",
    },
    {
      name = "sticky_metadata",
      run = summarize,
      expected_suffix = ".summary",
    },
    {
      name = "out_of_office",
      run = summarize,
      expected_suffix = ".summary",
    },
    {
      name = "quantized",
      run = summarize,
      expected_suffix = ".summary",
    },
    {
      name = "summary_conflicting_tags",
      run = summarize,
      expected_suffix = ".summary",
    },
    {
      name = "quantized_out_of_office",
      run = summarize,
      expected_suffix = ".summary",
    },
    {
      name = "copy_active_block",
      run = append_copy.run,
      expected_suffix = ".output",
    },
    {
      name = "order_notes_and_clears",
      run = order_blotters.run,
      expected_suffix = ".output",
    },
  }

  -- Edit scripts use zero-based indexes to mirror nvim_buf_set_lines(), while
  -- Lua arrays are one-based. This applies the same replacement semantics to a
  -- plain table so compatibility fixtures can test usecases without a buffer.
  local function apply_result(lines, result)
    local output = vim.deepcopy(lines)

    for _, edit in ipairs(result.edits or {}) do
      for i = edit.end_index, edit.start_index + 1, -1 do
        table.remove(output, i)
      end

      for i = #edit.lines, 1, -1 do
        table.insert(output, edit.start_index + 1, edit.lines[i])
      end
    end

    return output
  end

  local function mismatch_message(name, expected, actual)
    local lines = {
      string.format("compat fixture %s mismatch", name),
    }
    local max_lines = math.max(#expected, #actual)

    for i = 1, max_lines do
      if expected[i] ~= actual[i] then
        table.insert(
          lines,
          string.format(
            "line %d expected %s got %s",
            i,
            vim.inspect(expected[i]),
            vim.inspect(actual[i])
          )
        )
      end
    end

    return table.concat(lines, "\n")
  end

  for _, fixture in ipairs(fixtures) do
    t.test("compat " .. fixture.name .. " matches v0.1.0 baseline", function()
      local input = vim.fn.readfile(base_dir .. "/" .. fixture.name .. ".blot")
      local expected = vim.fn.readfile(base_dir .. "/" .. fixture.name .. fixture.expected_suffix)
      local result, err = fixture.run(input)

      t.ok(result ~= nil, err)

      local actual = apply_result(input, result)
      t.ok(vim.deep_equal(actual, expected), mismatch_message(fixture.name, expected, actual))
    end)
  end
end
