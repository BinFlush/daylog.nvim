return function(t)
  local autosave = require("daylog.autosave")

  -- Open a temp `.day` file as a daylog buffer (filetype set directly, so the test needs no ftdetect).
  local function temp_day_file(lines)
    local path = vim.fn.tempname() .. ".day"
    vim.fn.writefile(lines, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.bo.filetype = "daylog"
    return path, vim.api.nvim_get_current_buf()
  end

  t.test("save writes a modified daylog buffer and clears its modified flag", function()
    local path, buf = temp_day_file({ "--- log ---", "08:00 a", "09:00 done" })
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "08:00 planning" })
    t.ok(vim.bo[buf].modified, "buffer is dirty before save")

    autosave.save(buf)

    t.ok(not vim.bo[buf].modified, "buffer is clean after save")
    t.eq(vim.fn.readfile(path)[2], "08:00 planning")
  end)

  t.test("save is a no-op on an unmodified buffer", function()
    local path, buf = temp_day_file({ "--- log ---", "08:00 a", "09:00 done" })
    -- Mangle the file on disk; an unmodified buffer must not overwrite it.
    vim.fn.writefile({ "sentinel" }, path)

    autosave.save(buf)

    t.eq(vim.fn.readfile(path), { "sentinel" })
  end)

  t.test("save skips non-daylog, nofile, and unnamed buffers without error", function()
    -- A modified non-daylog file buffer is left untouched.
    local other = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "x" }, other)
    vim.cmd("edit " .. vim.fn.fnameescape(other))
    local obuf = vim.api.nvim_get_current_buf()
    vim.bo[obuf].filetype = "text"
    vim.api.nvim_buf_set_lines(obuf, 0, -1, false, { "changed" })
    autosave.save(obuf)
    t.eq(vim.fn.readfile(other), { "x" })

    -- A nofile scratch mislabelled daylog is skipped (buftype ~= "").
    local scratch = vim.api.nvim_create_buf(true, true)
    vim.bo[scratch].filetype = "daylog"
    autosave.save(scratch)

    -- An unnamed daylog buffer has no path to write.
    vim.cmd("enew")
    local unnamed = vim.api.nvim_get_current_buf()
    vim.bo[unnamed].filetype = "daylog"
    vim.api.nvim_buf_set_lines(unnamed, 0, -1, false, { "--- log ---" })
    autosave.save(unnamed)

    t.ok(true, "no error on any skip case")
  end)

  t.test("setup installs a change autocmd only when a delay is set", function()
    autosave.setup(1)
    t.ok(#vim.api.nvim_get_autocmds({
      group = "DaylogAutosave",
      event = { "TextChanged", "TextChangedI" },
    }) > 0, "a delay installs the autosave autocmd")

    autosave.setup(false)
    t.eq(
      #vim.api.nvim_get_autocmds({
        group = "DaylogAutosave",
        event = { "TextChanged", "TextChangedI" },
      }),
      0 -- disabled installs nothing but still clears the prior setup's autocmds
    )
  end)
end
