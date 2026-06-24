local document = require("daylog.document")
local analyze = require("daylog.analyze")

local M = {}

-- Worklog-frecency ranking of source items (PURE).
--
-- Reorders a source's cached items so the ones you actually work on lead, by a time-decayed
-- "frecency" score over your recent daylogs: each logged event contributes a base amount plus
-- the time tracked on it, discounted by how long ago it was. That single sum folds recency
-- (the decay), frequency (the number of events) and duration (the minutes) together. The signal
-- is your daybook (no hidden state) keyed on the entry text, so one ranker serves every source.
-- The daybook scan that feeds build_usage is the only impure part and lives in the picker shell
-- (pick.lua); everything here is pure over plain tables.

-- Open before unknown before done, so a normalized `active` flag breaks ties sensibly without
-- forcing every source to set it.
local function active_rank(active)
  if active == true then
    return 2
  elseif active == false then
    return 0
  end
  return 1
end

-- Effective-UTC gap between two entries: subtract each entry's offset so an interval that spans
-- a timezone/DST move measures its true length; with no offsets it is just b.minutes - a.minutes.
-- (The same formula summary.build_intervals uses for durations.)
local function interval_minutes(a, b)
  return (b.minutes - (b.offset or 0)) - (a.minutes - (a.offset or 0))
end

-- Build a usage map from recent daylogs for the time-decayed frecency score. `day_line_lists`
-- is { { date = <timestamp>, lines = <string[]> }, ... }. Each logged entry contributes to its
-- activity, weighted by recency `w = 0.5 ^ (age_days / half_life_days)`: `freq` accumulates `w`
-- (a decayed event count) and `time` accumulates `w * minutes` (its tracked duration -- the gap
-- to the next entry). `count` and `latest` are carried for reference and a custom picker.rank.
-- Pure: `now` and `half_life_days` are passed in.
function M.build_usage(day_line_lists, now, half_life_days)
  local usage = {}
  for _, day in ipairs(day_line_lists) do
    local w = 0.5 ^ ((now - day.date) / 86400 / half_life_days)
    local analysis = analyze.analyze(document.parse(day.lines))
    for _, block in ipairs(analysis.log_blocks) do
      local entries = block.entries
      for i, entry in ipairs(entries) do
        local text = entry.text
        if text and text ~= "" then
          -- The last entry of a block has no successor -> 0 minutes (in progress); it still
          -- counts toward freq, so the item you just started ranks by recency.
          local nxt = entries[i + 1]
          local minutes = nxt and math.max(0, interval_minutes(entry, nxt)) or 0

          local seen = usage[text]
          if not seen then
            usage[text] = { freq = w, time = w * minutes, count = 1, latest = day.date }
          else
            seen.freq = seen.freq + w
            seen.time = seen.time + w * minutes
            seen.count = seen.count + 1
            if day.date > seen.latest then
              seen.latest = day.date
            end
          end
        end
      end
    end
  end
  return usage
end

-- Order items by relevance (descending). The worklog score is `base * freq + time` -- the
-- decayed frequency weighted against the decayed duration -- so it is positive for anything you
-- have logged and 0 otherwise. ctx = { usage, key_of, base }; `key_of(item)` returns the entry
-- text the item would be logged as, matching build_usage's keys. Never-logged items (and exact
-- ties) fall back to the normalized `active` flag, then the tracker `updated` timestamp, then
-- the original index (stable -- items that tie on everything keep their input order).
function M.order(items, ctx)
  local usage = ctx.usage or {}
  local key_of = ctx.key_of
  local base = ctx.base
  if base == nil then
    base = 30
  end

  local decorated = {}
  for index, item in ipairs(items) do
    local used = key_of and usage[key_of(item)] or nil
    decorated[index] = {
      item = item,
      index = index,
      score = used and (base * used.freq + used.time) or 0,
    }
  end

  table.sort(decorated, function(a, b)
    -- worklog relevance: decayed frequency + duration
    if a.score ~= b.score then
      return a.score > b.score
    end

    -- normalized active flag: open before done
    local ar, br = active_rank(a.item.active), active_rank(b.item.active)
    if ar ~= br then
      return ar > br
    end

    -- tracker recency: ISO-8601 sorts lexically; missing sorts last
    local au, bu = a.item.updated, b.item.updated
    if au ~= bu then
      if au == nil then
        return false
      end
      if bu == nil then
        return true
      end
      return au > bu
    end

    -- full tie: preserve input order
    return a.index < b.index
  end)

  local ordered = {}
  for i, d in ipairs(decorated) do
    ordered[i] = d.item
  end
  return ordered
end

return M
