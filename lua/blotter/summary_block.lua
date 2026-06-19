local syntax = require("blotter.syntax")

local M = {}

-- Locator for a worklog's generated summary region.
--
-- A worklog has at most one summary, and it is derived output -- always exactly
-- `render(summarize(entries))`. The region is located two ways and the union is
-- returned, so each covers the other's blind spot:
--
--   * Content alignment (`align_find`, a Needleman-Wunsch fitting alignment, see
--     `fit_align`): line up the freshly rendered expected summary against the
--     worklog's tail. Format-agnostic and tolerant of edits -- a mangled header or
--     a deleted row is folded into the matched span -- but it needs a few
--     distinctive lines to anchor, so it fails when the fresh summary is nearly
--     empty (a worklog with no completed interval).
--   * Structural recognition (`structural_find`): the contiguous run of generated
--     summary lines in the tail -- section headers (`syntax.is_summary_section_header`)
--     and `<duration> (+Nm)` rows -- separated by blanks. This finds an empty
--     summary (the headers are still there) and, crucially, spans a *jumble* of
--     duplicated/stale generated sections so a refresh collapses them into one,
--     while stopping at the first real note so trailing prose is preserved.
--
-- Taking the union means a clean summary resolves identically to before, an
-- edited/partly-deleted one is still found by alignment, and an empty or
-- duplicated one is found (and collapsed) structurally. It owns no presentation or
-- reporting logic.

-- Needleman-Wunsch fitting alignment (a.k.a. semi-global): line up *all* of `expected`
-- against a contiguous span of `actual`, with the actual prefix and suffix outside the
-- span free (free end gaps). The classic edit-distance DP -- an (m+1)x(n+1) cost matrix
-- filled with match/substitute, delete (an expected line absent from actual) and insert
-- (an extra actual line); its minimum-cost path locates where the rendered summary sits
-- in the worklog's tail even after edits. Returns { start, stop, matches } (1-based,
-- inclusive bounds; `matches` = exact non-blank line matches) or nil when nothing
-- aligns. Substitution/match is preferred over deletion on ties so an edited boundary
-- line (a mangled header) stays inside the span; the caller trims boundary blanks so a
-- deleted header's separator blank stays outside it.
local function fit_align(expected, actual)
  local m, n = #expected, #actual
  if m == 0 then
    return nil
  end

  -- Score = edit-cost * `miss` minus non-blank exact matches, so the DP minimizes edit
  -- cost first and then *maximizes distinctive matches* (a non-blank match scores -1, a
  -- blank match 0, any edit `miss` > m). Maximizing matches keeps an exactly-matchable
  -- line a match rather than a substitution of a neighbour (which would drop it from the
  -- span and duplicate it on rewrite); counting only *non-blank* matches stops a run of
  -- blank lines from anchoring the span over the worklog body.
  local miss = m + 1
  local dp = {}
  for a = 0, m do
    dp[a] = {}
    for b = 0, n do
      if a == 0 then
        dp[a][b] = 0 -- empty expected: the actual prefix is free
      elseif b == 0 then
        dp[a][b] = a * miss -- expected[1..a] all deleted
      else
        local diag
        if expected[a] == actual[b] then
          diag = dp[a - 1][b - 1] + (expected[a] ~= "" and -1 or 0) -- match (blanks unrewarded)
        else
          diag = dp[a - 1][b - 1] + miss -- substitution
        end
        local del = dp[a - 1][b] + miss -- expected[a] absent from actual
        local ins = dp[a][b - 1] + miss -- extra actual line inside the span
        dp[a][b] = math.min(diag, del, ins)
      end
    end
  end

  -- Largest end column reaching the minimum score: a stale trailing row (a
  -- substitution of the last expected line) is kept inside the span and rewritten,
  -- while genuine trailing junk -- which only adds edits, raising the score -- stays
  -- outside it.
  local stop, best = 0, math.huge
  for b = 0, n do
    if dp[m][b] <= best then
      best = dp[m][b]
      stop = b
    end
  end
  if stop == 0 then
    return nil
  end

  -- Backtrack to the span start, counting non-blank matches. Order: exact match,
  -- substitution, deletion, insertion -- so a mismatched boundary is kept as a
  -- substitution (inside the span) rather than dropped via a deletion.
  local a, b, matches = m, stop, 0
  while a > 0 do
    if
      b > 0
      and expected[a] == actual[b]
      and dp[a][b] == dp[a - 1][b - 1] + (expected[a] ~= "" and -1 or 0)
    then
      if expected[a] ~= "" then
        matches = matches + 1
      end
      a, b = a - 1, b - 1
    elseif b > 0 and dp[a][b] == dp[a - 1][b - 1] + miss then
      a, b = a - 1, b - 1 -- substitution
    elseif dp[a][b] == dp[a - 1][b] + miss then
      a = a - 1 -- deletion
    else
      b = b - 1 -- insertion
    end
  end

  return { start = b + 1, stop = stop, matches = matches }
end

