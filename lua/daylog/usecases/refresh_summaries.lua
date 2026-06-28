local analyze = require("daylog.analyze")
local diagnostics = require("daylog.diagnostics")
local document = require("daylog.document")
local quantize = require("daylog.quantize")
local render = require("daylog.render")
local summary = require("daylog.summary")
local summary_block = require("daylog.summary_block")
local support = require("daylog.usecases.support")
local syntax = require("daylog.syntax")

local M = {}

-- Refresh every valid log's summary so it matches its entries -- creating one
-- where missing -- and report the problems that stop a log from being summarized.
--
-- Edits are conservative: a valid log's summary is created when missing and
-- rewritten when it exists but has drifted from its source; it is never removed. A
-- structurally broken document and currently-invalid logs are left untouched,
-- so editing cannot churn or corrupt output, and an already-current summary yields
-- no edit (which keeps the shell's auto-refresh idempotent and loop-free).
--
-- Warnings are not conservative: an unrefreshed summary is otherwise a silent
-- stall, so run also returns `warnings` for every problem the analyzer can see --
-- a broken or absent header, out-of-order timestamps, an invalid entry, 24:00 not
-- final -- whether or not a summary exists yet. Each warning is { row, message };
-- the shell publishes them as buffer diagnostics so they clear when fixed.

-- Read log-header parameters from a (possibly corrupted) header line: q=, d=,
-- #tag, @location, utc±H -- in any order, ignoring damaged dashes/keyword and junk
-- tokens. Returns the parsed fields and whether the line looked like a header at all
-- (it carried at least one real parameter, or the "entries" keyword fuzzily).
local function read_header_params(raw)
  local fields = {}
  local header_ish = false
  for token in raw:gmatch("%S+") do
    local q = token:match("^q=(%d+)$")
    local d = token:match("^d=(%a+)$")
    local tag = token:match("^#([%w_%-]+)$")
    local location = token:match("^@([%w_%-]+)$")
    local offset = syntax.parse_utc_offset(token)
    if q then
      fields.quantize, header_ish = tonumber(q), true
    elseif d and syntax.DURATION_FORMATS[d] then
      fields.duration, header_ish = d, true
    elseif tag then
      fields.tag, header_ish = tag, true
    elseif location then
      fields.location, header_ish = location, true
    elseif offset then
      fields.offset, header_ish = offset, true
    else
      local dist = summary_block.edit_distance(token, "entries")
      if dist and dist <= 2 then
        header_ish = true
      end
    end
  end
  return fields, header_ish
end

-- The canonical header for a recovered daylog: from the corrupted line's own readable
-- parameters when it still looked like a header, else (obliterated / missing) from the
-- previous log's metadata, else a bare header.
local function rebuilt_header(raw, prev)
  local fields, header_ish = {}, false
  if raw then
    fields, header_ish = read_header_params(raw)
  end
  if header_ish then
    return render.log_header_line(
      fields.tag,
      fields.location,
      fields.offset,
      fields.quantize,
      fields.duration
    )
  end
  if prev then
    return render.log_header_line(
      prev.header_tag,
      prev.header_location,
      prev.header_offset,
      prev.header_quantize_minutes,
      prev.header_duration_format
    )
  end
  return "--- log ---"
end

-- Recover a corrupted or missing log header. A log header damaged so it no
-- longer parses (a mistyped keyword, a dropped dash, an obliterated line) leaves its
-- entries "orphaned" -- not part of any recognized log. For each orphan entry run
-- (always below some summary, in the edit-free zone), reconstruct the next log's
-- header: replace a damaged header line just above the entries (reading back its
-- parameters), or -- when no header line remains -- synthesize one from the previous
-- log's metadata, inserted directly above the entries. Returns 0-based edits (replaces
-- and inserts); the entries themselves are never touched.
local function recover_header_edits(analysis)
  local nodes = analysis.document.nodes
  local total = analysis.document.row_count

  -- Rows of entries that belong to a recognized log (these are already fine).
  local owned = {}
  for _, block in ipairs(analysis.log_blocks) do
    for _, node in ipairs(block.body_nodes or {}) do
      if node.kind == syntax.NODE_KIND.ENTRY then
        owned[node.row] = true
      end
    end
  end

  local function previous_log(before_row)
    local best
    for _, block in ipairs(analysis.log_blocks) do
      if block.start_row < before_row and (not best or block.start_row > best.start_row) then
        best = block
      end
    end
    return best
  end

  local edits = {}
  local row = 1
  while row <= total do
    local node = nodes[row]
    if node and node.kind == syntax.NODE_KIND.ENTRY and not owned[row] then
      -- An orphan entry run starts here. Find the line just above it (skipping blanks).
      local hdr = row - 1
      while hdr >= 1 and nodes[hdr] and nodes[hdr].kind == syntax.NODE_KIND.BLANK_LINE do
        hdr = hdr - 1
      end
      local hdr_raw = (hdr >= 1 and nodes[hdr] and nodes[hdr].raw) or nil
      local hdr_is_summary = hdr_raw ~= nil
        and (syntax.is_infile_summary_header(hdr_raw) or syntax.is_summary_row(hdr_raw))
      local hdr_is_entry = hdr >= 1 and nodes[hdr] and nodes[hdr].kind == syntax.NODE_KIND.ENTRY
      -- Only recover when there is a preceding valid log to anchor on (and to supply
      -- metadata). A document that is all orphan entries -- no log at all -- is a "no
      -- log found" problem the user must fix, not something to fabricate a header for.
      -- A corrupted FIRST header is a structural error and never reaches here. Any line
      -- above an orphan entry run otherwise IS that log's header -- damaged, obliterated,
      -- or an unrelated `--- foo ---` (which carries no semantics) -- so reconstruct it.
      local prev = previous_log(row)
      if prev then
        if hdr_raw == nil or hdr_is_summary or hdr_is_entry then
          -- No header line remains (deleted, or only a summary/entry sits above): synthesize
          -- one from the previous log and insert it directly above the entries.
          edits[#edits + 1] = {
            start_index = row - 1,
            end_index = row - 1,
            lines = { rebuilt_header(nil, prev) },
          }
        else
          -- A corrupted (or obliterated-to-prose) header line above the entries: replace it,
          -- reading back whatever parameters survive (else the previous log's).
          edits[#edits + 1] = {
            start_index = hdr - 1,
            end_index = hdr,
            lines = { rebuilt_header(hdr_raw, prev) },
          }
        end
      end

      -- Skip to the end of this run -- the next `--- ... ---` header (its own summary
      -- banner) or EOF -- so it is reconstructed once.
      row = row + 1
      while
        row <= total and not ((nodes[row] and nodes[row].raw or ""):match("^%-%-%- .* %-%-%-$"))
      do
        row = row + 1
      end
    else
      row = row + 1
    end
  end

  return edits
end

-- A frozen `!L<minutes>` value records what was committed externally, and the
-- quantizer holds the row there. That stays honest only while it still reconciles
-- with the log: a value must be a non-negative multiple of the block's q (else it
-- cannot foot a bucket), and the frozen values together cannot exceed the log's
-- rounded activity total (else there is no budget left for the un-frozen rows). When
-- either breaks -- a q change, an edit inside a logged interval, deleted activity --
-- warn so the user re-runs :DaylogLog to recommit. The summary still renders (the
-- quantizer re-foots honestly around the stale value); this only surfaces the drift.
local function frozen_drift_warnings(block)
  local rows, bucket_minutes = summary.fine_grained_quantized(block.entries, block.quantize_minutes)

  local warnings = {}
  local frozen_total = 0
  local activity_total = 0

  for _, row in ipairs(rows) do
    activity_total = activity_total + (row.unrounded_duration or 0)

    if row.logged_minutes ~= nil then
      frozen_total = frozen_total + row.logged_minutes

      if row.logged_minutes < 0 or row.logged_minutes % bucket_minutes ~= 0 then
        local at = row.source_entry_rows and row.source_entry_rows[1]
        if at then
          warnings[#warnings + 1] = {
            row = at,
            message = string.format(
              "daylog: a frozen !L value no longer fits q=%d; re-run :DaylogLog to recommit",
              bucket_minutes
            ),
          }
        end
      end
    end
  end

  if frozen_total > quantize.round_to_nearest_bucket(activity_total, bucket_minutes) then
    warnings[#warnings + 1] = {
      row = block.start_row,
      message = "daylog: frozen !L values exceed this log's rounded total; re-run :DaylogLog to recommit",
    }
  end

  return warnings
