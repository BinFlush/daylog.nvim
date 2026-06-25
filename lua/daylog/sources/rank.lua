local document = require("daylog.document")
local analyze = require("daylog.analyze")

local M = {}

-- Worklog-frecency ranking of source items (PURE).
--
-- Reorders a source's cached items so the ones you actually work on lead, by a standard
-- Mozilla-style "frecency" over your recent daylogs. Each logged entry of an activity is a
-- "visit"; an activity scores its total visit count times the average recency weight of its
-- most recent visits, so recent *and* frequent activities rank highest (duration is not a
-- factor). The signal is your daybook (no hidden state) keyed on the entry text, so one ranker
-- serves every source. The daybook scan that feeds build_usage is the only impure part and
-- lives in the picker shell (pick.lua); everything here is pure over plain tables.

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

-- How many of the most recent visits to sample, and the recency buckets that weight them --
-- the Firefox frecency defaults: a visit in the last 4 days is worth 100, then 70 / 50 / 30 by
-- 14 / 31 / 90 days, and 10 beyond that.
local SAMPLE_SIZE = 10

local function recency_weight(age_days)
  if age_days <= 4 then
    return 100
  elseif age_days <= 14 then
    return 70
  elseif age_days <= 31 then
    return 50
  elseif age_days <= 90 then
    return 30
  end
  return 10
end

-- Standard Mozilla frecency for a list of visit timestamps: sample the most recent SAMPLE_SIZE,
-- weight each by its recency bucket, and scale the average by the full visit count. (Firefox's
-- per-visit-type bonus collapses to 1 here -- every logged entry is the same kind of visit.)
-- Returns a non-negative integer; 0 for no visits. Sorts `dates` in place (caller owns it).
local function frecency(dates, now)
  local count = #dates
  if count == 0 then
    return 0
  end
  table.sort(dates, function(a, b)
    return a > b
  end)
  local sampled = math.min(SAMPLE_SIZE, count)
  local points = 0
  for i = 1, sampled do
    points = points + recency_weight((now - dates[i]) / 86400)
  end
  return math.ceil(count * points / sampled)
end

-- The worklog relevance score: the frecency precomputed in build_usage, or 0 for a never-logged
-- item.
local function score_for(used)
  return used and used.score or 0
end

-- Build a usage map from recent daylogs for the Mozilla frecency score. `day_line_lists` is
-- { { date = <timestamp>, lines = <string[]> }, ... }. Every logged entry is a "visit" keyed on
-- its activity text (its `#tag`/`@location`/`!L` metadata peeled, matching how it is reported).
-- Each map value carries the visit `count`, the `latest` visit timestamp, and the computed
-- `score`; `count` and `latest` are kept for reference and a custom picker.rank. Pure: `now` is
-- passed in.
function M.build_usage(day_line_lists, now)
  local visits = {}
  for _, day in ipairs(day_line_lists) do
    local analysis = analyze.analyze(document.parse(day.lines))
    for _, block in ipairs(analysis.log_blocks) do
      for _, entry in ipairs(block.entries) do
        local text = entry.text
        if text and text ~= "" then
          local seen = visits[text]
          if not seen then
            visits[text] = { dates = { day.date }, latest = day.date }
          else
            seen.dates[#seen.dates + 1] = day.date
            if day.date > seen.latest then
              seen.latest = day.date
            end
          end
        end
      end
    end
  end

  local usage = {}
  for text, seen in pairs(visits) do
    usage[text] = {
      count = #seen.dates,
      latest = seen.latest,
      score = frecency(seen.dates, now),
    }
  end
  return usage
end

-- Order items by relevance (descending) on the precomputed worklog frecency -- positive for
-- anything you have logged, 0 otherwise. ctx = { usage, key_of }; `key_of(item)` returns the
-- entry text the item would be logged as, matching build_usage's keys. Never-logged items (and
-- exact ties) fall back to the normalized `active` flag, then the tracker `updated` timestamp,
-- then the original index (stable -- items that tie on everything keep their input order).
function M.order(items, ctx)
  local usage = ctx.usage or {}
  local key_of = ctx.key_of

  local decorated = {}
  for index, item in ipairs(items) do
    local used = key_of and usage[key_of(item)] or nil
    decorated[index] = {
      item = item,
      index = index,
      score = score_for(used),
    }
  end

  table.sort(decorated, function(a, b)
    -- worklog frecency
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

-- Build one ranked, deduped pool of insertable rows from several sources' items plus the
-- leftover recent activities (the worklog texts that are not a source item). PURE.
--
-- `sources` is a list of { name, items, key_of, display_for, text_of } (each fn(item)->string);
-- `ctx = { usage }`. Each item becomes a row keyed on its entry text; a usage key that no item
-- claims becomes an `activity` row -- so an activity that matches a tracker item appears once
-- (as the item). Every row carries `.text` -- what gets inserted/renamed-to when chosen (an
-- item's entry text, an activity's logged text). Rows sort by the worklog frecency (desc), then
-- item-before-activity, then their build order (stable). Returns rows:
--   { kind = "item", source = name, item, key, display, text, score }
--   { kind = "activity", key, display, text, score }
function M.build_insert_pool(sources, ctx)
  local usage = ctx.usage or {}

  local rows = {}
  local seen = {}

  for _, source in ipairs(sources) do
    for _, item in ipairs(source.items or {}) do
      local key = source.key_of(item)
      if not seen[key] then
        seen[key] = true
        rows[#rows + 1] = {
          kind = "item",
          source = source.name,
          item = item,
          key = key,
          display = source.display_for(item),
          text = source.text_of(item),
          score = score_for(usage[key]),
          order = #rows + 1,
        }
      end
    end
  end

  for key, used in pairs(usage) do
    if not seen[key] then
      rows[#rows + 1] = {
        kind = "activity",
        text = key,
        key = key,
        display = key,
        score = score_for(used),
        order = #rows + 1,
      }
    end
  end

  table.sort(rows, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    if a.kind ~= b.kind then
      return a.kind == "item"
    end
    return a.order < b.order
  end)

  return rows
end

return M
