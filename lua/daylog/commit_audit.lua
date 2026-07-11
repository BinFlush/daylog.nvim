local analyze = require("daylog.analyze")
local daybook = require("daylog.daybook")
local document = require("daylog.document")
local refresh_summaries = require("daylog.usecases.refresh_summaries")
local text = require("daylog.text")

local M = {}

-- Classify a git commit's changes to `.day` files by their time-tracking impact (PURE). A commit that
-- only edits notes (or regenerates a summary) is `notes`; one that changes the active log's entries on
-- the commit's own day is `today`; one that changes them on any OTHER day is `other-day` -- the case
-- worth review. Fingerprints the ACTIVE (latest) `--- log ---`
-- block only; earlier logs, notes, and the generated summary are ignored. Used by scripts/commit-audit.lua.

local FIELD_SEP = "\31" -- unit separator: never appears in daylog text
local LOGGED_SEP = "\30"

-- Serialize an entry's logged markers deterministically (level -> { minutes, names }).
local function serialize_logged(logged)
  if logged == nil then
    return ""
  end
  local levels = {}
  for level in pairs(logged) do
    levels[#levels + 1] = level
  end
  table.sort(levels)
  local parts = {}
  for _, level in ipairs(levels) do
    local marker = logged[level]
    parts[#parts + 1] = level
      .. "="
      .. tostring(marker.minutes or "")
      .. ":"
      .. table.concat(marker.names or {}, ",")
  end
  return table.concat(parts, LOGGED_SEP)
end

-- The reporting-relevant identity of a single entry: its time, resolved text/tag/location/offset,
-- rounding nudge, alias, and logged state. Excludes the source row so a pure move up/down the file
-- (which does not change the run of intervals) is not itself a difference.
local function serialize_entry(entry)
  return table.concat({
    tostring(entry.minutes or ""),
    entry.text or "",
    entry.tag or "",
    entry.location or "",
    tostring(entry.offset or ""),
    tostring(entry.nudge or ""),
    entry.alias or "",
    serialize_logged(entry.logged),
  }, FIELD_SEP)
end

-- A canonical fingerprint of the ACTIVE log's entries, in order. Empty when the file has no log block
-- (a pure-notes day). Reorders/edits/adds/removals of active entries all change it; whitespace- or
-- note-only edits do not, because entry `.text` is normalized and notes live outside `.entries`.
function M.active_log_fingerprint(lines)
  local analysis = analyze.analyze(document.parse(lines))
  local active = analyze.get_active_log(analysis)
  if not active then
    return ""
  end
  local parts = {}
  for _, entry in ipairs(active.entries) do
    parts[#parts + 1] = serialize_entry(entry)
  end
  return table.concat(parts, "\n")
end

-- The buffer-visible warnings for a committed file, as { row, message }: the SAME set refresh_summaries
-- publishes as diagnostics -- structural problems, footing/logging conflicts, and nudge clamps, across
-- EVERY log block (active or not). A file that crashes the summarizer is itself the worst corruption, so
-- a throw counts as a warning too. Used to flag a committed log left broken.
local function file_warnings(lines)
  if text.is_empty(lines) then
    return {}
  end
  local ok, result = pcall(refresh_summaries.run, lines)
  if not ok then
    return { { row = 1, message = "daylog: summarizer failed: " .. tostring(result) } }
  end
  return result.warnings
end

local function basename(path)
  return path:match("[^/\\]+$") or path
end

-- The calendar day a `.day` path belongs to (`YYYY-MM-DD`), or nil when the name is not `YYYY-MM-DD.day`.
local function day_of_path(path)
  local timestamp = daybook.parse_date_label(basename(path))
  if not timestamp then
    return nil
  end
  return daybook.date_label(timestamp)
end

local function append_unique(list, seen, value)
  if not seen[value] then
    seen[value] = true
    list[#list + 1] = value
  end
end

-- Classify a commit from its changed `.day` files. `files` is a list of { path, old_lines, new_lines }
-- (missing sides default to empty, so an add/delete is handled). `commit_date` is the commit's local
-- day (`YYYY-MM-DD`). Returns:
--   { classification = "notes" | "today" | "other-day",
--     log_days       = { day, ... },   -- days whose active log changed (sorted)
--     other_days     = { day, ... },   -- the subset that is not `commit_date`
--     needs_review   = boolean,        -- a committed file carries a warning (any log block)
--     reasons        = { "<path>: <reason>", ... } }
function M.classify(files, commit_date)
  local log_days, log_seen = {}, {}
  local other_days, other_seen = {}, {}
  local reasons = {}
  local needs_review = false

  for _, file in ipairs(files) do
    local day = day_of_path(file.path)
    if day then
      local old_lines = file.old_lines or {}
      local new_lines = file.new_lines or {}
      if M.active_log_fingerprint(old_lines) ~= M.active_log_fingerprint(new_lines) then
        append_unique(log_days, log_seen, day)
        if day ~= commit_date then
          append_unique(other_days, other_seen, day)
          reasons[#reasons + 1] = file.path .. ": log changed for " .. day
        end
      end

      -- Flag a committed file left with any warning regardless of the active-log fingerprint -- a broken
      -- earlier (non-active) log, a footing/logging conflict, or a diagnostic-introducing note still
      -- deserves review. Reads the buffer's warning source, so it spans every log block in the file.
      local warnings = file_warnings(new_lines)
      if #warnings > 0 then
        needs_review = true
        reasons[#reasons + 1] = file.path .. ": committed with a warning -- " .. warnings[1].message
      end
    end
  end

  table.sort(log_days)
  table.sort(other_days)

  local classification = "notes"
  if #other_days > 0 then
    classification = "other-day"
  elseif #log_days > 0 then
    classification = "today"
  end

  return {
    classification = classification,
    log_days = log_days,
    other_days = other_days,
    needs_review = needs_review,
    reasons = reasons,
  }
end

return M
