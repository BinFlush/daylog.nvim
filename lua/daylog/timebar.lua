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

return M
