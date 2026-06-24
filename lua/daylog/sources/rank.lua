local document = require("daylog.document")
local analyze = require("daylog.analyze")

local M = {}

-- Worklog-frecency ranking of source items (PURE).
--
-- Reorders a source's cached items so the ones you actually work on lead: an item whose
-- inserted text appears in your recent daylogs floats up. The signal is your daybook (no
-- hidden state) keyed on the entry text, so this one ranker serves every source. The
-- daybook scan that feeds build_usage is the only impure part and lives in the picker
-- shell (pick.lua); everything here is pure over plain tables.

-- Open before unknown before done, so a normalized `active` flag breaks ties sensibly
-- without forcing every source to set it.
local function active_rank(active)
  if active == true then
    return 2
  elseif active == false then
    return 0
  end
  return 1
end

-- Build a usage map from recent daylogs: activity text -> { count, latest }.
-- `day_line_lists` is { { date = <timestamp>, lines = <string[]> }, ... }. Every entry in
-- every log block counts as having-worked-on its activity; `latest` is the most recent
-- date the text appears, `count` the number of matching entries across the window.
function M.build_usage(day_line_lists)
  local usage = {}
  for _, day in ipairs(day_line_lists) do
    local analysis = analyze.analyze(document.parse(day.lines))
    for _, block in ipairs(analysis.log_blocks) do
      for _, entry in ipairs(block.entries) do
        local text = entry.text
        if text and text ~= "" then
          local seen = usage[text]
          if not seen then
            usage[text] = { count = 1, latest = day.date }
          else
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

-- Order items by relevance (descending): worklog recency, then worklog count, then the
-- normalized `active` flag, then the tracker `updated` timestamp (ISO-8601, lexical),
-- then the original order. ctx = { usage, key_of }. `key_of(item)` returns the entry text
-- the item would be logged as, so it matches build_usage's keys. Stable -- the original
-- index is the final tiebreaker, so items that tie on every signal keep their input order.
function M.order(items, ctx)
  local usage = ctx.usage or {}
  local key_of = ctx.key_of

  local decorated = {}
  for index, item in ipairs(items) do
    local used = key_of and usage[key_of(item)] or nil
    decorated[index] = {
      item = item,
      index = index,
      latest = used and used.latest or nil,
      count = used and used.count or 0,
    }
  end

  table.sort(decorated, function(a, b)
    -- worklog recency: a logged item leads; never-logged sorts last
    if a.latest ~= b.latest then
      if a.latest == nil then
        return false
      end
      if b.latest == nil then
        return true
      end
      return a.latest > b.latest
    end
    if a.count ~= b.count then
      return a.count > b.count
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
