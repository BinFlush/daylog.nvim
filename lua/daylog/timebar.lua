-- Time bar layout (PURE).
--
-- Turns the active log's intervals into a horizontal, time-proportional bar: each interval is a
-- segment whose cell width is its share of the real recorded duration, and whose colour is its
-- activity (resolved label). Colours are assigned by order of first appearance (colors.lua, shared
-- with the margin indicator and summary), and each bar carries its own legend of those activities. The
-- shell (timebar_ui.lua) maps the colour index onto a palette highlight group, draws the segments, and
-- centres each bar's legend alongside it.

local colors = require("daylog.colors")
local summary = require("daylog.summary")

local M = {}

-- Distribute `width` cells across the intervals proportional to their real duration, with
-- largest-remainder rounding so the widths sum to exactly `width` (the leftover cells go to the
-- largest fractional remainders, earlier intervals first).
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

-- A dead period -- the interval a blank entry starts -- is not time-proportional in the bar: it is a
-- single-cell marker that flags the gap without consuming it. GAP_WIDTH cells per contiguous run.
local GAP_WIDTH = 1

-- The 1-based bar column the clock minute `minutes` falls in, walking the (time-contiguous) segments:
-- each segment owns a run of cells and is linear within its own [start, stop). The inverse of
-- time_at_column; used to place the "now" marker across a bar whose axis is piecewise (gaps are thin).
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

