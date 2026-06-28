local render = require("daylog.render")
local summary_block = require("daylog.summary_block")
local syntax = require("daylog.syntax")

local M = {}

-- Log-header recovery (PURE).
--
-- A log header damaged so it no longer parses -- a mistyped keyword, a dropped dash, an
-- obliterated or deleted line -- leaves its entries "orphaned": part of no recognized log, and
-- so never summarized. This use case reconstructs the missing/corrupted header for each orphan
-- run, reading back whatever parameters survive on a damaged line, or synthesizing one from the
-- previous log's metadata. It returns 0-based edits (replaces and inserts) and never touches the
-- entries; refresh_summaries applies them on a working copy, re-analyzes, then summarizes the
-- now-recognized logs in the same idempotent pass.

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
function M.edits(analysis)
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

return M
