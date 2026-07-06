-- Activity colour generation (PURE).
--
-- Builds a maximally-distinct activity palette by farthest-point sampling in OkLCH: lay a grid of
-- candidates over hue x lightness x chroma, then greedily pick the candidate whose nearest
-- already-chosen colour is farthest (distance in perceptually-uniform OkLab), seeded from a blue
-- anchor. Using all three dimensions avoids two activities collapsing onto the same xterm-256 code
-- (which hue-only schemes did, rendering identically without `termguicolors`). Chroma is trimmed per
-- colour to stay in the sRGB gamut. Computed once on first use and cached. No Neovim API.

local M = {}

local COUNT = 24 -- distinct colours generated (cycled beyond -- far past the perceptual limit)
local SEED_H, SEED_L, SEED_C = 255, 0.70, 0.13 -- the anchor colour (a blue) the search starts from
local L_LO, L_HI = 0.45, 0.92 -- lightness search range (wide, favouring distinctness over polish)
local C_LO, C_HI = 0.06, 0.15 -- chroma (saturation) search range
local H_STEPS, L_STEPS, C_STEPS = 72, 7, 5 -- candidate grid resolution (hue / lightness / chroma)

local function srgb_gamma(x)
  if x <= 0.0031308 then
    return 12.92 * x
  end
  return 1.055 * x ^ (1 / 2.4) - 0.055
end

-- OkLab -> linear sRGB (Björn Ottosson's reference matrices).
local function oklab_to_linear(lightness, a, b)
  local l_ = lightness + 0.3963377774 * a + 0.2158037573 * b
  local m_ = lightness - 0.1055613458 * a - 0.0638541728 * b
  local s_ = lightness - 0.0894841775 * a - 1.2914855480 * b
  local l, m, s = l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_
  return 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
end

local function in_gamut(r, g, b)
  local e = 1e-7
  return r >= -e and r <= 1 + e and g >= -e and g <= 1 + e and b >= -e and b <= 1 + e
end

-- The linear sRGB for hue `h` (degrees) at `lightness` and a given chroma.
local function linear_at(lightness, h, chroma)
  local hr = math.rad(h)
  return oklab_to_linear(lightness, chroma * math.cos(hr), chroma * math.sin(hr))
end

-- The largest chroma <= `target` that keeps (lightness, hue) inside the sRGB gamut (binary search).
local function fit_chroma(lightness, h, target)
  if in_gamut(linear_at(lightness, h, target)) then
    return target
  end
  local lo, hi = 0, target
  for _ = 1, 22 do
    local mid = (lo + hi) / 2
    if in_gamut(linear_at(lightness, h, mid)) then
      lo = mid
    else
      hi = mid
    end
  end
  return lo
end

local function channel(x)
  local srgb = srgb_gamma(math.max(0, math.min(1, x)))
  return math.max(0, math.min(255, math.floor(srgb * 255 + 0.5)))
end

-- xterm-256: the 6x6x6 colour cube levels, plus a nearest-level lookup.
local CUBE = { 0, 95, 135, 175, 215, 255 }

local function nearest_cube(v)
  local best, best_d = 0, math.huge
  for i = 0, 5 do
    local d = math.abs(CUBE[i + 1] - v)
    if d < best_d then
      best, best_d = i, d
    end
  end
  return best, CUBE[best + 1]
end

-- Quantise an 8-bit RGB to the nearest xterm-256 colour (the 6x6x6 cube or the 24-step gray ramp).
local function to_cterm(r, g, b)
  local ri, rv = nearest_cube(r)
  local gi, gv = nearest_cube(g)
  local bi, bv = nearest_cube(b)
  local cube_d = (rv - r) ^ 2 + (gv - g) ^ 2 + (bv - b) ^ 2

  local gray = (r + g + b) / 3
  local gn = math.max(0, math.min(23, math.floor((gray - 8) / 10 + 0.5)))
  local gv2 = 8 + 10 * gn
  local gray_d = (gv2 - r) ^ 2 + (gv2 - g) ^ 2 + (gv2 - b) ^ 2

  if gray_d < cube_d then
    return 232 + gn
  end
  return 16 + 36 * ri + 6 * gi + bi
end

-- An OkLab point ({ L, a, b }) for the in-gamut colour at (lightness, hue, target chroma).
local function point(lightness, h, target)
  local c = fit_chroma(lightness, h, target)
  local hr = math.rad(h)
  return { L = lightness, a = c * math.cos(hr), b = c * math.sin(hr), h = h, c = c }
end

-- Squared OkLab distance (monotonic with true distance, so fine for comparisons).
local function dist2(p, q)
  return (p.L - q.L) ^ 2 + (p.a - q.a) ^ 2 + (p.b - q.b) ^ 2
end

-- Greedily choose COUNT maximally-separated colours from the candidate grid, seeded at the anchor.
local function build()
  local cand = {}
  for hi = 0, H_STEPS - 1 do
    local h = 360 * hi / H_STEPS
    for li = 0, L_STEPS - 1 do
      local lightness = L_LO + (L_HI - L_LO) * li / (L_STEPS - 1)
      for ci = 0, C_STEPS - 1 do
        cand[#cand + 1] = point(lightness, h, C_LO + (C_HI - C_LO) * ci / (C_STEPS - 1))
      end
    end
  end

  local seed = point(SEED_L, SEED_H, SEED_C)
  local chosen = {}
  local first, first_d = 1, math.huge
  for k, c in ipairs(cand) do
    local d = dist2(c, seed)
    if d < first_d then
      first, first_d = k, d
    end
  end
  chosen[1] = cand[first]

  for _ = 2, COUNT do
    local best, best_sep = nil, -1
    for _, c in ipairs(cand) do
      local nearest = math.huge
      for _, ch in ipairs(chosen) do
        local d = dist2(c, ch)
        if d < nearest then
          nearest = d
        end
      end
      if nearest > best_sep then
        best_sep, best = nearest, c
      end
    end
    chosen[#chosen + 1] = best
  end

  local out = {}
  for _, c in ipairs(chosen) do
    local lr, lg, lb = linear_at(c.L, c.h, c.c)
    local r, g, b = channel(lr), channel(lg), channel(lb)
    out[#out + 1] = {
      gui = string.format("#%02x%02x%02x", r, g, b),
      cterm = to_cterm(r, g, b),
    }
  end
  return out
end

local cache

-- The colour for a 1-based activity index; the palette is built once, cached, and cycles beyond its length.
function M.color(index)
  cache = cache or build()
  return cache[(index - 1) % #cache + 1]
end

return M
