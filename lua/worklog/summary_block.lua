local syntax = require("worklog.syntax")

local M = {}

-- Locator for a worklog's generated summary region.
--
-- A worklog has at most one summary, and it is derived output -- always exactly
-- `render(summarize(entries))`. Rather than recognize summary header strings (which
-- break the moment a header is edited or deleted), this module aligns the freshly
-- rendered expected summary against the worklog's tail -- a Needleman-Wunsch fitting
-- alignment (see `fit_align`) -- and reports the best-matching span. That keeps it
-- format-agnostic -- nothing here changes when the summary layout
-- does -- and lets the summary usecases rewrite an edited or partly deleted summary in
-- place: a mangled header or a deleted row is folded into the matched span. It owns no
-- presentation or reporting logic.

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

-- Locate `worklog_block`'s generated summary by aligning `expected_lines` (the freshly
-- rendered summary) against the worklog's tail. Returns { start_row, end_row } (1-based,
-- end_row exclusive) when enough of the summary is present to be sure it is this
-- summary, or nil when there is none to rewrite.
function M.find(analysis, worklog_block, expected_lines)
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

-- Exposed for direct unit testing of the alignment.
M.fit_align = fit_align

return M
