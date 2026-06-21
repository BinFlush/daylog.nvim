local analyze = require("blotter.analyze")
local body = require("blotter.body")
local diagnostics = require("blotter.diagnostics")
local document = require("blotter.document")
local render = require("blotter.render")
local summary_block = require("blotter.summary_block")
local support = require("blotter.usecases.support")
local syntax = require("blotter.syntax")

local M = {}

-- Refresh every valid blotter's summary so it matches its blots -- creating one
-- where missing -- and report the problems that stop a blotter from being summarized.
--
-- Edits are conservative: a valid blotter's summary is created when missing and
-- rewritten when it exists but has drifted from its source; it is never removed. A
-- structurally broken document and currently-invalid blotters are left untouched,
-- so editing cannot churn or corrupt output, and an already-current summary yields
-- no edit (which keeps the shell's auto-refresh idempotent and loop-free).
--
-- Warnings are not conservative: an unrefreshed summary is otherwise a silent
-- stall, so run also returns `warnings` for every problem the analyzer can see --
-- a broken or absent header, out-of-order timestamps, an invalid blot, 24:00 not
-- final -- whether or not a summary exists yet. Each warning is { row, message };
-- the shell publishes them as buffer diagnostics so they clear when fixed.

-- The blast layout: the body, then exactly two blank separator lines, then the
-- content-only summary render. The two blanks are emitted by the blast (not by the
-- render), so the separator is normalized however a border edit mangled it. When
-- another blotter follows, the same two blanks are emitted as a trailing separator so
-- stacked blotters stay two blanks apart; at EOF none are added.
local SEPARATOR = { "", "" }

-- The block's last timestamped blot row, or its header row when blot-less. The hard
-- floor for the body/summary boundary search: everything below the last blot is
-- either a note or generated summary, so the boundary never sweeps past it into a
-- blot, even when a deleted banner left the summary rows parsed as body notes (which
-- would push body.last_content_row down into the generated zone).
local function last_blot_row(block)
  local row = block.start_row
  for _, node in ipairs(block.body_nodes or {}) do
    if node.kind == syntax.NODE_KIND.BLOT then
      row = node.row
    end
  end
  return row
end

-- The body's last line: the last authored (prose or blot) line above the summary.
-- Scanned UPWARD from just above the summary boundary, skipping blank lines and
-- generated-shaped lines (the separator blanks, and any stranded summary row -- e.g. a
-- yanked row pasted flush under the last blot). So the body keeps every authored note,
-- whether it sits flush under a blot or is separated from it by a blank, while blanks
-- and stranded generated debris below the last note are swept into the blast. Floored
-- at the last blot row, so a blot is never crossed even when a deleted banner left
-- summary rows parsed as body notes.
local function body_end_above(lines, block, start_row)
  local floor = last_blot_row(block)
  for row = start_row - 1, floor + 1, -1 do
    local raw = lines[row] or ""
    if
      raw ~= ""
      and not syntax.is_infile_summary_header(raw)
      and not syntax.is_summary_row(raw)
    then
      return row
    end
  end
  return floor
end

-- The 0-based edit replacing [body_end .. zone_end) with the canonical separator +
-- content, true when that zone is already exactly canonical (so no edit is emitted).
local function canonical_edit(lines, body_end, zone_end, content, trailing)
  local want = {}
  for _, line in ipairs(SEPARATOR) do
    want[#want + 1] = line
  end
  for _, line in ipairs(content) do
    want[#want + 1] = line
  end
  if trailing then
    for _, line in ipairs(SEPARATOR) do
      want[#want + 1] = line
    end
  end

  local matches = (zone_end - 1 - body_end) == #want
  if matches then
    for index, line in ipairs(want) do
      if lines[body_end + index] ~= line then
        matches = false
        break
      end
    end
  end

  return {
    start_index = body_end,
    end_index = zone_end - 1,
    lines = want,
  }, matches
end

-- Apply a list of replace edits (0-based, disjoint, sorted highest-first) to a line
-- list -- the pure mirror of the buffer apply, used internally to build the repaired
-- copy before re-analyzing.
local function apply_edits(lines, edits)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line
  end
  for _, edit in ipairs(edits) do
    local next_out = {}
    for i = 1, edit.start_index do
      next_out[#next_out + 1] = out[i]
    end
    for _, line in ipairs(edit.lines) do
      next_out[#next_out + 1] = line
    end
    for i = edit.end_index + 1, #out do
      next_out[#next_out + 1] = out[i]
    end
    out = next_out
  end
  return out
end

-- Read blotter-header parameters from a (possibly corrupted) header line: q=, d=,
-- #tag, @location, utc±H -- in any order, ignoring damaged dashes/keyword and junk
-- tokens. Returns the parsed fields and whether the line looked like a header at all
-- (it carried at least one real parameter, or the "blots" keyword fuzzily).
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
      local dist = summary_block.edit_distance(token, "blots")
      if dist and dist <= 2 then
        header_ish = true
      end
    end
  end
  return fields, header_ish
end

-- The canonical header for a recovered blotter: from the corrupted line's own readable
-- parameters when it still looked like a header, else (obliterated / missing) from the
-- previous blotter's metadata, else a bare header.
local function rebuilt_header(raw, prev)
  local fields, header_ish = {}, false
  if raw then
    fields, header_ish = read_header_params(raw)
  end
  if header_ish then
    return render.blotter_header_line(
      fields.tag,
      fields.location,
      fields.offset,
      fields.quantize,
      fields.duration
    )
  end
  if prev then
    return render.blotter_header_line(
      prev.header_tag,
      prev.header_location,
      prev.header_offset,
      prev.header_quantize_minutes,
      prev.header_duration_format
    )
  end
  return "--- blots ---"
end

-- Recover a corrupted or missing blotter header. A blotter header damaged so it no
-- longer parses (a mistyped keyword, a dropped dash, an obliterated line) leaves its
-- blots "orphaned" -- not part of any recognized blotter. For each orphan blot run
-- (always below some summary, in the edit-free zone), reconstruct the next blotter's
-- header: replace a damaged header line just above the blots (reading back its
-- parameters), or -- when no header line remains -- synthesize one from the previous
-- blotter's metadata, inserted directly above the blots. Returns 0-based edits (replaces
-- and inserts); the blots themselves are never touched.
local function recover_header_edits(analysis)
  local nodes = analysis.document.nodes
  local total = analysis.document.row_count

  -- Rows of blots that belong to a recognized blotter (these are already fine).
  local owned = {}
  for _, block in ipairs(analysis.blotter_blocks) do
    for _, node in ipairs(block.body_nodes or {}) do
      if node.kind == syntax.NODE_KIND.BLOT then
        owned[node.row] = true
      end
    end
  end

  local function previous_blotter(before_row)
    local best
    for _, block in ipairs(analysis.blotter_blocks) do
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
    if node and node.kind == syntax.NODE_KIND.BLOT and not owned[row] then
      -- An orphan blot run starts here. Find the line just above it (skipping blanks).
      local hdr = row - 1
      while hdr >= 1 and nodes[hdr] and nodes[hdr].kind == syntax.NODE_KIND.BLANK_LINE do
        hdr = hdr - 1
      end
      local hdr_raw = (hdr >= 1 and nodes[hdr] and nodes[hdr].raw) or nil
      local hdr_is_summary = hdr_raw ~= nil
        and (syntax.is_infile_summary_header(hdr_raw) or syntax.is_summary_row(hdr_raw))
      local hdr_is_blot = hdr >= 1 and nodes[hdr] and nodes[hdr].kind == syntax.NODE_KIND.BLOT
      local hdr_is_block = hdr_raw ~= nil and hdr_raw:match("^%-%-%- .* %-%-%-$") ~= nil
      local hdr_header_ish = false
      if hdr_raw then
        local _, header_ish = read_header_params(hdr_raw)
        hdr_header_ish = header_ish
      end

      -- Only recover when there is a preceding valid blotter to anchor on (and to
      -- supply metadata). A document that is all orphan blots -- no blotter at all -- is
      -- a "no blotter found" problem the user must fix, not something to fabricate a
      -- header for. A corrupted FIRST header is a structural error and never reaches here.
      -- A deliberate foreign section (e.g. `--- notes ---`) that merely happens to contain
      -- blot-shaped lines is NOT a corrupted blots header -- a `--- ... ---` line with
      -- neither a fuzzy "blots" keyword nor any blots parameter -- so it is left alone.
      local foreign_section = hdr_is_block and not hdr_header_ish

      local prev = previous_blotter(row)
      if prev and not foreign_section then
        if hdr_raw == nil or hdr_is_summary or hdr_is_blot then
          -- No header line remains (deleted, or only a summary/blot sits above): synthesize
          -- one from the previous blotter and insert it directly above the blots.
          edits[#edits + 1] = {
            start_index = row - 1,
            end_index = row - 1,
            lines = { rebuilt_header(nil, prev) },
          }
        else
          -- A corrupted (or obliterated-to-prose) header line above the blots: replace it,
          -- reading back whatever parameters survive (else the previous blotter's).
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

function M.run(lines)
  local analysis = analyze.analyze(document.parse(lines))

  -- A structurally broken document is never rewritten (so editing cannot churn or
  -- corrupt output) until it parses cleanly again; its problems still warn.
  if analyze.structural_error(analysis) then
    return { edits = {}, warnings = diagnostics.collect(analysis) }
  end

  -- Recover corrupted/missing blotter headers first, on a working copy, then re-analyze
  -- so the recovered blotters are summarized in this same pass (keeping refresh
  -- idempotent). Recovery edits are applied highest-row-first; a synthesized header is an
  -- insertion, so the summary edits are computed in the WORKING copy's coordinates and
  -- emitted after all recovery edits (the shell applies the list in order).
  local recover_edits = recover_header_edits(analysis)
  table.sort(recover_edits, function(a, b)
    return a.start_index > b.start_index
  end)
  local work, work_analysis = lines, analysis
  if #recover_edits > 0 then
    work = apply_edits(lines, recover_edits)
    work_analysis = analyze.analyze(document.parse(work))
  end

  local warnings = diagnostics.collect(work_analysis)
  local summary_edits = {}

  for _, block in ipairs(work_analysis.blotter_blocks) do
    -- For a valid blotter: blast-regenerate its whole summary zone, or create one when
    -- missing. The summary is entirely generated, so the located zone is discarded
    -- wholesale and rewritten -- nothing inside it is authored -- while the body above
    -- the boundary is left untouched.
    if not analyze.find_block_diagnostic(work_analysis, block) then
      local region, _, content = support.locate_summary(work_analysis, block)

      local body_end, zone_end
      if region then
        -- Blast the located zone, sweeping trailing body blanks above its boundary
        -- into the replacement so the separator is regenerated canonically too.
        body_end = body_end_above(work, block, region.start_row)
        zone_end = region.end_row
      else
        -- No summary yet: create one after the body. The blotter block spans its
        -- trailing blanks, so blast from the last content line to the block end and
        -- re-emit the separator + summary, replacing any stray trailing blanks.
        body_end = body.last_content_row(block)
        local _, stop = support.summary_zone_bounds(work_analysis, block)
        zone_end = stop
      end

      -- Another blotter follows when the zone ends at its header rather than EOF
      -- (zone_end points past the last line only at EOF). Keep the canonical two-blank
      -- separator between this summary and that next blotter.
      local trailing = zone_end <= #work
      local edit, already_canonical = canonical_edit(work, body_end, zone_end, content, trailing)
      if not already_canonical then
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
