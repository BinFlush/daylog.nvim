local buffer = require("daylog.buffer")
local config = require("daylog.config")
local daybook = require("daylog.daybook")
local new_log = require("daylog.usecases.new_log")
local text = require("daylog.text")

local M = {}

-- Day-file / buffer IO (shell).
--
-- Reads, opens, scans, and seeds the dated daybook files on disk and their loaded buffers;
-- distinct from the pure daybook.lua (path/date math only).

local warn = buffer.warn
local buffer_is_empty = buffer.buffer_is_empty
local run_buffer_usecase = buffer.run_buffer_usecase

-- The system's current UTC offset in signed minutes from os.date("%z"), or nil when the platform
-- reports no numeric offset (so an unresolvable offset stamps no zone rather than a wrong one).
local function system_utc_offset_minutes()
  local sign, hours, minutes = tostring(os.date("%z")):match("^([%+%-])(%d%d)(%d%d)$")
  if not sign then
    return nil
  end

  local total = tonumber(hours) * 60 + tonumber(minutes)
  if sign == "-" then
    total = -total
  end

  return total
end

-- The live system offset to stamp on a current-time insert, or nil when auto_timezone is off or the
-- platform reports no numeric offset.
local function live_offset()
  if not config.get().auto_timezone then
    return nil
  end
  return system_utc_offset_minutes()
end

-- Resolve a defaults table's `utc` for a fresh log header: the system offset fills in for the
-- "auto" sentinel and for an unset offset when `auto_timezone` is on. The shared config table is
-- never mutated; a copy is returned only when the offset must be resolved.
local function resolve_log_defaults(defaults)
  local utc = defaults and defaults.utc
  local resolve = utc == "auto" or (utc == nil and config.get().auto_timezone)
  if not resolve then
    return defaults
  end

  local resolved = {}
  if defaults then
    for key, value in pairs(defaults) do
      resolved[key] = value
    end
  end
  resolved.utc = system_utc_offset_minutes()
  return resolved
end

local function apply_new_log(defaults)
  return run_buffer_usecase(new_log.run, resolve_log_defaults(defaults))
end

-- Scaffold a fresh log into the current buffer using the configured header defaults: an empty
-- buffer is initialized in place, otherwise a new log block is appended as the active log. Reached
-- through :Daylog new.
function M.insert_new_log()
  return apply_new_log(config.get().defaults)
end

-- A loaded, file-backed buffer whose name resolves to `path`, or nil. Report buffers (nofile) are
-- skipped so they can never shadow a real daybook file.
local function loaded_buffer_for_path(path)
  local target = vim.fn.fnamemodify(path, ":p")

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fn.fnamemodify(name, ":p") == target then
        return buf
      end
    end
  end

  return nil
end

-- Read a daybook day's lines for reporting, preferring a loaded buffer (so reports reflect unsaved
-- edits) then the file on disk. Returns nil when neither exists (treated as an empty day).
local function daybook_lines(path)
  local buf = loaded_buffer_for_path(path)
  if buf then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  if vim.fn.filereadable(path) == 1 then
    -- readfile keeps the trailing \r on CRLF files where a loaded buffer strips it; strip it here
    -- too so disk-read and buffer-read labels group instead of splitting into separate rows.
    local lines = vim.fn.readfile(path)
    for i, line in ipairs(lines) do
      lines[i] = (line:gsub("\r$", ""))
    end
    return lines
  end

  return nil
end

-- True when a daybook day already holds log content, considering a loaded
-- (possibly unsaved) buffer before falling back to the file on disk.
local function daybook_path_has_content(path)
  local lines = daybook_lines(path)
  return lines ~= nil and not text.is_empty(lines)
end

