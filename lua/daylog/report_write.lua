local buffer = require("daylog.buffer")
local daybook_io = require("daylog.daybook_io")

local M = {}

-- Shared shell helpers for commands that act on a multi-day report by fanning a change out across its
-- source day files (rename, log). `target_paths` is pure; `write_change` / `confirm` touch buffers/UI.

-- The day files a resolved report row acts on: one path for a per-day row, every day of the period
-- for an aggregate row.
function M.target_paths(report, resolved)
  if resolved.scope == "day" then
    return { resolved.path }
  end

  local paths = {}
  for _, day in ipairs(report.days) do
    paths[#paths + 1] = day.path
  end
  return paths
end

-- Write a day file's new content into its open buffer when one exists (so the report reflects it at
-- once), else straight to disk.
function M.write_change(path, new_lines)
  local buf = daybook_io.loaded_buffer_for_path(path)
  if buf then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    if vim.bo[buf].filetype == "daylog" then
      buffer.highlight_buffer(buf)
    end
    return
  end

  vim.fn.writefile(new_lines, path)
end

-- Confirm a fan-out that will rewrite `changes` (each carrying `path`). `sentence` states the action
-- ("rename tag 'X' to 'Y'", "log !S 'X' with a, b"); the affected files are listed by basename.
function M.confirm(sentence, changes)
  local names = {}
  for _, change in ipairs(changes) do
    names[#names + 1] = "  " .. vim.fn.fnamemodify(change.path, ":t")
  end

  local prompt =
    string.format("daylog: %s in %d file(s)?\n%s", sentence, #changes, table.concat(names, "\n"))

  return vim.fn.confirm(prompt, "&Yes\n&No", 1) == 1
end

return M