-- The alignment window: from just after the worklog's last timestamped entry to the
-- next worklog header / EOF. Anchoring the window past the entries is a hard guarantee
-- that they can never be drawn into the matched span and rewritten away -- the summary
-- always follows the entries, and a deleted summary header only leaks its rows in as
-- notes, which still sit after the last entry.
local function tail_bounds(analysis, worklog_block)
  local blocks = analysis.blocks
  local start_index
  for index, block in ipairs(blocks) do
    if block == worklog_block then
      start_index = index
      break
    end
  end
  if not start_index then
    return nil
  end

  local tail_start = worklog_block.body_start_row
  for _, node in ipairs(worklog_block.body_nodes or {}) do
    if node.kind == syntax.NODE_KIND.ENTRY then
      tail_start = node.row + 1
    end
  end

  local stop_row = analysis.document.row_count + 1
  for index = start_index + 1, #blocks do
    if blocks[index].kind == syntax.BLOCK_KIND.WORKLOG then
      stop_row = blocks[index].start_row
      break
    end
  end

  return tail_start, stop_row
end

-- Locate the summary by aligning `expected_lines` (the freshly rendered summary)
-- against the worklog's tail. Returns { start_row, end_row } (1-based, end_row
-- exclusive) or nil. Strong against edits, weak when `expected_lines` is nearly
-- empty (too few distinctive lines to anchor).
local function align_find(analysis, worklog_block, expected_lines)
  if not expected_lines or #expected_lines == 0 then
    return nil
  end

  local tail_start, stop_row = tail_bounds(analysis, worklog_block)
  if not tail_start then
    return nil
  end

  local nodes = analysis.document.nodes
  local actual = {}
  for row = tail_start, stop_row - 1 do
    actual[#actual + 1] = (nodes[row] and nodes[row].raw) or ""
  end

  local span = fit_align(expected_lines, actual)
  if not span then
    return nil
  end

  -- The rendered summary never starts or ends with a blank, so trim any boundary
  -- blanks the alignment pulled in (e.g. the separator above a header-less summary).
  while span.start <= span.stop and actual[span.start] == "" do
    span.start = span.start + 1
  end
  while span.stop >= span.start and actual[span.stop] == "" do
    span.stop = span.stop - 1
  end

  -- Confirm it is this summary, not unrelated tail content: at least two non-blank
  -- lines must align exactly. Two distinctive summary lines (a header and a row, say)
  -- are enough to be sure, and a partial summary -- e.g. one whose totals were
  -- deleted -- still clears this, so it is recognized and completed in place.
  if span.stop < span.start or span.matches < 2 then
    return nil
  end

  return {
    start_row = tail_start + span.start - 1,
    end_row = tail_start + span.stop,
  }
end

-- Locate the summary as the contiguous run of generated summary sections in the
-- worklog's tail. The run is *anchored* on the first bare in-file summary header
-- (the banner or a bare tags/locations/logged/totals). A generated section runs
-- from its header to the next blank line, and *every* line in between belongs to
-- the summary -- a `(+Nm)` row or junk left inside the section alike -- so a refresh
-- rewrites the whole section and regenerates any stray content away. A blank ends
-- the section; the next non-blank line continues the run only if it is another
-- section header. So a line after a blank that is not a header is a free note and
-- ends the run (kept), as does the next worklog or EOF. Anchoring on a header (not a
-- lone row) keeps a leaked summary-shaped note from starting a run; a genuinely
-- deleted header is recovered by content alignment instead. This finds an empty
-- summary (its headers survive), spans a jumble of duplicated or stale sections, and
-- pulls in junk sitting inside a section, while leaving prose after the summary out.
local function structural_find(analysis, worklog_block)
  local tail_start, stop_row = tail_bounds(analysis, worklog_block)
  if not tail_start then
    return nil
  end

  local nodes = analysis.document.nodes
  local start, stop, in_section
  for row = tail_start, stop_row - 1 do
    local raw = (nodes[row] and nodes[row].raw) or ""
    if syntax.is_infile_summary_header(raw) then
      start = start or row
      stop = row
      in_section = true
    elseif raw == "" then
      -- A blank ends a section's rows; the next non-blank must be a header to continue.
      in_section = false
    elseif start and in_section then
      -- Any line inside a section belongs to the summary, so a refresh rewrites it.
      stop = row
    elseif start then
      -- A non-blank line after a blank that is not a header is a free note: leave it.
      break
    end
  end

  if not start then
    return nil
  end

  return { start_row = start, end_row = stop + 1 }
end

-- Locate `worklog_block`'s generated summary region, returning { start_row,
-- end_row } (1-based, end_row exclusive) or nil. The union of content alignment
-- and structural recognition (see the module comment): alignment handles edited
-- summaries, structural recognition handles empty ones and collapses a jumble of
-- duplicated/stale generated sections into the single region a refresh rewrites.
function M.find(analysis, worklog_block, expected_lines)
  local aligned = align_find(analysis, worklog_block, expected_lines)
  local structural = structural_find(analysis, worklog_block)

  if not aligned then
    return structural
  end
  if not structural then
    return aligned
  end

  return {
    start_row = math.min(aligned.start_row, structural.start_row),
    end_row = math.max(aligned.end_row, structural.end_row),
  }
end

-- Exposed for direct unit testing of the alignment.
M.fit_align = fit_align

return M
