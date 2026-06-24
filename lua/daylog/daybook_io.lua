local buffer = require("daylog.buffer")
local config = require("daylog.config")
local daybook = require("daylog.daybook")
local new_log = require("daylog.usecases.new_log")
local text = require("daylog.text")

local M = {}

-- Day-file / buffer IO (shell).
--
-- Reads, opens, scans, and seeds the dated daybook files on disk (and their loaded
-- buffers). Distinct from the pure daybook.lua, which is only path/date math.

local warn = buffer.warn
local buffer_lines = buffer.buffer_lines
local buffer_is_empty = buffer.buffer_is_empty
local apply_result = buffer.apply_result

-- The system's current UTC offset in signed minutes, parsed from os.date("%z")
-- ("+0200", "-0400", "+0530"). Returns nil when the platform does not report a
-- numeric offset, so an unresolvable "auto" default stamps no zone rather than a
-- wrong one. This is the one, one-time clock read for the offset feature; mid-day
-- markers stay manual.
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

-- Resolve a defaults table's `utc` for a fresh log header: the "auto" sentinel
-- becomes the system's current offset, a numeric offset passes through, and absent
-- stays absent. The shared config table is never mutated; a copy is returned only
-- when "auto" must be resolved.
local function resolve_log_defaults(defaults)
  if defaults == nil or defaults.utc ~= "auto" then
    return defaults
  end

  local resolved = {}
  for key, value in pairs(defaults) do
    resolved[key] = value
  end
  resolved.utc = system_utc_offset_minutes()
  return resolved
end

local function apply_new_log(defaults)
  local lines = buffer_lines()
  local result, err = new_log.run(lines, resolve_log_defaults(defaults))
  if not result then
    warn(err)
    return false
  end

  apply_result(result)
  return true
end

-- A loaded, file-backed buffer whose name resolves to `path`, or nil. Report
-- buffers (buftype "nofile", e.g. "daylog-week-2026-W21.day") are skipped so
-- they can never shadow a real daybook file.
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

-- Read a daybook day's lines for reporting. Prefer a loaded buffer for the path
-- so reports reflect unsaved edits; otherwise fall back to the file on disk.
-- Returns nil when neither is available, which the report pipeline treats as an
-- empty day.
local function daybook_lines(path)
  local buf = loaded_buffer_for_path(path)
  if buf then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  if vim.fn.filereadable(path) == 1 then
    return vim.fn.readfile(path)
  end

  return nil
end

-- True when a daybook day already holds log content, considering a loaded
-- (possibly unsaved) buffer before falling back to the file on disk.
local function daybook_path_has_content(path)
  local buf = loaded_buffer_for_path(path)
  if buf then
    return not text.is_empty(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end

  if vim.fn.filereadable(path) == 0 then
    return false
  end

  -- Match the loaded-buffer branch: a whitespace-only file is empty, not content.
  return not text.is_empty(vim.fn.readfile(path))
end

-- Every daybook day that actually holds a daylog: dated `.day` files under the
-- daybook tree (each validated against the configured directory template, so only
-- canonical files count) plus any loaded buffer for a daybook day that currently
-- has content but is not yet written to disk. Returns a list of midday timestamps;
-- nearest_date de-duplicates by date. This file-IO scan is the shell's job.
local function existing_daybook_dates(settings)
  local dates = {}

  -- Trim any trailing slash (an expanded directory root carries one) so the glob
  -- yields single-slash paths that string-match daybook.date_from_path's canonical
  -- form -- a `root//2026/...` would otherwise be rejected as non-canonical.
  local root = (settings.root:gsub("/+$", ""))
  for _, path in ipairs(vim.fn.glob(root .. "/**/*.day", true, true)) do
    local date = daybook.date_from_path(settings, path)
    if date and daybook_path_has_content(path) then
      table.insert(dates, date)
    end
  end

  -- An unsaved new day (seeded today, or a freshly created day) has no file on
  -- disk yet, so pick it up from the buffer list. Report scratch buffers (nofile)
  -- are skipped by the buftype guard.
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

-- The latest daybook date that holds a daylog, or nil when none exist. Resolves an
-- open-ended range end (`FROM..` / `..`); future-dated files count, so an open right end
-- reaches genuinely into the future.
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

  -- Decide from the live buffer, not disk: :edit reuses an existing unsaved
  -- buffer (today seeded but never written, then navigated away and back),
  -- whose content must not be re-seeded. A freshly opened missing/empty file is
  -- an empty buffer and gets the initial header.
  local should_initialize = buffer_is_empty()

  if should_initialize and not apply_new_log(config.get().defaults) then
    return false
  end

  return true, should_initialize
end

-- Open the daybook file for a date for navigation only: never create the
-- directory or file and never write a header. A missing day opens as an empty,
-- unmodified buffer named for that date, so nothing is written to disk and the
-- buffer can be abandoned cleanly.
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