end

-- A manual `round±N` marker is honest only while the row can absorb it. A round-down can be
-- demanded past what the row holds -- typed too large by hand, or left stale by an edit that
-- shrank the activity -- which would carry the displayed duration below zero. The quantizer
-- clamps the display to 0 and records `nudge_below_zero`; surface that as a diagnostic so the
-- out-of-range marker is corrected rather than silently honored. The summary still renders
-- (clamped), mirroring the frozen-drift surfacing above.
local function nudge_range_warnings(block)
  local rows = summary.fine_grained_quantized(block.entries, block.quantize_minutes)

  local warnings = {}
  for _, row in ipairs(rows) do
    if row.nudge_below_zero then
      local at = row.source_entry_rows and row.source_entry_rows[1]
      if at then
        warnings[#warnings + 1] = {
          row = at,
          message = string.format(
            "daylog: round%+d rounds this item below zero; clear or reduce the nudge",
            row.nudge
          ),
        }
      end
    end
  end

  return warnings
end

function M.run(lines)
  local analysis = analyze.analyze(document.parse(lines))

  -- A structurally broken document is never rewritten (so editing cannot churn or
  -- corrupt output) until it parses cleanly again; its problems still warn.
  if analyze.structural_error(analysis) then
    return { edits = {}, warnings = diagnostics.collect(analysis) }
  end

  -- Recover corrupted/missing log headers first, on a working copy, then re-analyze
  -- so the recovered logs are summarized in this same pass (keeping refresh
  -- idempotent). Recovery edits are applied highest-row-first; a synthesized header is an
  -- insertion, so the summary edits are computed in the WORKING copy's coordinates and
  -- emitted after all recovery edits (the shell applies the list in order).
  local recover_edits = recover_header_edits(analysis)
  table.sort(recover_edits, function(a, b)
    return a.start_index > b.start_index
  end)
  local work, work_analysis = lines, analysis
  if #recover_edits > 0 then
    work = support.apply_edits(lines, recover_edits)
    work_analysis = analyze.analyze(document.parse(work))
  end

  local warnings = diagnostics.collect(work_analysis)
  local summary_edits = {}

  for _, block in ipairs(work_analysis.log_blocks) do
    -- For a valid daylog: blast-regenerate its whole summary zone, or create one when
    -- missing. The summary is entirely generated, so the located zone is discarded
    -- wholesale and rewritten -- nothing inside it is authored -- while the body above
    -- the boundary is left untouched.
    if not analyze.find_block_diagnostic(work_analysis, block) then
      for _, warning in ipairs(frozen_drift_warnings(block)) do
        warnings[#warnings + 1] = warning
      end

      for _, warning in ipairs(nudge_range_warnings(block)) do
        warnings[#warnings + 1] = warning
      end

      for _, conflict in ipairs(summary.logged_value_conflicts(block.entries)) do
        warnings[#warnings + 1] = {
          row = conflict.row,
          message = "daylog: logged entries for this activity disagree on their "
            .. "!L value; re-run :DaylogLog to recommit",
        }
      end

      -- Rebuild this valid log's summary from its entries -- creating one when missing --
      -- through the one canonical zone writer. An already-canonical zone yields no edit.
      local edit = support.summary_zone_edit(work, work_analysis, block, block.entries, true)
      if edit then
        table.insert(summary_edits, edit)
      end
    end
  end

  table.sort(summary_edits, function(a, b)
    return a.start_index > b.start_index
  end)

  -- Recovery edits transform `lines` -> `work`; the summary edits are in `work`
  -- coordinates. The shell applies the list in order, so every recovery (which may insert
  -- a line) runs before any summary edit, keeping both coordinate systems valid.
  local edits = {}
  for _, edit in ipairs(recover_edits) do
    edits[#edits + 1] = edit
  end
  for _, edit in ipairs(summary_edits) do
    edits[#edits + 1] = edit
  end

  return { edits = edits, warnings = warnings }
end

return M
