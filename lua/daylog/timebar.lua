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

-- Build the bar layout for `entries`' active intervals over `width` cells, or nil when there is
-- nothing to show (no intervals, a zero/negative span, or an invalid out-of-order log). Returns
-- { segments = { { width, color_index, label } }, legend = { { label, color_index } } }; zero-width
-- segments are dropped, but the legend still lists every activity in colour order.
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
  local widths = segment_widths(intervals, total, width)

  local segments = {}
  for i, iv in ipairs(intervals) do
    if widths[i] > 0 then
      segments[#segments + 1] = { width = widths[i], color_index = index[iv.text], label = iv.text }
    end
  end

  local legend = {}
  for _, label in ipairs(order) do
    legend[#legend + 1] = { label = label, color_index = index[label] }
  end

  local result = { segments = segments, legend = legend }

  -- The "now" marker column: when the current time falls inside the bar's span -- i.e. the final
  -- entry is in the future relative to now -- mark where now sits so the shell can draw a line on the
  -- bar at the current time. Purely a position cue; it changes no interval and never the summary.
  if now_minutes then
    local first = entries[1].minutes
    local last = entries[#entries].minutes
    if last > first and now_minutes >= first and now_minutes < last then
      result.now_col =
        math.min(math.floor((now_minutes - first) / (last - first) * width) + 1, width)
    end
  end

  return result
end

-- The clock minutes at a 1-based bar column, the inverse of the now-marker mapping above: the bar's
-- x-axis is linear in time over [first, last], so column `col` of `width` sits at the cell's left
-- edge, first + (col-1)/width * (last-first). Rounded to the minute and clamped to the span.
function M.time_at_column(first, last, width, col)
  if width < 1 then
    return first
  end
  local raw = first + math.floor((col - 1) / width * (last - first) + 0.5)
  return math.max(first, math.min(last, raw))
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
