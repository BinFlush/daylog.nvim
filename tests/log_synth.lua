-- Multi-mode random log generator for property/fuzz tests.
--
-- Knows nothing about any specific invariant: given a seeded RNG (tests/rng.lua)
-- and a mode name it emits a random VALID log -- header plus sorted
-- timestamped entries with optional sticky tags/locations, notes, #ooo, clears
-- (#-/@-), !S[], occasional UTC offsets (utc±H), occasional manual rounding nudges
-- (round±N), occasionally closing at 24:00. Returns { lines, params }; `params`
-- carries the sampled knobs (including `mode`) for failure reporting.
--
-- UTC offsets, when used, walk monotonically downward across the day (a westward
-- traveller). Local times are strictly increasing and the offsets never increase,
-- so effective UTC time is strictly increasing too -- the log stays valid (no
-- false unordered-timestamps) while exercising the offset-reconciled duration math.
--
-- Modes only pick distributions; the emitted structure is identical:
--   * maximal -- the general, assumption-free stress mode (whole clock, every q).
--   * workday -- a ~7-to-5 day; several q values do not foot cleanly (1, 5, 10).
--   * billing -- precise client tracking (q = 1 or 0.1h), heavy !S[], decimal hours.
-- Reusable by any log property test.

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

local syntax = require("daylog.syntax")

-- Plausible UTC offsets in signed minutes, east to west. A log that uses
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
  -- Precise client tracking: exact q (1, or 0.1h buckets), heavy !S[], decimal
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

  local header = { "--- log" }
  local header_tag, header_loc
  if params.init_tag then
    header_tag = rng:choice(tags)
    header[#header + 1] = "#" .. header_tag
  end
  if params.init_loc then
    header_loc = rng:choice(locs)
    header[#header + 1] = "@" .. header_loc
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

  -- Resolved sticky state, and the per-entry facts the claim pass below needs: an entry's cell at
  -- each level, its effective-UTC clock, and whether it already carries a nudge.
  local cur_tag, cur_loc = header_tag, header_loc
  local slot, effective = {}, {}

  for i = 1, #times do
    if i == #times and times[i] == 1440 then
      effective[i] = times[i] - (current_offset or 0)
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
          cur_tag = nil
        elseif rng:chance(cfg.p_ooo) then
          parts[#parts + 1] = "#ooo"
          cur_tag = "ooo"
        else
          cur_tag = rng:choice(tags)
          parts[#parts + 1] = "#" .. cur_tag
        end
      end

      if rng:chance(params.p_loc) then
        if rng:chance(cfg.p_clear) then
          parts[#parts + 1] = "@-"
          cur_loc = nil
        else
          cur_loc = rng:choice(locs)
          parts[#parts + 1] = "@" .. cur_loc
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

      effective[i] = times[i] - (current_offset or 0)
      slot[i] = { name = name, tag = cur_tag, loc = cur_loc }

      -- An occasional manual rounding nudge (round±N): a small up/down q-step shift the balance use
      -- case would write. A nudged entry is never claimed below -- a claim freezes its row, so a
      -- nudge there is refused outright. Footing must still hold with these in play.
      if rng:chance(cfg.p_nudge) then
        parts[#parts + 1] = syntax.round_nudge_token(rng:choice({ -2, -1, 1, 2 }))
        slot[i].nudged = true
      end

      lines[#lines + 1] = table.concat(parts, " ")
      slot[i].row = #lines

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

  -- Claims, derived from the time each slice actually measured. Unrelated random values across four
  -- levels contradict each other almost always -- an outcome the engine correctly refuses, which
  -- leaves the pinning pass itself unexercised -- so each claim starts from its slice's measured
  -- total and is perturbed a bucket or two: it lands above and below the honest value while most
  -- logs still resolve. The value is the SLICE total, repeated verbatim on every member (the shape
  -- every valid log has), and a nudged entry is never a member.
  local CELL = {
    S = function(at)
      return table.concat({ at.name, at.tag or "", at.loc or "" }, "\1")
    end,
    T = function(at)
      return at.tag or ""
    end,
    L = function(at)
      return at.loc or ""
    end,
    W = function()
      return ""
    end,
  }

  local function duration_at(i)
    return effective[i + 1] and (effective[i + 1] - effective[i]) or 0
  end

  -- A bracketed name-set: 0-3 real names, sometimes seeded with the unnamed element (an empty first
  -- slot -> `!S[,n1]`), and sometimes empty (the explicit unnamed `!S[]`). The parser dedupes and
  -- sorts, so canonicalize here too, or one slice would be handed two spellings and two values.
  local function pick_names()
    if not rng:chance(0.3) then
      return "[]"
    end
    local picked = {}
    if rng:chance(0.25) then
      picked[#picked + 1] = ""
    end
    for _ = 1, rng:int(0, 3) do
      picked[#picked + 1] = rng:choice({ "n1", "n2", "n3", "n4" })
    end
    local seen, canonical = {}, {}
    for _, name in ipairs(picked) do
      if not seen[name] then
        seen[name] = true
        canonical[#canonical + 1] = name
      end
    end
    table.sort(canonical)
    return "[" .. table.concat(canonical, ",") .. "]"
  end

  local markers_at = {}
  for _, level in ipairs({ "S", "T", "L", "W" }) do
    local cells, order = {}, {}
    for i = 1, #times do
      local at = slot[i]
      if at and not at.nudged then
        local key = CELL[level](at)
        if not cells[key] then
          cells[key] = {}
          order[#order + 1] = key
        end
        table.insert(cells[key], i)
      end
    end

    for _, key in ipairs(order) do
      if rng:chance(params.p_log) then
        local members, measured = {}, 0
        for _, i in ipairs(cells[key]) do
          -- A partial slice leaves the cell a plain remainder row beside its claim.
          if rng:chance(0.75) then
            table.insert(members, i)
            measured = measured + duration_at(i)
          end
        end
        if #members > 0 then
          local q = params.q
          local value = math.floor((measured + q / 2) / q) * q + rng:int(-2, 2) * q
          value = math.max(0, math.min(syntax.END_OF_DAY_MINUTES, value))
          local suffix = pick_names()
          for _, i in ipairs(members) do
            markers_at[i] = markers_at[i] or {}
            table.insert(markers_at[i], level .. suffix .. value)
          end
        end
      end
    end
  end

  -- Emit each entry's markers, compact (`!S[]60T[]90`) or separated (`!S[]60 !T[]90`); the per-level
  -- loop above already built them in canonical S T L W order.
  for i = 1, #times do
    local markers = markers_at[i]
    if markers then
      local row = slot[i].row
      if rng:chance(0.5) then
        lines[row] = lines[row] .. " !" .. table.concat(markers)
      else
        for _, marker in ipairs(markers) do
          lines[row] = lines[row] .. " !" .. marker
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