-- The legend for one bar: its distinct activity labels in first-appearance order, each
-- { label, color_index }. Gap segments (no label) are skipped. Each bar carries its own legend so the
-- raw and resolved bars name only their own segments.
local function segments_legend(segments)
  local seen, out = {}, {}
  for _, seg in ipairs(segments) do
    if seg.label and not seen[seg.label] then
      seen[seg.label] = true
      out[#out + 1] = { label = seg.label, color_index = seg.color_index }
    end
  end
  return out
end

-- Build the bar layout for `entries`' active intervals over `width` cells, or nil when there is
-- nothing to show (no intervals, a zero/negative span, or an invalid out-of-order log). Returns
-- { segments = { { width, color_index, label, start, stop } }, legend = { { label, color_index } },
-- raw_segments = <same shape, or nil>, raw_legend = <same shape, or nil> }. Each segment carries its
-- [start, stop) clock span; zero-width counted segments are dropped, but a blank entry's dead period is
-- kept as a thin `gap` segment. `legend` names the resolved (or unmapped) bar's activities; when the log
-- is mapped (some entry's raw description differs from its resolved label) `raw_segments`/`raw_legend`
-- carry the "before mapping" bar coloured by raw description, so each bar renders its own legend.
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

  -- The raw description (the `=>` left-hand side) of the entry starting each interval. `iv.text` is
  -- the resolved label (alias or text); when they differ for any interval the log carries a mapping,
  -- so a "before mapping" bar is worth drawing alongside the resolved one.
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

  -- One shared colour map, so both bars and the single legend agree: resolved labels first (leaving the
  -- resolved bar's colours exactly as before), then any raw sides that differ, appended in appearance
  -- order. An unmapped interval keeps its one index in both bars.
  if mapped then
    for _, iv in ipairs(intervals) do
      local raw = raw_of(iv)
      if index[raw] == nil then
        order[#order + 1] = raw
        index[raw] = #order
      end
    end
  end

  -- Walk the entries in time order into slots: each counted interval is one slot; a run of consecutive
  -- blank entries collapses to one `gap` slot spanning to the next timestamp. Counted intervals are
  -- taken from `intervals` in order (which skips blanks), so the counter tracks them one-for-one.
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

  -- Reserve GAP_WIDTH cells per gap and spread the rest across the counted intervals proportionally.
  -- A bar too narrow to hold the gaps plus one counted cell drops the markers (the counted bar wins).
  local gap_count = 0
  for _, slot in ipairs(slots) do
    if slot.gap then
      gap_count = gap_count + 1
    end
  end
  local show_gaps = gap_count > 0 and width - gap_count * GAP_WIDTH >= 1
  local widths =
    segment_widths(intervals, total, show_gaps and width - gap_count * GAP_WIDTH or width)

  -- Emit segments in time order. A counted segment carries its colour/label and its [start, stop) so
  -- the piecewise now-marker and hover can map columns to clock time; a gap segment is a thin marker
  -- (no colour/label) over its own dead span. Zero-width counted segments are dropped; gaps are not.
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

  -- Each bar carries its own labels, placed over their widest segment (`labels`, and `raw_labels` for the
  -- raw "before" bar when mapped). `legend`/`raw_legend` keep the distinct-label colour ordering.
  local result = {
    segments = segments,
    legend = segments_legend(segments),
    labels = M.label_placements(segments, width),
    raw_segments = raw_segments,
    raw_legend = raw_segments and segments_legend(raw_segments) or nil,
    raw_labels = raw_segments and M.label_placements(raw_segments, width) or nil,
  }

  -- The "now" marker column: when the current time falls inside the bar's span -- i.e. the final
  -- entry is in the future relative to now -- mark where now sits so the shell can draw a line on the
  -- bar at the current time. Purely a position cue; it changes no interval and never the summary.
  if now_minutes then
    local first = entries[1].minutes
    local last = entries[#entries].minutes
    if last > first and now_minutes >= first and now_minutes < last then
      result.now_col = column_at_time(segments, now_minutes)
    end
  end

  return result
end

-- The clock minutes at a 1-based bar column, the inverse of column_at_time: the bar's x-axis is
-- piecewise linear (a gap is a thin fixed cell, not time-proportional), so find the segment `col`
-- lands in and interpolate within its own [start, stop) run. Past the last segment clamps to its
-- stop. Pure; reads the layout's segments, which carry their time span.
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

-- The activity label of the segment covering 1-based column `col` (segment widths sum to the bar
-- width), or nil when `col` falls past the last segment. Pure; reads `layout.segments`.
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

-- Split a string into its UTF-8 characters, so abbreviation never cuts a multibyte char. A byte below
-- 0x80 (ASCII) or at/above 0xC0 (a lead byte) starts a character; 0x80..0xBF continues the current one.
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

-- Fit the legend `items` ({ label, color_index } in appearance order) into `width` cells: abbreviate
-- the longest labels to a still-distinct prefix (marked with "…") before dropping any, and drop from
-- the tail only once even the floored minimums no longer fit. Returns { { text, color_index } } with
-- the text already abbreviated. Pure: the shell renders it and guards the true display width.
function M.fit_legend(items, width)
  local n = #items
  if n == 0 then
    return {}
  end

  local chars, len = {}, {}
  for i = 1, n do
    chars[i] = utf8_chars(items[i].label)
    len[i] = #chars[i]
  end

  -- 1) the shortest prefix that keeps each label distinct from every other, floored for readability
  --    and capped at its own length (so a label that is a prefix of another simply stays full).
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
    return LEGEND_OVERHEAD + a + (a < len[i] and 1 or 0)
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

  -- A single leading label too wide even at its minimum: still show it, hard-truncated to the width
  -- (the shell drops it if even that overflows).
  if keep == 0 then
    local a = math.max(1, math.min(len[1], width - LEGEND_OVERHEAD - 1))
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

-- Place each distinct label once, centred over its widest segment, resolving overlaps optimally. Returns
-- { { text, color_index, col } } sorted by `col` (1-based left cell of the swatch). This is 1-D label
-- placement: sort by target centre (crossing never helps), then minimise total squared displacement
-- subject to non-overlap -- exactly isotonic regression, solved by Pool-Adjacent-Violators (PAVA). A
-- crowded cluster pools into one block centred on its targets' centroid, members abutting. `fit_legend`
-- first abbreviates and drops the least-present (smallest total footprint) so the survivors fit `width`,
-- guaranteeing feasibility. All arithmetic is integer half-cells (×2), so it is exact and deterministic.
function M.label_placements(segments, width)
  -- Distinct labels: the centre (half-cells) of the WIDEST occurrence, and the total footprint (for
  -- eviction priority), keyed by colour index. `appear` is the first-appearance tiebreak.
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

  -- Abbreviate + drop the least-present: feed fit_legend in total-footprint order (appearance tiebreak),
  -- so it keeps the most-present prefix and evicts the tail.
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
      w = LEGEND_OVERHEAD + #utf8_chars(fit.text),
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

  -- keep==0 corner: a single label wider than the whole bar (fit_legend guarantees the rest fit). Place
  -- at col 1; the shell drops it if it still overflows.
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

  -- PAVA: pooled blocks (sum, count) over the integer targets; merge while the previous block's mean
  -- strictly exceeds the current one (integer cross-multiply, no floats).
  local blocks = {}
  for i = 1, n do
    local cur = { sum = t[i], count = 1 }
    while #blocks >= 1 and blocks[#blocks].sum * cur.count > cur.sum * blocks[#blocks].count do
      local top = table.remove(blocks)
      cur = { sum = top.sum + cur.sum, count = top.count + cur.count }
    end
    blocks[#blocks + 1] = cur
  end

  -- Snap to integer cells with a forward de-overlap pass. Each block value x = clamp(sum/count, 0, xmax)
  -- (uniform box ⇒ clamp the block mean, monotonicity preserved); L_i = x + Σ_{j<i} 2·w_j, rounded.
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
