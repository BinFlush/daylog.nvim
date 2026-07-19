local quantize = require("daylog.quantize")
local syntax = require("daylog.syntax")

local M = {}

-- Logged claims and the displayed shares they pin. PURE.
--
-- A marker `!X[names]V` records a FACT: V minutes of a slice were logged externally. Every counted
-- entry holds ONE displayed share -- its honest quantized split, unless a claim pins it -- and each
-- report section sums those same shares under its own partition, so all four always foot alike.
-- Claims pin finest-to-coarsest (S -> T -> L -> W); one the pass cannot realize is a conflict.
-- (docs/architecture.md, Logging: the facts model.)

local LEVEL_NOUN = { s = "activity", t = "tag", l = "location", w = "workday" }

-- A blank entry (bare timestamp, no activity text) marks uncounted time: excluded from every report,
-- never a map/rename target, carrying no metadata.
function M.is_blank(entry)
  return entry.text == nil or entry.text == ""
end

-- The text an entry reports under: its alias when mapped, else its description. Every grouping and
-- the frecency ranker key on this, so a bare and a mapped entry reporting as one label rank as one.
function M.label(entry)
  return (entry.alias ~= nil and entry.alias ~= "") and entry.alias or entry.text
end

-- The cell a claim describes at each level: the granule for `s`, the tag / location for `t` / `l`,
-- the whole block for `w`.
local CELL = {
  s = function(span)
    return table.concat({ span.text, span.tag or "", span.location or "" }, "\0")
  end,
  t = function(span)
    return span.tag or ""
  end,
  l = function(span)
    return span.location or ""
  end,
  w = function()
    return ""
  end,
}

M.CELL = CELL

