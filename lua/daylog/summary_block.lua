local syntax = require("daylog.syntax")

local M = {}

-- Locator for a log's generated summary region -- the banner-delimited blast (PURE).
--
-- The summary is ENTIRELY generated and owns everything from its banner down to the next log / EOF;
-- the locator's whole job is to find the TOP BOUNDARY (the banner) and return [boundary .. next-
-- log/EOF), tried exact, then mangled (nearest tail line by edit distance, guarded), then by shape
-- (first surviving summary row/section header), else nil. The window is anchored past the last
-- entry, a hard guarantee that an entry can never be drawn into the zone and rewritten away.

-- Cap on the alignment DP (rows*cols); bounds the worst case, never hit in practice.
local MAX_ALIGN_CELLS = 1e6

-- Character-level edit distance (unit costs), rolling two rows so the space is O(min length).
-- Returns the distance, or nil when the DP would exceed MAX_ALIGN_CELLS (caller falls back).
local function edit_distance(a, b)
  local la, lb = #a, #b
  if (la + 1) * (lb + 1) > MAX_ALIGN_CELLS then
    return nil
  end
  if la == 0 then
    return lb
  end
  if lb == 0 then
    return la
  end

  local prev = {}
  for j = 0, lb do
    prev[j] = j
  end

  for i = 1, la do
    local cur = { [0] = i }
    local ca = a:byte(i)
    for j = 1, lb do
      local cost = (ca == b:byte(j)) and 0 or 1
      local del = prev[j] + 1
      local ins = cur[j - 1] + 1
      local sub = prev[j - 1] + cost
      local best = del
      if ins < best then
        best = ins
      end
      if sub < best then
        best = sub
      end
      cur[j] = best
    end
    prev = cur
  end

  return prev[lb]
end

-- The tail window: from just after the log's last timestamped entry to the next log header / EOF.
-- Returns tail_start, stop_row (1-based; stop_row exclusive). Anchoring past the entries guarantees
-- they stay out of the located zone.
local function tail_bounds(analysis, log_block)
  local blocks = analysis.blocks
  local start_index
  for index, block in ipairs(blocks) do
    if block == log_block then
      start_index = index
      break
    end
  end
  if not start_index then
    return nil
  end

  local tail_start = log_block.body_start_row
  for _, node in ipairs(log_block.body_nodes or {}) do
    if node.kind == syntax.NODE_KIND.ENTRY then
      tail_start = node.row + 1
    end
  end

  -- Search limit: the next real log header, or EOF.
  local limit = analysis.document.row_count + 1
  for index = start_index + 1, #blocks do
    if blocks[index].kind == syntax.BLOCK_KIND.LOG then
      limit = blocks[index].start_row
      break
    end
  end

  -- Stop the zone at the first entry line below the summary (the next log's entries; the summary
  -- has none), backed up over a directly-preceding `--- ... ---` header so it is preserved with its
  -- entries. Scanning only for the next LOG would let a corrupted `--- log ---` (which no longer
  -- parses as a log) run the blast to EOF and wipe that log's entries.
  local nodes = analysis.document.nodes
  local stop_row = limit
  for row = tail_start, limit - 1 do
    if nodes[row] and nodes[row].kind == syntax.NODE_KIND.ENTRY then
      stop_row = row
      local above = row - 1
      while
        above >= tail_start
        and nodes[above]
        and nodes[above].kind == syntax.NODE_KIND.BLANK_LINE
      do
        above = above - 1
      end
      local raw = (above >= tail_start and nodes[above] and nodes[above].raw) or ""
      if raw:match("^%-%-%-.*%-%-%-$") and not syntax.is_infile_summary_header(raw) then
        stop_row = above
      end
      break
    end
  end

  return tail_start, stop_row
end

-- The canonical banner this log would render, the target the mangled-banner search aligns against.
local function canonical_banner(log_block)
  return syntax.summary_header(log_block.quantize_minutes, log_block.duration_format)
end

-- Find the banner row in the tail: exact `--- summary q=N d=fmt ---` first, then the closest tail
-- line by edit distance accepted only within ~40% of the banner length (real similarity, so a body
-- note never matches). Returns the row, or nil.
local function find_banner(analysis, tail_start, stop_row, banner)
  local nodes = analysis.document.nodes

  for row = tail_start, stop_row - 1 do
    local raw = (nodes[row] and nodes[row].raw) or ""
    -- The exact pass matches only the banner (any q=/d=, so drifted parameters still anchor), never
    -- a bare section header like `--- tags ---`, which starts mid-zone and would orphan the rows
    -- above it; the shape fallback recovers a banner-less summary.
    if raw == banner or raw:match("^%-%-%- summary q=%d+ d=%a+ %-%-%-$") then
      return row
    end
  end

  -- Mangled banner: nearest line by edit distance, guarded by a similarity threshold so only a
  -- genuinely-corrupted banner (not a body note) qualifies.
  local threshold = math.floor(#banner * 0.4)
  local best_row, best_dist
  for row = tail_start, stop_row - 1 do
    local raw = (nodes[row] and nodes[row].raw) or ""
    local dist = edit_distance(banner, raw)
    if dist and dist <= threshold and (not best_dist or dist < best_dist) then
      best_dist = dist
      best_row = row
    end
  end

  return best_row
end

-- Whether a line is a `--- ... ---` block header, to tell a foreign block from summary content in
-- the shape fallback.
local function is_block_header(raw)
  return raw:match("^%-%-%- .* %-%-%-$") ~= nil
end

-- No banner survives: locate surviving summary content by shape -- the zone starts at the first
-- summary section header or `<dur> (+Nm)` row. A non-summary `--- ... ---` block header ends the
-- search with no summary, since the log's summary is contiguous from its body, so a summary-shaped
-- line inside an unrelated block is never mistaken for it. Returns the zone start row, or nil.
local function find_shape_start(analysis, tail_start, stop_row)
  local nodes = analysis.document.nodes
  for row = tail_start, stop_row - 1 do
    local raw = (nodes[row] and nodes[row].raw) or ""
    if syntax.is_infile_summary_header(raw) or syntax.is_summary_row(raw) then
      return row
    elseif is_block_header(raw) then
      -- A foreign block header before any summary content: no summary here.
      return nil
    end
  end
  return nil
end

-- Locate `log_block`'s generated summary region, returning { start_row, end_row } (1-based, end_row
-- exclusive) covering the zone from the banner to the next log / EOF, or nil when no summary is
-- recognizable and one must be created fresh.
function M.find(analysis, log_block)
  local tail_start, stop_row = tail_bounds(analysis, log_block)
  if not tail_start then
    return nil
  end

  local start = find_banner(analysis, tail_start, stop_row, canonical_banner(log_block))
    or find_shape_start(analysis, tail_start, stop_row)

  if not start then
    return nil
  end

  return { start_row = start, end_row = stop_row }
end

-- The log's tail bounds (tail_start, stop_row): just past the last entry, to the next log / EOF.
-- Exposed so the create path can blast to the same zone end.
function M.tail_bounds(analysis, log_block)
  return tail_bounds(analysis, log_block)
end

-- Exposed for direct unit testing of the character alignment.
M.edit_distance = edit_distance

return M
