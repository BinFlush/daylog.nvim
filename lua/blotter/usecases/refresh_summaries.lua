local analyze = require("blotter.analyze")
local body = require("blotter.body")
local diagnostics = require("blotter.diagnostics")
local document = require("blotter.document")
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
-- render), so the separator is normalized however a border edit mangled it.
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
local function canonical_edit(lines, body_end, zone_end, content)
  local want = {}
  for _, line in ipairs(SEPARATOR) do
    want[#want + 1] = line
  end
  for _, line in ipairs(content) do
    want[#want + 1] = line
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

function M.run(lines)
  local analysis = analyze.analyze(document.parse(lines))
  local warnings = diagnostics.collect(analysis)
  local edits = {}

  -- A structurally broken document is never rewritten (so editing cannot churn
  -- or corrupt output) until it parses cleanly again; its problems still warn
  -- via diagnostics.collect above.
  if not analyze.structural_error(analysis) then
    for _, block in ipairs(analysis.blotter_blocks) do
      -- For a valid blotter: blast-regenerate its whole summary zone, or create one
      -- when missing. The summary is entirely generated, so the located zone (banner
      -- to next blotter / EOF) is discarded wholesale and rewritten -- nothing inside
      -- it is authored -- while the body above the boundary is left untouched.
      if not analyze.find_block_diagnostic(analysis, block) then
        local region, _, content = support.locate_summary(analysis, block)

        local body_end, zone_end
        if region then
          -- Blast the located zone, sweeping trailing body blanks above its boundary
          -- into the replacement so the separator is regenerated canonically too.
          body_end = body_end_above(lines, block, region.start_row)
          zone_end = region.end_row
        else
          -- No summary yet: create one after the body. The blotter block spans its
          -- trailing blanks, so blast from the last content line to the block end and
          -- re-emit the separator + summary, replacing any stray trailing blanks.
          body_end = body.last_content_row(block)
          local _, stop = support.summary_zone_bounds(analysis, block)
          zone_end = stop
        end

        local edit, already_canonical = canonical_edit(lines, body_end, zone_end, content)
        if not already_canonical then
          table.insert(edits, edit)
        end
      end
    end

    -- Apply highest-row-first so multiple region replacements do not shift each
    -- other's indices.
    table.sort(edits, function(a, b)
      return a.start_index > b.start_index
    end)
  end

  return { edits = edits, warnings = warnings }
end

return M
