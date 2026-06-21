local analyze = require("blotter.analyze")
local body = require("blotter.body")
local diagnostics = require("blotter.diagnostics")
local document = require("blotter.document")
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

-- Recover a one-character-corrupted blotter header. A `--- blots ... ---` whose keyword
-- was lightly damaged (e.g. `--- blts q=15 d=dec ---`) no longer parses as a blotter --
-- it becomes a generic `--- ... ---` block, and without recovery its blots go
-- un-summarized. When such a generic block CONTAINS blots and its keyword is within edit
-- distance of "blots" (so a real `--- notes ---` is never mistaken for one), it is a
-- corrupted blotter header: fix just the keyword, preserving the header's options
-- verbatim, so the blotter is recognized and summarized again. Returns 0-based replace
-- edits (one per recovered header); the options/dashes are otherwise untouched.
local function recover_header_edits(lines, analysis)
  local edits = {}
  for _, block in ipairs(analysis.blocks) do
    if block.kind == syntax.BLOCK_KIND.GENERIC then
      local has_blot = false
      for _, node in ipairs(block.body_nodes or {}) do
        if node.kind == syntax.NODE_KIND.BLOT then
          has_blot = true
          break
        end
      end

      local raw = lines[block.start_row] or ""
      local content = has_blot and raw:match("^%-%-%- (.+) %-%-%-$")
      local keyword = content and content:match("^(%S+)")
      if keyword and keyword ~= "blots" then
        local dist = summary_block.edit_distance(keyword, "blots")
        if dist and dist <= 2 then
          local fixed = "--- blots" .. content:sub(#keyword + 1) .. " ---"
          if fixed ~= raw then
            edits[#edits + 1] = {
              start_index = block.start_row - 1,
              end_index = block.start_row,
              lines = { fixed },
            }
          end
        end
      end
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

  -- Recover lightly-corrupted blotter headers first, on a working copy, then re-analyze
  -- so the recovered blotters are summarized in this same pass (keeping refresh
  -- idempotent). The recovery edits are single-line replacements (no row shift), so the
  -- summary edits below stay valid in the original coordinates.
  local recover_edits = recover_header_edits(lines, analysis)
  local work, work_analysis = lines, analysis
  if #recover_edits > 0 then
    work = apply_edits(lines, recover_edits)
    work_analysis = analyze.analyze(document.parse(work))
  end

  local warnings = diagnostics.collect(work_analysis)
  local edits = {}

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
        table.insert(edits, edit)
      end
    end
  end

  for _, edit in ipairs(recover_edits) do
    table.insert(edits, edit)
  end

  -- Apply highest-row-first so multiple region replacements do not shift each other's
  -- indices. Recovery edits are row-preserving replacements, so they compose with the
  -- summary edits in these original coordinates.
  table.sort(edits, function(a, b)
    return a.start_index > b.start_index
  end)

  return { edits = edits, warnings = warnings }
end

return M
