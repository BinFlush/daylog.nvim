-- Time bar layout (PURE).
-- Turns the active log's intervals into a time-proportional bar: each interval is a segment whose cell
-- width is its share of the real recorded duration and whose colour is its resolved-label activity
-- (assigned by first appearance, colors.lua). The shell (timebar_ui.lua) renders it.

local colors = require("daylog.colors")
local summary = require("daylog.summary")

local M = {}

-- Distribute `width` cells across intervals proportional to real duration, largest-remainder rounding
-- so the widths sum to exactly `width` (leftovers to the largest remainders, earlier first).
local function segment_widths(intervals, total, width)
  local floors = {}
  local remainder = {}
  local used = 0
  for i, iv in ipairs(intervals) do
    local exact = iv.duration / total * width
    floors[i] = math.floor(exact)
    remainder[i] = exact - floors[i]
    used = used + floors[i]
  end

  local order = {}
  for i = 1, #intervals do
    order[i] = i
  end
  table.sort(order, function(a, b)
    if remainder[a] ~= remainder[b] then
      return remainder[a] > remainder[b]
    end
    return a < b
  end)
  for k = 1, width - used do
    floors[order[k]] = floors[order[k]] + 1
  end

  return floors
end

-- A dead period (the interval a blank entry starts) is a single-cell marker, not time-proportional:
-- GAP_WIDTH cells per contiguous run.
local GAP_WIDTH = 1

-- The 1-based bar column clock minute `minutes` falls in; inverse of time_at_column over the piecewise
-- axis (each segment linear within its own [start, stop)).
local function column_at_time(segments, minutes)
  local left = 0
  for _, seg in ipairs(segments) do
    if minutes < seg.stop then
      local span = seg.stop - seg.start
      local within = span > 0 and math.floor((minutes - seg.start) / span * seg.width) or 0
      return left + math.max(0, math.min(seg.width - 1, within)) + 1
    end
    left = left + seg.width
  end
  return math.max(1, left)
end

