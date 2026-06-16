-- Deterministic, seedable uniform RNG for property/fuzz tests.
--
-- Park-Miller "minimal standard" LCG: state = (16807 * state) mod (2^31 - 1).
-- Pure double arithmetic -- 16807 * state < 2^46 < 2^53, so every step is exact
-- in Lua/LuaJIT doubles and reproducible across versions and machines. A failing
-- fuzz case therefore replays exactly from its printed seed.

local M = {}
M.__index = M

local MODULUS = 2147483647 -- 2^31 - 1
local MAX_STATE = MODULUS - 1 -- 2147483646

local function normalize(seed)
  local s = math.floor(seed) % MODULUS
  if s <= 0 then
    s = s + MAX_STATE
  end
  return s
end

function M.new(seed)
  local self = setmetatable({ state = normalize(seed or 1) }, M)
  -- Warm up so small/sequential seeds still produce well-mixed streams.
  for _ = 1, 3 do
    self:random()
  end
  return self
end

-- Uniform float in [0, 1).
function M:random()
  self.state = (16807 * self.state) % MODULUS
  return (self.state - 1) / MAX_STATE
end

-- Uniform integer in [lo, hi] inclusive.
function M:int(lo, hi)
  return lo + math.floor(self:random() * (hi - lo + 1))
end

-- True with probability p.
function M:chance(p)
  return self:random() < p
end

-- Uniform element of a non-empty array.
function M:choice(list)
  return list[self:int(1, #list)]
end

-- `count` distinct integers in [lo, hi] (capped at the range size), sorted ascending.
function M:distinct(count, lo, hi)
  count = math.min(count, hi - lo + 1)
  local seen = {}
  local out = {}
  while #out < count do
    local v = self:int(lo, hi)
    if not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  table.sort(out)
  return out
end

return M
