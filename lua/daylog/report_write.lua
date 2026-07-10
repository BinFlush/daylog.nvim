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
-- once), else straight to disk. Returns true on success, or nil and a message when the disk write fails.
function M.write_change(path, new_lines)
  local buf = daybook_io.loaded_buffer_for_path(path)
  if buf then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    if vim.bo[buf].filetype == "daylog" then
      buffer.highlight_buffer(buf)
    end
    return true
  end

  if not pcall(vim.fn.writefile, new_lines, path) then
    return nil, "daylog: could not write " .. path
  end
  return true
end

-- Apply a fan-out of `changes` (each `{ path, lines }`), stopping at the first write failure and
-- warning with a daylog: message instead of letting a raw error escape the command. Files written
-- before the failure keep their new content. Returns true when every change was written.
function M.apply_changes(changes)
  for _, change in ipairs(changes) do
    local ok, err = M.write_change(change.path, change.lines)
    if not ok then
      buffer.warn(err)
      return false
    end
  end
  return true
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
