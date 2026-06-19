-- Multi-mode random worklog generator for property/fuzz tests.
--
-- Knows nothing about any specific invariant: given a seeded RNG (tests/rng.lua)
-- and a mode name it emits a random VALID worklog -- header plus sorted
-- timestamped entries with optional sticky tags/locations, notes, #ooo, clears
-- (#-/@-), !L, occasional UTC offsets (utc±H), occasional manual rounding nudges
-- (round±N), occasionally closing at 24:00. Returns { lines, params }; `params`
-- carries the sampled knobs (including `mode`) for failure reporting.
--
-- UTC offsets, when used, walk monotonically downward across the day (a westward
-- traveller). Local times are strictly increasing and the offsets never increase,
-- so effective UTC time is strictly increasing too -- the worklog stays valid (no
-- false unordered-timestamps) while exercising the offset-reconciled duration math.
--
-- Modes only pick distributions; the emitted structure is identical:
--   * maximal -- the general, assumption-free stress mode (whole clock, every q).
--   * workday -- a ~7-to-5 day; several q values do not foot cleanly (1, 5, 10).
--   * billing -- precise client tracking (q = 1 or 0.1h), heavy !L, decimal hours.
-- Reusable by any worklog property test.

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

local syntax = require("blotter.syntax")

-- Plausible UTC offsets in signed minutes, east to west. A worklog that uses
-- offsets walks this list downward only (never back east), which keeps effective
-- time strictly increasing for strictly increasing local times.
local UTC_OFFSETS = { 330, 120, 60, 0, -240, -300, -480 }

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

-- Per-mode distributions. Ranges are inclusive int `{lo, hi}` (n, pools, start,
-- finish) or float `{lo, hi}` (probabilities, sampled via `float_in`). `q` is
-- either a `q_set` list (sampled uniformly) or an int `{lo, hi}` range. `times`
-- selects the strategy ("uniform" | "bounded"); bounded reads `start`/`finish`.
local MODE_CONFIG = {
  -- The general stress mode: the whole clock, every q, all probabilities
  -- uniform. This reproduces the original generator's distributions.
  maximal = {
    times = "uniform",
    p_midnight = 0.2,
    n = { 1, 100 },
    q = { 1, 60 },
    d_dec = 0.5,
    p_diff = { 0, 1 },
    p_tag = { 0, 1 },
    p_loc = { 0, 1 },
    p_note = { 0, 0.5 },
    p_log = { 0, 1 },
    tag_pool = { 1, 6 },
    loc_pool = { 1, 5 },
    p_init_tag = 0.5,
    p_init_loc = 0.5,
    p_clear = 0.15,
    p_ooo = 0.15,
    p_utc = 0.3,
    p_nudge = 0.2,
  },
  -- A ~7-to-5 day: a bounded span, a handful of tasks, q values several of
  -- which do not foot cleanly, an occasional break (#ooo), light notes/logging.
  workday = {
    times = "bounded",
    start = { 390, 480 }, -- 06:30 - 08:00
    finish = { 960, 1080 }, -- 16:00 - 18:00
    n = { 8, 20 },
    q_set = { 1, 5, 10, 15, 30 }, -- 1, 5, 10 do not foot cleanly
    d_dec = 0.6,
    p_diff = { 0.3, 0.9 },
    p_tag = { 0.2, 0.6 },
    p_loc = { 0, 0.3 },
    p_note = { 0, 0.25 },
    p_log = { 0, 0.4 },
    tag_pool = { 1, 4 },
    loc_pool = { 1, 2 },
    p_init_tag = 0.5,
    p_init_loc = 0.3,
    p_clear = 0.15,
    p_ooo = 0.15,
    p_utc = 0.2,
    p_nudge = 0.15,
  },
  -- Precise client tracking: exact q (1, or 0.1h buckets), heavy !L, decimal
  -- hours, a wider client (tag) pool, rare breaks.
  billing = {
    times = "bounded",
    start = { 420, 540 }, -- 07:00 - 09:00
    finish = { 960, 1140 }, -- 16:00 - 19:00
    n = { 8, 25 },
    q_set = { 1, 6 },
    d_dec = 0.85,
    p_diff = { 0.5, 1 },
    p_tag = { 0.3, 0.8 },
    p_loc = { 0, 0.3 },
    p_note = { 0.1, 0.4 },
    p_log = { 0.5, 1 },
    tag_pool = { 2, 5 },
    loc_pool = { 1, 2 },
    p_init_tag = 0.5,
    p_init_loc = 0.2,
    p_clear = 0.15,
    p_ooo = 0.08,
    p_utc = 0.15,
    p_nudge = 0.1,
  },
}

local function hhmm(minutes)
  if minutes == 1440 then
    return "24:00"
  end
  return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

-- Uniform float in the inclusive range `{lo, hi}`.
local function float_in(rng, range)
  return range[1] + (range[2] - range[1]) * rng:random()
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

-- Sorted distinct entry times for `n` entries. "uniform" spans the whole clock
-- and may overwrite the final entry with 24:00; "bounded" pins a morning
-- `start` and an evening `finish` with `n-2` distinct interior times between
-- them (a realistic day, never crossing midnight).
local function gen_times(rng, cfg, n)
  if cfg.times == "bounded" then
    local start = rng:int(cfg.start[1], cfg.start[2])
    local finish = rng:int(cfg.finish[1], cfg.finish[2])
    if finish <= start then
      finish = start + n -- defensive; the mode ranges already keep finish > start
    end
    if n <= 1 then
      return { start }
    end
    if n == 2 then
      return { start, finish }
    end
    local times = { start }
    for _, m in ipairs(rng:distinct(n - 2, start + 1, finish - 1)) do
      times[#times + 1] = m
    end
    times[#times + 1] = finish
    return times
  end

  local times = rng:distinct(n, 0, 1439)
  if n >= 2 and rng:chance(cfg.p_midnight) then
    times[#times] = 1440 -- still the maximum, so it stays the final entry
  end
  return times
end

local function generate(rng, mode_name)
  local cfg = MODE_CONFIG[mode_name]
  assert(cfg, "unknown synth mode: " .. tostring(mode_name))

  local params = {
    mode = mode_name,
    n = rng:int(cfg.n[1], cfg.n[2]),
    d = rng:chance(cfg.d_dec) and "dec" or "hm",
    p_diff = float_in(rng, cfg.p_diff),
    p_tag = float_in(rng, cfg.p_tag),
    p_loc = float_in(rng, cfg.p_loc),
    p_note = float_in(rng, cfg.p_note),
    p_log = float_in(rng, cfg.p_log),
    tag_pool_n = rng:int(cfg.tag_pool[1], cfg.tag_pool[2]),
    loc_pool_n = rng:int(cfg.loc_pool[1], cfg.loc_pool[2]),
    init_tag = rng:chance(cfg.p_init_tag),
    init_loc = rng:chance(cfg.p_init_loc),
  }
  params.q = cfg.q_set and rng:choice(cfg.q_set) or rng:int(cfg.q[1], cfg.q[2])
  params.use_utc = rng:chance(cfg.p_utc or 0)

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

  -- The sticky offset state: when offsets are in use, start somewhere in the pool
  -- and optionally declare that base on the header (otherwise the first entry that
  -- changes it emits the token). The index only ever advances downward (westward).
  local utc_index, current_offset
  if params.use_utc then
    utc_index = rng:int(1, #UTC_OFFSETS)
    if rng:chance(0.5) then
      current_offset = UTC_OFFSETS[utc_index]
      header[#header + 1] = syntax.utc_offset_token(current_offset)
    end
  end

  header[#header + 1] = "q=" .. params.q
  header[#header + 1] = "d=" .. params.d
  local lines = { table.concat(header, " ") .. " ---" }

  local times = gen_times(rng, cfg, params.n)

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
        if rng:chance(cfg.p_clear) then
          parts[#parts + 1] = "#-"
        elseif rng:chance(cfg.p_ooo) then
          parts[#parts + 1] = "#ooo"
        else
          parts[#parts + 1] = "#" .. rng:choice(tags)
        end
      end

      if rng:chance(params.p_loc) then
        if rng:chance(cfg.p_clear) then
          parts[#parts + 1] = "@-"
        else
          parts[#parts + 1] = "@" .. rng:choice(locs)
        end
      end

      -- Advance the offset downward (never up) and emit a utc token on change, so
      -- the sticky resolution matches and effective time keeps increasing.
      if params.use_utc then
        if utc_index < #UTC_OFFSETS and rng:chance(0.25) then
          utc_index = rng:int(utc_index + 1, #UTC_OFFSETS)
        end
        local off = UTC_OFFSETS[utc_index]
        if off ~= current_offset then
          parts[#parts + 1] = syntax.utc_offset_token(off)
          current_offset = off
        end
      end

      -- An occasional manual rounding nudge (round±N): a small up/down q-step shift
      -- the balance use case would write. Footing must still hold with these in play.
      if rng:chance(cfg.p_nudge) then
        parts[#parts + 1] = syntax.round_nudge_token(rng:choice({ -2, -1, 1, 2 }))
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

return {
  generate = generate,
  MODES = { "maximal", "workday", "billing" },
}