-- Every counted entry's measured span, in source order. An entry starts an interval running to the
-- next entry; a blank starts uncounted time and is dropped; the closing entry starts nothing and
-- measures zero, joining only when it carries a claim of its own (which still displays).
function M.spans(entries)
  local spans = {}
  local last = #entries

  for index, entry in ipairs(entries) do
    local starts_interval = index < last
    if not M.is_blank(entry) and (starts_interval or entry.logged ~= nil) then
      local duration, stop = 0, nil
      if starts_interval then
        local next_entry = entries[index + 1]
        -- Durations are effective UTC (`local - offset`), so an interval spanning a clock move
        -- (timezone crossing or DST flip) is its true length; start/stop stay raw local clock.
        duration = (next_entry.minutes - (next_entry.offset or 0))
          - (entry.minutes - (entry.offset or 0))
        stop = next_entry.minutes
      end

      local logged = entry.logged
      local span = {
        start = entry.minutes,
        stop = stop,
        duration = duration,
        text = M.label(entry),
        tag = entry.tag,
        location = entry.location,
        nudge = entry.nudge,
        -- The whole per-level table, so every section splits at its own level; `logged` below is the
        -- summary (`s`) slice's flag, which the items rows and the time bar read.
        logged_by_level = logged,
        logged = logged ~= nil and logged.s ~= nil and true or nil,
        marked = logged ~= nil or nil,
        source_entry_row = entry.row,
      }

      -- Name-set keys (flat strings, "" when unnamed) split each level's cell; the parallel display
      -- lists (nil when the level is unmarked) ride along for rendering the marker.
      for _, level in ipairs(syntax.LOGGED_LEVELS) do
        local marker = logged and logged[level]
        span[level .. "_names_key"] = syntax.names_key(marker)
        span[level .. "_names"] = marker and marker.names or nil
      end

      spans[#spans + 1] = span
    end
  end

  return spans
end

-- Group spans by `key_fn`, keeping first-seen order; each group carries its member indices (into
-- `spans`), its measured total, and its first span as the anchor. A nil key drops the span.
function M.group(spans, key_fn)
  local by_key, order = {}, {}

  for index, span in ipairs(spans) do
    local key = key_fn(span)
    local found = key ~= nil and by_key[key] or nil
    if key ~= nil and not found then
      found = { key = key, first = span, members = {}, measured = 0 }
      by_key[key] = found
      order[#order + 1] = found
    end
    if found then
      found.members[#found.members + 1] = index
      found.measured = found.measured + span.duration
    end
  end

  return order
end

-- The display rows the honest pass quantizes: one per (granule, s-slice). Marked and unmarked runs of
-- one activity are separate rows, so each carries its own honest baseline.
local function row_key(span)
  return table.concat({
    span.text,
    span.tag or "",
    span.location or "",
    span.logged and "1" or "0",
    span.s_names_key,
  }, "\1")
end

M.row_key = row_key

-- The claims at `level`, in first-appearance order: one per (cell, name-set) over the spans marked
-- there. `value` is the slice total every member repeats -- members stating different values are the
-- textual conflict, reported on the group's first entry.
function M.claims_at(spans, level)
  local cell_of = CELL[level]
  local groups = M.group(spans, function(span)
    if not (span.logged_by_level and span.logged_by_level[level]) then
      return nil
    end
    return cell_of(span) .. "\1" .. span[level .. "_names_key"]
  end)

  local claims = {}
  for _, found in ipairs(groups) do
    local marker = found.first.logged_by_level[level]
    local claim = {
      level = level,
      members = found.members,
      value = marker.minutes,
      names = marker.names,
      names_key = found.first[level .. "_names_key"],
      row = found.first.source_entry_row,
    }
    for _, index in ipairs(found.members) do
      if spans[index].logged_by_level[level].minutes ~= claim.value then
        claim.disagrees = true
      end
    end
    claims[#claims + 1] = claim
  end

  return claims
end

-- Split `total` across `weights` proportionally, in whole buckets by largest remainder (ties by
-- position). With nothing measured at all the first member takes it.
local function split(total, weights, bucket_minutes)
  local weight_total = 0
  for _, weight in ipairs(weights) do
    weight_total = weight_total + weight
  end

  local parts, ranked, dealt = {}, {}, 0
  for i, weight in ipairs(weights) do
    local exact
    if weight_total > 0 then
      exact = total * weight / weight_total
    elseif i == 1 then
      exact = total
    else
      exact = 0
    end

    parts[i] = math.floor(exact / bucket_minutes) * bucket_minutes
    dealt = dealt + parts[i]
    ranked[i] = { index = i, remainder = exact - parts[i] }
  end

  table.sort(ranked, function(a, b)
    if a.remainder == b.remainder then
      return a.index < b.index
    end
    return a.remainder > b.remainder
  end)

  local leftover, at = total - dealt, 1
  while leftover > 0 and ranked[at] do
    local step = math.min(bucket_minutes, leftover)
    parts[ranked[at].index] = parts[ranked[at].index] + step
    leftover = leftover - step
    at = at + 1
  end

  return parts
end

-- Move `delta` minutes across `members` in whole buckets, round-robin from the first, a sub-bucket
-- residue landing on the next recipient -- the redistribution a balance would produce.
local function deal(shares, members, delta, bucket_minutes)
  local sign = delta < 0 and -1 or 1
  local remaining = math.abs(delta)

  while remaining > 0 do
    local moved = 0
    for _, index in ipairs(members) do
      local step = math.min(bucket_minutes, remaining)
      if sign < 0 then
        -- A deficit skips a share already at zero; a share never goes negative.
        step = math.min(step, shares[index])
      end
      shares[index] = shares[index] + sign * step
      remaining = remaining - step
      moved = moved + step
      if remaining == 0 then
        break
      end
    end
    if moved == 0 then
      break
    end
  end
end

-- Quantize the display rows honestly (marker-blind, largest remainder over the whole counted day),
-- then split each row's value over its member spans: the per-entry baseline every claim pins from.
local function honest_shares(spans, rows, bucket_minutes)
  local measured = 0
  for _, row in ipairs(rows) do
    measured = measured + row.measured
  end

  local pool = {}
  for i, row in ipairs(rows) do
    pool[i] = { unrounded_duration = row.measured, nudge = row.nudge }
  end

  local quantized = quantize.quantize_rows(
    pool,
    bucket_minutes,
    quantize.round_to_nearest_bucket(measured, bucket_minutes)
  )

  local shares = {}
  for i, row in ipairs(rows) do
    row.duration = quantized[i].duration
    row.nudge_below_zero = quantized[i].nudge_below_zero
    local weights = {}
    for at, index in ipairs(row.members) do
      weights[at] = spans[index].duration
    end
    local parts = split(row.duration, weights, bucket_minutes)
    for at, index in ipairs(row.members) do
      shares[index] = parts[at]
    end
  end

  return shares
end

-- Pin every claim's members, finest-to-coarsest. A claim distributes only its remainder over the
-- members no finer claim has pinned; when the pinned members alone already hold a different total,
-- or hold more than the claim states, no assignment realizes it -- that is the conflict.
local function pin(spans, shares, bucket_minutes)
  local pinned = {}

  for _, level in ipairs(syntax.LOGGED_LEVELS) do
    for _, claim in ipairs(M.claims_at(spans, level)) do
      if claim.disagrees then
        return {
          row = claim.row,
          message = string.format(
            "logged entries for this %s disagree on their !%s value",
            LEVEL_NOUN[level],
            level:upper()
          ),
        }
      end

      local held, free, loose = 0, {}, 0
      for _, index in ipairs(claim.members) do
        if pinned[index] then
          held = held + shares[index]
        else
          free[#free + 1] = index
          loose = loose + shares[index]
        end
      end

      local room = claim.value - held
      if room < 0 or (#free == 0 and room ~= 0) then
        return {
          row = claim.row,
          message = string.format(
            "this !%s claim of %dm contradicts the finer claims on its entries, which hold %dm",
            level:upper(),
            claim.value,
            held
          ),
        }
      end

      deal(shares, free, room - loose, bucket_minutes)
      for _, index in ipairs(claim.members) do
        pinned[index] = true
      end
    end
  end

  return nil
end

-- Resolve a block's entries into the displayed share every section sums: spans in source order,
-- their shares, and the display rows behind them. Returns the state plus the conflict when the
-- claims cannot be realized -- the shares then stay honest, so a section still foots.
function M.resolve(entries, bucket_minutes)
  local spans = M.spans(entries)
  local rows = M.group(spans, row_key)

  for _, row in ipairs(rows) do
    for _, index in ipairs(row.members) do
      local nudge = spans[index].nudge
      -- Every entry of a balanced row carries that row's one nudge; the largest wins a hand-edit.
      if nudge and nudge ~= 0 and (not row.nudge or math.abs(nudge) > math.abs(row.nudge)) then
        row.nudge = nudge
      end
    end
  end

  local shares = honest_shares(spans, rows, bucket_minutes)
  local conflict = pin(spans, shares, bucket_minutes)
  if conflict then
    shares = honest_shares(spans, rows, bucket_minutes)
  end

  return { spans = spans, shares = shares, rows = rows, bucket_minutes = bucket_minutes }, conflict
end

-- The conflict a block's claims raise, or nil. The analyzer's block diagnostic, so a contradicted
-- log stops being summarized and every entry command refuses until it is fixed.
function M.conflict(entries, bucket_minutes)
  local _, conflict = M.resolve(entries, bucket_minutes)
  return conflict
end

return M
