local document = require("daylog.document")
local analyze = require("daylog.analyze")
local summary = require("daylog.summary")

local M = {}

-- Daylog-frecency ranking of source items (PURE).
--
-- Mozilla-style frecency over recent daylogs, keyed on each entry's resolved label so one ranker
-- serves every source; the impure daybook scan lives in the picker shell (pick.lua).

-- Open before unknown before done, so a normalized `active` flag breaks ties without forcing
-- every source to set it.
local function active_rank(active)
  if active == true then
    return 2
  elseif active == false then
    return 0
  end
  return 1
end

-- Firefox frecency defaults: sample the 10 most recent visits; a visit scores 100 within 4 days,
-- then 70 / 50 / 30 by 14 / 31 / 90 days, 10 beyond.
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

-- Mozilla frecency for visit timestamps: average the recency weight of the most recent
-- SAMPLE_SIZE, scaled by the full count. Sorts `dates` in place (caller owns it).
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

-- The daylog relevance score: the frecency precomputed in build_usage, or 0 for a never-logged
-- item.
local function score_for(used)
  return used and used.score or 0
end

-- Accumulate one visit for `key` dated `date` into a visits map (init or extend).
local function add_visit(visits, key, date)
  local seen = visits[key]
  if not seen then
    visits[key] = { dates = { date }, latest = date }
  else
    seen.dates[#seen.dates + 1] = date
    if date > seen.latest then
      seen.latest = date
    end
  end
end

-- Score an accumulated visits map into `{ key -> { count, latest, score } }`.
local function score_visits(visits, now)
  local usage = {}
  for key, seen in pairs(visits) do
    usage[key] = {
      count = #seen.dates,
      latest = seen.latest,
      score = frecency(seen.dates, now),
    }
  end
  return usage
end

-- Build a frecency usage map from recent daylogs. Every logged entry is a "visit" keyed on its
-- resolved label (alias else description) -- matching key_of -- so bare and mapped count as one.
-- Each value carries `count`, `latest`, and `score`. Pure: `now` is passed in.
function M.build_usage(day_line_lists, now)
  local visits = {}
  for _, day in ipairs(day_line_lists) do
    local analysis = analyze.analyze(document.parse(day.lines))
    for _, block in ipairs(analysis.log_blocks) do
      for _, entry in ipairs(block.entries) do
        -- Key on the resolved label so a mapped entry credits its target, not a duplicate.
        local text = summary.entry_summary_text(entry)
        if text and text ~= "" then
          add_visit(visits, text, day.date)
        end
      end
    end
  end

  return score_visits(visits, now)
end

-- Build per-level frecency usage maps of the logging names across recent daylogs. For each logged
-- entry, EACH name at each level scores one visit dated that day -- so a name used once a day for N
-- days scores exactly as an activity would. Returns `{ s = <name->usage>, t, l, w }` (empty maps
-- when unused). Pure: `now` is passed in.
function M.build_name_usage(day_line_lists, now)
  local visits = { s = {}, t = {}, l = {}, w = {} }
  for _, day in ipairs(day_line_lists) do
    local analysis = analyze.analyze(document.parse(day.lines))
    for _, block in ipairs(analysis.log_blocks) do
      for _, entry in ipairs(block.entries) do
        for level, bucket in pairs(visits) do
          local marker = entry.logged and entry.logged[level]
          if marker and marker.names then
            for _, name in ipairs(marker.names) do
              -- The unnamed name ("") is not a real corpus name; it is the synthetic "(unnamed)".
              if name ~= "" then
                add_visit(bucket, name, day.date)
              end
            end
          end
        end
      end
    end
  end

  local out = {}
  for level, bucket in pairs(visits) do
    out[level] = score_visits(bucket, now)
  end
  return out
end

-- Order items by daylog frecency (desc); ties fall back to the `active` flag, then the tracker
-- `updated` timestamp, then input index (stable). ctx = { usage, key_of }; key_of matches
-- build_usage's keys.
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
      -- Admit only a string so the comparator never compares a foreign type against a string.
      updated = type(item.updated) == "string" and item.updated or nil,
    }
  end

  table.sort(decorated, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end

    -- normalized active flag: open before done
    local ar, br = active_rank(a.item.active), active_rank(b.item.active)
    if ar ~= br then
      return ar > br
    end

    -- tracker recency: ISO-8601 sorts lexically; missing sorts last
    local au, bu = a.updated, b.updated
    if au ~= bu then
      if au == nil then
        return false
      end
      if bu == nil then
        return true
      end
      return au > bu
    end

    return a.index < b.index
  end)

  local ordered = {}
  for i, d in ipairs(decorated) do
    ordered[i] = d.item
  end
  return ordered
end

-- Build one ranked, deduped pool of insertable rows from several sources' items plus leftover
-- recent activities (daylog texts no item claims). PURE. Each item is a row keyed on its entry
-- text; an unclaimed usage key becomes an `activity` row, so a matching activity appears once.
-- Rows sort by frecency (desc), then item-before-activity, then build order (stable). Returns:
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

  -- pairs() walks in hash order, so sort the leftover keys -- otherwise tied activities' final
  -- order is nondeterministic.
  local activity_keys = {}
  for key in pairs(usage) do
    if not seen[key] then
      activity_keys[#activity_keys + 1] = key
    end
  end
  table.sort(activity_keys)

  for _, key in ipairs(activity_keys) do
    rows[#rows + 1] = {
      kind = "activity",
      text = key,
      key = key,
      display = key,
      score = score_for(usage[key]),
      order = #rows + 1,
    }
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
