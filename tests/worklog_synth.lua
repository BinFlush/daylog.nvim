-- General-purpose random worklog generator for property/fuzz tests.
--
-- Knows nothing about any specific invariant: given a seeded RNG (tests/rng.lua)
-- it emits a uniformly random VALID worklog -- header plus sorted timestamped
-- entries with optional sticky tags/locations, notes, #ooo, clears (#-/@-), and
-- !L, occasionally closing at 24:00. Returns { lines, params }; `params` carries
-- the sampled knobs for failure reporting. Reusable by any worklog property test.

local WORDS = {
  "planning",
  "review",
  "email",
  "standup",
  "coding",
  "design",
  "research",
  "meeting",
  "testing",
  "deploy",
  "support",
  "writing",
  "reading",
  "debug",
  "refactor",
  "interview",
  "lunch",
  "errand",
  "commute",
  "sync",
  "demo",
  "retro",
  "grooming",
  "oncall",
  "docs",
  "release",
  "triage",
  "pairing",
  "spike",
  "cleanup",
}

local NOTE_WORDS = {
  "followed",
  "up",
  "with",
  "team",
  "about",
  "the",
  "new",
  "approach",
  "and",
  "discussed",
  "blockers",
  "next",
  "steps",
  "remaining",
  "work",
  "later",
  "todo",
  "fixed",
  "issue",
  "in",
  "module",
  "see",
  "ticket",
  "for",
  "details",
}

local function hhmm(minutes)
  if minutes == 1440 then
    return "24:00"
  end
  return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

-- `count` distinct identifier names (word + a unique letter suffix, so no digits
-- that might trip metadata parsing). Used for the tag and location pools.
local function distinct_names(rng, count)
  local out = {}
  for i = 1, count do
    out[i] = rng:choice(WORDS) .. string.char(96 + i)
  end
  return out
end

-- Activity-name source: `fresh()` yields a never-before-used name; `reuse()`
-- returns a uniformly random prior distinct name. With per-entry P(fresh) = p,
-- expected distinct names = 1 + (n-1)p (0 -> all same, 1 -> all different).
local function name_pool(rng)
  local distinct = {}
  local counter = 0
  return {
    fresh = function()
      counter = counter + 1
      local name = rng:choice(WORDS) .. counter
      distinct[#distinct + 1] = name
      return name
    end,
    reuse = function()
      return rng:choice(distinct)
    end,
    count = function()
      return #distinct
    end,
  }
end

local P_CLEAR = 0.15 -- when changing tag/location, chance of a clear (#-/@-)
local P_OOO = 0.15 -- when changing tag, chance it is #ooo
local P_MIDNIGHT = 0.2 -- chance (n >= 2) the worklog closes at 24:00

return function(rng)
  local params = {
    n = rng:int(1, 100),
    q = rng:int(1, 60),
    d = rng:choice({ "dec", "hm" }),
    p_diff = rng:random(),
    p_tag = rng:random(),
    p_loc = rng:random(),
    p_note = 0.5 * rng:random(),
    p_log = rng:random(),
    tag_pool_n = rng:int(1, 6),
    loc_pool_n = rng:int(1, 5),
    init_tag = rng:chance(0.5),
    init_loc = rng:chance(0.5),
  }

  local tags = distinct_names(rng, params.tag_pool_n)
  local locs = distinct_names(rng, params.loc_pool_n)
  local names = name_pool(rng)

  local header = { "--- worklog" }
  if params.init_tag then
    header[#header + 1] = "#" .. rng:choice(tags)
  end
  if params.init_loc then
    header[#header + 1] = "@" .. rng:choice(locs)
  end
  header[#header + 1] = "q=" .. params.q
  header[#header + 1] = "d=" .. params.d
  local lines = { table.concat(header, " ") .. " ---" }

  local times = rng:distinct(params.n, 0, 1439)
  if params.n >= 2 and rng:chance(P_MIDNIGHT) then
    times[#times] = 1440 -- still the maximum, so it stays the final entry
  end

  for i = 1, #times do
    if i == #times and times[i] == 1440 then
      lines[#lines + 1] = "24:00"
    else
      local name
      if i == 1 or names.count() == 0 or rng:chance(params.p_diff) then
        name = names.fresh()
      else
        name = names.reuse()
      end

      local parts = { hhmm(times[i]), name }

      if rng:chance(params.p_tag) then
        if rng:chance(P_CLEAR) then
          parts[#parts + 1] = "#-"
        elseif rng:chance(P_OOO) then
          parts[#parts + 1] = "#ooo"
        else
          parts[#parts + 1] = "#" .. rng:choice(tags)
        end
      end

      if rng:chance(params.p_loc) then
        if rng:chance(P_CLEAR) then
          parts[#parts + 1] = "@-"
        else
          parts[#parts + 1] = "@" .. rng:choice(locs)
        end
      end

      if rng:chance(params.p_log) then
        parts[#parts + 1] = "!L"
      end

      lines[#lines + 1] = table.concat(parts, " ")

      if rng:chance(params.p_note) then
        for _ = 1, rng:int(1, 3) do
          local words = {}
          local word_count = rng:int(1, 6)
          for w = 1, word_count do
            words[w] = rng:choice(NOTE_WORDS)
          end
          lines[#lines + 1] = table.concat(words, " ")
        end
      end
    end
  end

  return { lines = lines, params = params }
end