-- Build the bar layout for `entries`' active intervals over `width` cells, or nil when nothing to show
-- (no intervals, zero/negative span, out-of-order log). Returns { segments, labels, raw_segments,
-- raw_labels }; each segment carries its [start, stop) span, zero-width counted segments dropped but a
-- blank's dead period kept as a thin `gap`. When mapped, `raw_*` carry the "before mapping" bar.
function M.layout(entries, width, now_minutes)
  if type(width) ~= "number" or width < 1 then
    return nil
  end

  local intervals = summary.build_intervals(entries)
  if #intervals == 0 then
    return nil
  end

  local total = 0
  for _, iv in ipairs(intervals) do
    if iv.duration < 0 then
      return nil
    end
    total = total + iv.duration
  end
  if total <= 0 then
    return nil
  end

  local index, order = colors.indices(intervals)

  -- The raw description of the entry starting each interval; when it differs from `iv.text` (the
  -- resolved label) the log carries a mapping, so a "before mapping" bar is worth drawing.
  local by_row = {}
  for _, e in ipairs(entries) do
    by_row[e.row] = e
  end
  local function raw_of(iv)
    return by_row[iv.source_entry_row].text
  end

  local mapped = false
  for _, iv in ipairs(intervals) do
    if raw_of(iv) ~= iv.text then
      mapped = true
      break
    end
  end

  -- One shared colour map so both bars and the legend agree: resolved labels first, then any differing
  -- raw sides appended in appearance order.
  if mapped then
    for _, iv in ipairs(intervals) do
      local raw = raw_of(iv)
      if index[raw] == nil then
        order[#order + 1] = raw
        index[raw] = #order
      end
    end
  end

  -- Walk entries in time order into slots: each counted interval one slot, a run of blanks one `gap`
  -- slot to the next timestamp. `intervals` skips blanks, so `ci` tracks counted slots one-for-one.
  local slots = {}
  local ci, i = 1, 1
  while i <= #entries - 1 do
    if summary.is_blank_entry(entries[i]) then
      local gap_start = entries[i].minutes
      while i <= #entries - 1 and summary.is_blank_entry(entries[i]) do
        i = i + 1
      end
      slots[#slots + 1] = { gap = true, start = gap_start, stop = entries[i].minutes }
    else
      slots[#slots + 1] = { interval = intervals[ci] }
      ci = ci + 1
      i = i + 1
    end
  end

  -- Reserve GAP_WIDTH per gap, spread the rest across counted intervals; too narrow drops the markers.
  local gap_count = 0
  for _, slot in ipairs(slots) do
    if slot.gap then
      gap_count = gap_count + 1
    end
  end
  local show_gaps = gap_count > 0 and width - gap_count * GAP_WIDTH >= 1
  local widths =
    segment_widths(intervals, total, show_gaps and width - gap_count * GAP_WIDTH or width)

  -- Emit segments in time order: a counted segment carries colour/label and [start, stop); a gap is a
  -- thin colourless marker over its dead span. Zero-width counted segments are dropped; gaps are not.
  local segments = {}
  local raw_segments = mapped and {} or nil
  local ii = 0
  for _, slot in ipairs(slots) do
    if slot.gap then
      if show_gaps then
        local gap = { width = GAP_WIDTH, gap = true, start = slot.start, stop = slot.stop }
        segments[#segments + 1] = gap
        if mapped then
          raw_segments[#raw_segments + 1] = gap
        end
      end
    else
      ii = ii + 1
      local iv = slot.interval
      if widths[ii] > 0 then
        segments[#segments + 1] = {
          width = widths[ii],
          color_index = index[iv.text],
          label = iv.text,
          start = iv.start,
          stop = iv.stop,
        }
        if mapped then
          local raw = raw_of(iv)
          raw_segments[#raw_segments + 1] = {
            width = widths[ii],
            color_index = index[raw],
            label = raw,
            start = iv.start,
            stop = iv.stop,
          }
        end
      end
    end
  end

  -- Each bar's labels are placed over their widest segment.
  local result = {
    segments = segments,
    labels = M.label_placements(segments, width),
    raw_segments = raw_segments,
    raw_labels = raw_segments and M.label_placements(raw_segments, width) or nil,
  }

  -- The "now" marker column, only when now falls inside a displayed segment's [start, stop): a dropped
  -- or zero-width segment is a hole in the piecewise axis where a marker would sit on the wrong cell.
  if now_minutes then
    for _, seg in ipairs(segments) do
      if now_minutes >= seg.start and now_minutes < seg.stop then
        result.now_col = column_at_time(segments, now_minutes)
        break
      end
    end
  end

  return result
end

-- The clock minutes at a 1-based bar column, inverse of column_at_time: interpolate within the segment
-- `col` lands in (piecewise axis); past the last segment clamps to its stop. PURE.
function M.time_at_column(segments, col)
  local left = 0
  for _, seg in ipairs(segments) do
    if col <= left + seg.width then
      local local_col = col - left
      local raw = seg.start + math.floor((local_col - 1) / seg.width * (seg.stop - seg.start) + 0.5)
      return math.max(seg.start, math.min(seg.stop, raw))
    end
    left = left + seg.width
  end
  local last = segments[#segments]
  return last and last.stop or 0
end

-- The activity label of the segment covering 1-based column `col`, or nil past the last segment. PURE.
function M.segment_label_at(segments, col)
  local edge = 0
  for _, seg in ipairs(segments) do
    edge = edge + seg.width
    if col <= edge then
      return seg.label
    end
  end
  return nil
end

-- Split a string into UTF-8 characters so abbreviation never cuts a multibyte char (a byte <0x80 or
-- >=0xC0 starts a character; 0x80..0xBF continues it).
local function utf8_chars(s)
  local chars = {}
  for i = 1, #s do
    local b = string.byte(s, i)
    if b < 0x80 or b >= 0xC0 then
      chars[#chars + 1] = string.sub(s, i, i)
    elseif #chars > 0 then
      chars[#chars] = chars[#chars] .. string.sub(s, i, i)
    end
  end
  return chars
end

-- Codepoint ranges that render two cells wide (East Asian Wide/Fullwidth: CJK, Hangul, fullwidth
-- forms, common emoji). Everything else counts as one cell.
local WIDE_RANGES = {
  { 0x1100, 0x115F },
  { 0x2E80, 0xA4CF },
  { 0xA960, 0xA97F },
  { 0xAC00, 0xD7A3 },
  { 0xF900, 0xFAFF },
  { 0xFE30, 0xFE4F },
  { 0xFF00, 0xFF60 },
  { 0xFFE0, 0xFFE6 },
  { 0x1F000, 0x1F0FF }, -- mahjong / dominoes / playing cards
  { 0x1F300, 0x1F64F }, -- misc symbols & pictographs, emoticons
  { 0x1F680, 0x1F6FF }, -- transport & map symbols (e.g. U+1F680 rocket)
  { 0x1F900, 0x1FAFF },
  { 0x20000, 0x2FFFD },
}

-- The display width in cells of one UTF-8 character; mirrors strdisplaywidth so label budgets are
-- cell-accurate, kept pure.
local function char_cells(ch)
  local b1 = string.byte(ch, 1)
  local cp
  if b1 < 0x80 then
    cp = b1
  elseif b1 < 0xE0 then
    cp = (b1 % 0x20) * 0x40 + ((string.byte(ch, 2) or 0x80) % 0x40)
  elseif b1 < 0xF0 then
    cp = (b1 % 0x10) * 0x1000
      + ((string.byte(ch, 2) or 0x80) % 0x40) * 0x40
      + ((string.byte(ch, 3) or 0x80) % 0x40)
  else
    cp = (b1 % 0x08) * 0x40000
      + ((string.byte(ch, 2) or 0x80) % 0x40) * 0x1000
      + ((string.byte(ch, 3) or 0x80) % 0x40) * 0x40
      + ((string.byte(ch, 4) or 0x80) % 0x40)
  end
  for _, range in ipairs(WIDE_RANGES) do
    if cp >= range[1] and cp <= range[2] then
      return 2
    end
  end
  return 1
end

M.char_cells = char_cells

-- The number of leading characters two char arrays share.
local function lcp(a, b)
  local n = math.min(#a, #b)
  local i = 0
  while i < n and a[i + 1] == b[i + 1] do
    i = i + 1
  end
  return i
end

local SWATCH_CELLS = 2 -- a legend item's colour swatch at full width
local MIN_SWATCH = 1 -- ...which it gives cells up to, down to this, rather than let a label be dropped
local ITEM_OVERHEAD = 3 -- per legend item besides the swatch and the label: a leading + two trailing
local LEGEND_OVERHEAD = SWATCH_CELLS + ITEM_OVERHEAD -- fit_legend prices a full-width swatch
local LEGEND_FLOOR = 3 -- never shave a label below this many characters (or its length, if shorter)
local LEGEND_MARKER = "…" -- appended to a shortened label; one display cell

-- Fit legend `items` (in appearance order) into `width` cells: abbreviate the longest labels to a
-- still-distinct "…"-marked prefix before dropping any, then drop from the tail. PURE.
function M.fit_legend(items, width)
  local n = #items
  if n == 0 then
    return {}
  end

  -- Per label: characters, count, and prefix cell sums (cells[i][a] = width of first `a` chars).
  local chars, len, cells = {}, {}, {}
  for i = 1, n do
    chars[i] = utf8_chars(items[i].label)
    len[i] = #chars[i]
    local sums = { [0] = 0 }
    for k = 1, len[i] do
      sums[k] = sums[k - 1] + char_cells(chars[i][k])
    end
    cells[i] = sums
  end

  -- 1) shortest prefix keeping each label distinct, floored for readability, capped at its own length.
  local min_len = {}
  for i = 1, n do
    local distinct = 1
    for j = 1, n do
      if j ~= i then
        distinct = math.max(distinct, lcp(chars[i], chars[j]) + 1)
      end
    end
    min_len[i] = math.min(len[i], math.max(LEGEND_FLOOR, distinct))
  end

  local function cost(i, a)
    return LEGEND_OVERHEAD + cells[i][a] + (a < len[i] and 1 or 0)
  end

  -- 2) keep the longest leading run whose floored minimums fit; evict the rest from the tail.
  local keep, budget = 0, 0
  for i = 1, n do
    budget = budget + cost(i, min_len[i])
    if budget > width then
      break
    end
    keep = i
  end

  -- A single leading label too wide even at its minimum: hard-truncate it to the width.
  if keep == 0 then
    local cap = width - LEGEND_OVERHEAD - 1
    local a = 1
    while a < len[1] and cells[1][a + 1] <= cap do
      a = a + 1
    end
    local text = table.concat(chars[1], "", 1, a)
    if a < len[1] then
      text = text .. LEGEND_MARKER
    end
    return { { text = text, color_index = items[1].color_index } }
  end

  -- 3) start the kept labels full, then shave the longest one still above its minimum until it fits.
  local a, total = {}, 0
  for i = 1, keep do
    a[i] = len[i]
    total = total + cost(i, a[i])
  end
  while total > width do
    local pick
    for i = 1, keep do
      if a[i] > min_len[i] then
        local better
        if not pick then
          better = true
        elseif a[i] ~= a[pick] then
          better = a[i] > a[pick]
        elseif a[i] - min_len[i] ~= a[pick] - min_len[pick] then
          better = a[i] - min_len[i] > a[pick] - min_len[pick]
        else
          better = true -- equal length and slack: prefer the later (greater) index
        end
        if better then
          pick = i
        end
      end
    end
    if not pick then
      break
    end
    total = total - cost(pick, a[pick])
    a[pick] = a[pick] - 1
    total = total + cost(pick, a[pick])
  end

  -- 4) emit, marking the shortened labels.
  local out = {}
  for i = 1, keep do
    local text = table.concat(chars[i], "", 1, a[i])
    if a[i] < len[i] then
      text = text .. LEGEND_MARKER
    end
    out[#out + 1] = { text = text, color_index = items[i].color_index }
  end
  return out
end

local ASSIGNMENT_BUDGET = 20000 -- cap on the anchor-assignment search; trim to widest-few beyond it

-- Gather each colour's occurrences (blocks as 0-based [bl, br)), total duration, and appearance order.
local function label_occurrences(segments)
  local info, order, left = {}, {}, 0
  for _, seg in ipairs(segments) do
    if seg.label then
      local rec = info[seg.color_index]
      if not rec then
        rec = { label = seg.label, total = 0, appear = #order + 1, occ = {} }
        info[seg.color_index] = rec
        order[#order + 1] = seg.color_index
      end
      rec.total = rec.total + seg.width
      rec.occ[#rec.occ + 1] = { bl = left, br = left + seg.width, width = seg.width }
    end
    left = left + seg.width
  end
  return info, order
end

-- Place each distinct label once, its colour swatch on ONE of the activity's segments, and give it as
-- much of its text as fits. Swatch width (1..SWATCH_CELLS) and text length are both placement variables;
-- the swatch sits FULLY on its block (bl <= s <= br - sw), so it is never shown off its own colour.
-- fit_legend picks which activities are shown; then, over a bounded search of which occurrence each label
-- anchors to, the layout minimises lexicographically:
--   (1) labels dropped, (2) swatches shrunk, (3) characters hidden (prefer full text), (4) Σ rank of the
--   anchored occurrence (0 = the activity's longest segment), (5) duration dropped.
-- Each label is packed at its true minimum (a 1-cell swatch, its shortest still-distinct text) for
-- feasibility -- so a blocker is SHORTENED or narrowed, not its neighbour dropped -- then grown back into
-- whatever slack remains, swatch first then text; a label is dropped only when even that minimum cannot
-- sit on any of its blocks. Its swatch is centred on the block where room allows.
-- Returns { { text, color_index, col, swatch } } sorted by col. PURE, deterministic.
function M.label_placements(segments, width)
  local info, order = label_occurrences(segments)
  if #order == 0 then
    return {}
  end

  -- fit_legend decides which activities show (dropping the least-present when even minimal labels can't
  -- all fit the width); presence order feeds it.
  local by_presence = {}
  for _, ci in ipairs(order) do
    local rec = info[ci]
    by_presence[#by_presence + 1] =
      { label = rec.label, color_index = ci, total = rec.total, appear = rec.appear }
  end
  table.sort(by_presence, function(a, b)
    if a.total ~= b.total then
      return a.total > b.total
    end
    return a.appear < b.appear
  end)

  -- Candidates: char array + cell prefix sums (to price any prefix length) + occurrences ranked
  -- longest-first (rank 0 = longest).
  local cands = {}
  for _, fit in ipairs(M.fit_legend(by_presence, width)) do
    local rec = info[fit.color_index]
    local chars = utf8_chars(rec.label)
    local sums = { [0] = 0 }
    for k = 1, #chars do
      sums[k] = sums[k - 1] + char_cells(chars[k])
    end
    local occ = {}
    for _, o in ipairs(rec.occ) do
      occ[#occ + 1] = { bl = o.bl, br = o.br, width = o.width }
    end
    table.sort(occ, function(a, b)
      if a.width ~= b.width then
        return a.width > b.width
      end
      return a.bl < b.bl
    end)
    for r = 1, #occ do
      occ[r].rank = r - 1
    end
    cands[#cands + 1] = {
      color_index = fit.color_index,
      chars = chars,
      cells = sums,
      full = #chars,
      total = rec.total,
      appear = rec.appear,
      occ = occ,
    }
  end
  local n = #cands
  if n == 0 then
    return {}
  end
  -- Shortest still-distinct prefix each label may shrink to (floored at LEGEND_FLOOR).
  for i, c in ipairs(cands) do
    local distinct = 1
    for j, d in ipairs(cands) do
      if i ~= j then
        distinct = math.max(distinct, lcp(c.chars, d.chars) + 1)
      end
    end
    c.min_len = math.min(c.full, math.max(LEGEND_FLOOR, distinct))
  end
  table.sort(cands, function(a, b)
    return a.appear < b.appear
  end)

  -- Footprint (cells) of showing `a` chars of `c` behind an `sw`-cell swatch: swatch + overhead + prefix
  -- cells + ellipsis when shortened.
  local function footprint(c, a, sw)
    return sw + ITEM_OVERHEAD + c.cells[a] + (a < c.full and 1 or 0)
  end
  -- Longest prefix length in [min_len, full] whose footprint fits `cap`, or nil if even min_len overflows.
  local function fit_len(c, cap, sw)
    if footprint(c, c.min_len, sw) > cap then
      return nil
    end
    local a = c.min_len
    while a < c.full and footprint(c, a + 1, sw) <= cap do
      a = a + 1
    end
    return a
  end

  -- Bound the search: trim the busiest label's narrowest occurrences until the product of choices fits.
  local function over_budget()
    local p = 1
    for _, c in ipairs(cands) do
      p = p * #c.occ
      if p > ASSIGNMENT_BUDGET then
        return true
      end
    end
    return false
  end
  while over_budget() do
    local pick, most = nil, 1
    for i, c in ipairs(cands) do
      if #c.occ > most then
        most, pick = #c.occ, i
      end
    end
    if not pick then
      break
    end
    table.remove(cands[pick].occ)
  end

  -- Evaluate one assignment (choice[i] = occurrence for cand i). Pass 1: pack each label at its MINIMUM
  -- footprint (a 1-cell swatch, its shortest still-distinct text), leftmost, its swatch on its block and
  -- clearing the previous; a label whose minimum can't fit is dropped, and its leftmost column is kept in
  -- `s`. Pass 2 (right-to-left): grow each shown label into the room a RIGHT-ALIGNED right neighbour
  -- leaves (past the left labels' reserved minimums) -- so free space to the right flows left to whoever
  -- can still use it, rather than stranding it behind a right label pinned near its centre. The swatch
  -- grows before the text, so a narrowed swatch means the item had NO slack at all -- exactly where a
  -- label would otherwise be dropped. Returns drops, swatches shrunk, hidden chars, Σrank, dropped
  -- duration, and the placed list { c, o, s, len, sw } in block order.
  local function evaluate(choice)
    local seq = {}
    for i = 1, n do
      seq[#seq + 1] = { c = cands[i], o = choice[i] }
    end
    table.sort(seq, function(a, b)
      if a.o.bl ~= b.o.bl then
        return a.o.bl < b.o.bl
      end
      return a.c.appear < b.c.appear
    end)
    local placed, drops, sum_rank, drop_dur, prev_right = {}, 0, 0, 0, 0
    for _, e in ipairs(seq) do
      local c, o = e.c, e.o
      local floor_w = footprint(c, c.min_len, MIN_SWATCH)
      local s = math.max(prev_right, o.bl)
      if s <= o.br - MIN_SWATCH and s + floor_w <= width then
        placed[#placed + 1] = { c = c, o = o, s = s }
        sum_rank = sum_rank + o.rank
        prev_right = s + floor_w
      else
        drops = drops + 1
        drop_dur = drop_dur + c.total
      end
    end
    local hidden, shrunk, bound = 0, 0, width
    for i = #placed, 1, -1 do
      local p = placed[i]
      -- `bound - p.s` is the span from this label's reserved-minimum column to the right neighbour's
      -- right-aligned swatch: the most the item can spend.
      local cap = bound - p.s
      local full_swatch = p.s <= p.o.br - SWATCH_CELLS
        and footprint(p.c, p.c.min_len, SWATCH_CELLS) <= cap
      p.sw = full_swatch and SWATCH_CELLS or MIN_SWATCH
      shrunk = shrunk + (SWATCH_CELLS - p.sw)
      p.len = fit_len(p.c, cap, p.sw) or p.c.min_len
      hidden = hidden + (p.c.full - p.len)
      bound = math.min(p.o.br - p.sw, bound - footprint(p.c, p.len, p.sw))
    end
    return drops, shrunk, hidden, sum_rank, drop_dur, placed
  end

  -- Odometer over occurrence choices; keep the lexicographically best (drops, shrunk, hidden, Σrank,
  -- drop-dur).
  local idx = {}
  for i = 1, n do
    idx[i] = 1
  end
  local best, best_placed
  while true do
    local choice = {}
    for i = 1, n do
      choice[i] = cands[i].occ[idx[i]]
    end
    local drops, shrunk, hidden, sum_rank, drop_dur, placed = evaluate(choice)
    local key = { drops, shrunk, hidden, sum_rank, drop_dur }
    if not best then
      best, best_placed = key, placed
    else
      for k = 1, #key do
        if key[k] ~= best[k] then
          if key[k] < best[k] then
            best, best_placed = key, placed
          end
          break
        end
      end
    end
    local i = n
    while i >= 1 do
      idx[i] = idx[i] + 1
      if idx[i] <= #cands[i].occ then
        break
      end
      idx[i] = 1
      i = i - 1
    end
    if i < 1 then
      break
    end
  end

  -- Position the winner's swatches now that widths and lengths are fixed: the leftmost feasible packing
  -- (with the grown items) is each swatch's floor; then right-to-left, centre each on its block, clamped
  -- to [bl, br - sw] so every swatch cell stays on its own colour, and so it never shoves a left label off
  -- its block or overruns the next. A swatch slides off-centre only as far as a neighbour genuinely needs
  -- the room. Text is truncated to its chosen length (+ ellipsis when shortened).
  local m = #best_placed
  local leftmost, prev_right = {}, 0
  for i = 1, m do
    local p = best_placed[i]
    leftmost[i] = math.max(prev_right, p.o.bl)
    prev_right = leftmost[i] + footprint(p.c, p.len, p.sw)
  end
  local out, next_left = {}, width
  for i = m, 1, -1 do
    local p = best_placed[i]
    local fw = footprint(p.c, p.len, p.sw)
    local target = math.floor((p.o.bl + p.o.br - p.sw) / 2)
    local s = math.max(leftmost[i], math.min(target, math.min(p.o.br - p.sw, next_left - fw)))
    local t = table.concat(p.c.chars, "", 1, p.len)
    if p.len < p.c.full then
      t = t .. LEGEND_MARKER
    end
    out[i] = { text = t, color_index = p.c.color_index, col = s + 1, swatch = p.sw }
    next_left = s
  end
  return out
end

return M
