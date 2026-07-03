-- Time bar layout (PURE).
--
-- Turns the active log's intervals into a horizontal, time-proportional bar: each interval is a
-- segment whose cell width is its share of the real recorded duration, and whose colour is its
-- activity (resolved label). Colours are assigned by order of first appearance (colors.lua, shared
-- with the margin indicator and summary), and a legend lists them in that order. The shell
-- (buffer.lua) maps the colour index onto a palette highlight group and draws the segments.

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

-- Build the bar layout for `entries`' active intervals over `width` cells, or nil when there is
-- nothing to show (no intervals, a zero/negative span, or an invalid out-of-order log). Returns
-- { segments = { { width, color_index, label } }, legend = { { label, color_index } },
-- raw_segments = <same shape, or nil> }; zero-width segments are dropped, but the legend still lists
-- every activity in colour order. `raw_segments` is set only when the log is mapped (some entry's raw
-- description differs from its resolved label): the same-width segments coloured by raw description,
-- for a "before mapping" bar. The legend then covers both bars' colours (resolved labels then raw).
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

  local legend = {}
  for _, label in ipairs(order) do
    legend[#legend + 1] = { label = label, color_index = index[label] }
  end

  -- raw_segments is present only when the log is mapped; the shell then stacks it above the resolved
  -- bar for a before/after view. Unmapped logs return a single bar.
  local result = { segments = segments, legend = legend, raw_segments = raw_segments }

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

return M
