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
  { 0x1F300, 0x1F64F },
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

-- The display width in cells of a whole string.
local function text_cells(s)
  local w = 0
  for _, ch in ipairs(utf8_chars(s)) do
    w = w + char_cells(ch)
  end
  return w
end

-- The number of leading characters two char arrays share.
local function lcp(a, b)
  local n = math.min(#a, #b)
  local i = 0
  while i < n and a[i + 1] == b[i + 1] do
    i = i + 1
  end
  return i
end

local LEGEND_OVERHEAD = 5 -- per legend item besides the label: swatch (2) + a leading + two trailing
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

-- Place each distinct label once, centred over its widest segment, overlaps resolved optimally. This is
-- 1-D placement: minimise total squared displacement from the target centres subject to non-overlap =
-- isotonic regression, solved by Pool-Adjacent-Violators (PAVA); fit_legend first guarantees the
-- survivors fit `width`. All arithmetic is integer half-cells (×2), exact and deterministic. See
-- docs/architecture.md (Time bar). Returns { { text, color_index, col } } sorted by `col`.
function M.label_placements(segments, width)
  -- Distinct labels keyed by colour index: the centre (half-cells) of the WIDEST occurrence, total
  -- footprint (eviction priority), and `appear` first-appearance tiebreak.
  local info, order, left = {}, {}, 0
  for _, seg in ipairs(segments) do
    if seg.label then
      local rec = info[seg.color_index]
      if not rec then
        rec = { widest = -1, total = 0, label = seg.label, appear = #order + 1 }
        info[seg.color_index] = rec
        order[#order + 1] = seg.color_index
      end
      rec.total = rec.total + seg.width
      if seg.width > rec.widest then
        rec.widest = seg.width
        rec.center2 = 2 * left + seg.width
      end
    end
    left = left + seg.width
  end
  if #order == 0 then
    return {}
  end

  -- Feed fit_legend in total-footprint order (appearance tiebreak) so it keeps the most-present, evicts
  -- the tail.
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

  -- Placement items: target centre + width recomputed from the (possibly abbreviated) returned text.
  local items = {}
  for _, fit in ipairs(M.fit_legend(by_presence, width)) do
    local rec = info[fit.color_index]
    items[#items + 1] = {
      text = fit.text,
      color_index = fit.color_index,
      center2 = rec.center2,
      w = LEGEND_OVERHEAD + text_cells(fit.text),
      appear = rec.appear,
    }
  end
  table.sort(items, function(a, b)
    if a.center2 ~= b.center2 then
      return a.center2 < b.center2
    end
    return a.appear < b.appear
  end)

  local n = #items
  local sum_w = 0
  for _, it in ipairs(items) do
    sum_w = sum_w + it.w
  end

  -- keep==0 corner: a single label wider than the whole bar; place at col 1, shell drops if it overflows.
  if sum_w > width then
    local out = {}
    for i = 1, n do
      out[i] = { text = items[i].text, color_index = items[i].color_index, col = 1 }
    end
    return out
  end

  -- Isotonic targets in half-cells: t_i = centre_i - w_i - Σ_{j<i} 2·w_j.
  local xmax = 2 * (width - sum_w)
  local t, prefix2 = {}, 0
  for i = 1, n do
    t[i] = items[i].center2 - items[i].w - prefix2
    prefix2 = prefix2 + 2 * items[i].w
  end

  -- PAVA: pooled blocks (sum, count) over the targets; merge while the previous block's mean strictly
  -- exceeds the current (integer cross-multiply).
  local blocks = {}
  for i = 1, n do
    local cur = { sum = t[i], count = 1 }
    while #blocks >= 1 and blocks[#blocks].sum * cur.count > cur.sum * blocks[#blocks].count do
      local top = table.remove(blocks)
      cur = { sum = top.sum + cur.sum, count = top.count + cur.count }
    end
    blocks[#blocks + 1] = cur
  end

  -- Snap to integer cells, forward de-overlap. Block value x = clamp(sum/count, 0, xmax); L_i = x +
  -- Σ_{j<i} 2·w_j, rounded.
  local suffix_w, s = {}, 0
  for i = n, 1, -1 do
    s = s + items[i].w
    suffix_w[i] = s
  end
  local out, idx, prefixw, right = {}, 0, 0, 0
  for _, blk in ipairs(blocks) do
    for _ = 1, blk.count do
      idx = idx + 1
      local it = items[idx]
      local want
      if blk.sum <= 0 then
        want = prefixw -- x = 0
      elseif blk.sum >= xmax * blk.count then
        want = math.floor(xmax / 2) + prefixw -- x = xmax (even)
      else
        want = math.floor((blk.sum + 2 * prefixw * blk.count + blk.count) / (2 * blk.count)) -- round half up
      end
      local col_left = math.min(math.max(want, right), width - suffix_w[idx])
      out[#out + 1] = { text = it.text, color_index = it.color_index, col = col_left + 1 }
      right = col_left + it.w
      prefixw = prefixw + it.w
    end
  end
  return out
end

return M
