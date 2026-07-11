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

-- Apply a fan-out of `changes` (each `{ path, lines }`) atomically per file and as all-or-nothing as a
-- buffer+disk mix allows. An OPEN day file takes the in-memory set_lines branch (so the report reflects
-- it at once); a CLOSED one is written via a temp file + atomic rename (like sources/sync.lua) so an
-- interrupted write can never truncate it. Every disk write is STAGED to its temp first, so a failure
-- (disk full, bad path) aborts before anything is committed and leaves every file untouched -- no partial
-- fan-out, no corruption. Warns with a daylog: message instead of letting a raw error escape. Returns
-- true when every change was applied.
function M.apply_changes(changes)
  local staged = {} -- closed day files: { tmp, path }, written but not yet renamed
  local live = {} -- open buffers: { buf, lines }, not yet set

  for _, change in ipairs(changes) do
    local buf = daybook_io.loaded_buffer_for_path(change.path)
    if buf then
      live[#live + 1] = { buf = buf, lines = change.lines }
    else
      local tmp = change.path .. ".tmp"
      if not pcall(vim.fn.writefile, change.lines, tmp) then
        os.remove(tmp)
        for _, s in ipairs(staged) do
          os.remove(s.tmp) -- nothing committed yet; drop every staged temp
        end
        buffer.warn("daylog: could not write " .. change.path)
        return false
      end
      staged[#staged + 1] = { tmp = tmp, path = change.path }
    end
  end

  -- Commit: rename each staged temp (atomic, same filesystem, so this ~never fails after a good stage),
  -- then set the open buffers (in-memory, cannot fail).
  for _, s in ipairs(staged) do
    if not pcall(function()
      assert(vim.loop.fs_rename(s.tmp, s.path))
    end) then
      os.remove(s.tmp)
      buffer.warn("daylog: could not write " .. s.path)
      return false
    end
  end
  for _, l in ipairs(live) do
    vim.api.nvim_buf_set_lines(l.buf, 0, -1, false, l.lines)
    if vim.bo[l.buf].filetype == "daylog" then
      buffer.highlight_buffer(l.buf)
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
