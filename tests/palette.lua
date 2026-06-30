-- Pure tests for the activity-colour generator (greedy farthest-point sampling in OkLCH): every index
-- maps to a valid, in-gamut colour with a distinct 256-colour fallback, and the colours stay
-- perceptually well separated. These assert the *guarantees* (separation, distinctness), not pinned
-- hex strings, so they are robust to floating-point jitter across builds.
return function(t)
  local palette = require("daylog.palette")

  -- sRGB hex -> OkLab, to measure the perceived distance between two generated colours.
  local function inv_gamma(c)
    c = c / 255
    if c <= 0.04045 then
      return c / 12.92
    end
    return ((c + 0.055) / 1.055) ^ 2.4
  end
  local function oklab(hex)
    local r = inv_gamma(tonumber(hex:sub(2, 3), 16))
    local g = inv_gamma(tonumber(hex:sub(4, 5), 16))
    local b = inv_gamma(tonumber(hex:sub(6, 7), 16))
    local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
    local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
    local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
    return {
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    }
  end
  local function delta_e(a, b)
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
  end

  t.test("the first 16 activity colours are perceptually well separated", function()
    -- The farthest-point search maximises the closest pair; assert it clears a comfortable floor
    -- (measured ~0.13, several times a just-noticeable difference of ~0.02).
    local labs = {}
    for i = 1, 16 do
      labs[i] = oklab(palette.color(i).gui)
    end
    local closest = math.huge
    for i = 1, 16 do
      for j = i + 1, 16 do
        closest = math.min(closest, delta_e(labs[i], labs[j]))
      end
    end
    t.ok(closest >= 0.10, "closest pair ΔE " .. string.format("%.3f", closest) .. " >= 0.10")
  end)

  t.test("activity colours have distinct 256-colour codes (no cterm collisions)", function()
    -- The separation in OkLab also keeps the xterm-256 codes distinct, so terminals without
    -- `termguicolors` never render two activities identically.
    local seen = {}
    for i = 1, 24 do
      local ct = palette.color(i).cterm
      t.ok(not seen[ct], "cterm " .. ct .. " (index " .. i .. ") is not already used")
      seen[ct] = true
    end
  end)

  t.test("palette.color yields valid hex and an xterm-256 code at any index", function()
    for i = 1, 40 do
      local c = palette.color(i)
      t.ok(c.gui:match("^#%x%x%x%x%x%x$") ~= nil, "valid hex at index " .. i)
      t.ok(c.cterm >= 16 and c.cterm <= 255, "cterm in [16,255] at index " .. i)
    end
  end)

  t.test("consecutive activity colours differ", function()
    for i = 1, 24 do
      t.ok(palette.color(i).gui ~= palette.color(i + 1).gui, "index " .. i .. " differs from next")
    end
  end)
end