-- Every daybook day that holds a daylog: canonical dated `.day` files under the tree plus any
-- loaded buffer with content not yet on disk. Returns a list of midday timestamps (de-duplicated by
-- nearest_date).
local function existing_daybook_dates(settings)
  local dates = {}

  -- Trim any trailing slash so the paths match date_from_path's canonical single-slash form (a
  -- `root//2026/...` would be rejected as non-canonical). vim.fs.find treats `root` LITERALLY --
  -- unlike a glob, which would interpret `[`/`{`/`?` in the configured path as pattern syntax.
  local root = (settings.root:gsub("/+$", ""))
  for _, path in
    ipairs(vim.fs.find(function(name)
      return name:sub(-4) == ".day"
    end, { path = root, type = "file", limit = math.huge }))
  do
    local date = daybook.date_from_path(settings, path)
    if date and daybook_path_has_content(path) then
      table.insert(dates, date)
    end
  end

  -- An unsaved new day has no file yet, so pick it up from the buffer list; report scratch buffers
  -- (nofile) are skipped by the buftype guard.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        local date = daybook.date_from_path(settings, vim.fn.fnamemodify(name, ":p"))
        if date and not text.is_empty(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
          table.insert(dates, date)
        end
      end
    end
  end

  return dates
end

-- The earliest daybook date that holds a daylog, or nil when none exist. Resolves an
-- open-ended range start (`..TO` / `..`).
local function earliest_daybook_date(settings)
  local earliest

  for _, date in ipairs(existing_daybook_dates(settings)) do
    if not earliest or date < earliest then
      earliest = date
    end
  end

  return earliest
end

-- The latest daybook date that holds a daylog, or nil. Resolves an open-ended range end (`FROM..`);
-- future-dated files count, so an open right end reaches into the future.
local function latest_daybook_date(settings)
  local latest

  for _, date in ipairs(existing_daybook_dates(settings)) do
    if not latest or date > latest then
      latest = date
    end
  end

  return latest
end

local function expanded_daybook_settings()
  local settings = config.get().daybook
  if settings == nil then
    return nil
  end

  return {
    -- Absolutize so a relative daybook.root still matches the absolute buffer
    -- paths date_from_path compares against (it uses string equality).
    root = vim.fn.fnamemodify(vim.fn.expand(settings.root), ":p"),
    directory = settings.directory,
  }
end

local function can_abandon_current_buffer()
  return not vim.bo.modified or vim.o.hidden or vim.o.autowrite or vim.o.autowriteall
end

-- Open (creating the directory, file, and header as needed) the daybook file
-- for a date. Returns ok, was_initialized.
local function open_daybook_file(settings, date)
  local path = daybook.path_for_date(settings, date)
  local directory = vim.fn.fnamemodify(path, ":h")

  if vim.fn.isdirectory(directory) == 0 and vim.fn.mkdir(directory, "p") == 0 then
    warn("daylog: failed to create daybook directory: " .. directory)
    return false
  end

  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    warn(tostring(err))
    return false
  end

  -- Decide from the live buffer, not disk: :edit reuses an existing unsaved buffer whose content
  -- must not be re-seeded, while a freshly opened missing/empty file gets the initial header.
  local should_initialize = buffer_is_empty()

  if should_initialize and not apply_new_log(config.get().defaults) then
    return false
  end

  return true, should_initialize
end

-- Open the daybook file for navigation only: never create the directory/file or write a header, so
-- a missing day opens as an empty, unmodified, cleanly-abandonable buffer.
local function edit_daybook_file(settings, date)
  local path = daybook.path_for_date(settings, date)

  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    warn(tostring(err))
    return false
  end

  return true
end

-- The daybook date the current buffer represents, or nil when it is not a
-- canonical daybook file (unnamed buffer, daybook unconfigured, or a dated file
-- outside the configured location).
local function current_buffer_daybook_date(settings)
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return nil
  end

  return daybook.date_from_path(settings, vim.fn.fnamemodify(name, ":p"))
end

M.live_offset = live_offset
M.loaded_buffer_for_path = loaded_buffer_for_path
M.daybook_lines = daybook_lines
M.daybook_path_has_content = daybook_path_has_content
M.existing_daybook_dates = existing_daybook_dates
M.earliest_daybook_date = earliest_daybook_date
M.latest_daybook_date = latest_daybook_date
M.expanded_daybook_settings = expanded_daybook_settings
M.can_abandon_current_buffer = can_abandon_current_buffer
M.open_daybook_file = open_daybook_file
M.edit_daybook_file = edit_daybook_file
M.current_buffer_daybook_date = current_buffer_daybook_date

return M
