local palette = require("daylog.palette")

local M = {}

-- Per-activity highlight groups (shell).
--
-- The end of the colour pipeline: colors.lua decides which slot an activity gets, palette.lua gives
-- that slot a colour, and this module registers it as the live Neovim groups -- DaylogBar{n} (a
-- background, for the bar blocks and legend swatches) and DaylogSign{n} (a foreground, for the margin
-- indicator, carried by the DaylogActivitySign{n} sign). Groups are defined lazily on first use with
-- default = true (so a theme or the user's own :highlight wins), and forgotten on a colorscheme switch
-- so the next render re-creates them.

local bar_defined = {}
local sign_defined = {}

-- The highlight group for an activity's bar block (a generated colour as a background), defined on
-- first use. Used by the time-bar blocks and the legend swatches.
function M.bar_group(index)
  if not bar_defined[index] then
    local c = palette.color(index)
    vim.api.nvim_set_hl(0, "DaylogBar" .. index, { bg = c.gui, ctermbg = c.cterm, default = true })
    bar_defined[index] = true
  end
  return "DaylogBar" .. index
end

-- The sign name for an activity's margin indicator (a generated colour as a foreground), defining the
-- DaylogSign{index} colour group and its DaylogActivitySign{index} sign on first use.
function M.activity_sign(index)
  if not sign_defined[index] then
    local c = palette.color(index)
    vim.api.nvim_set_hl(0, "DaylogSign" .. index, { fg = c.gui, ctermfg = c.cterm, default = true })
    vim.fn.sign_define("DaylogActivitySign" .. index, {
      text = "▌",
      texthl = "DaylogSign" .. index,
    })
    sign_defined[index] = true
  end
  return "DaylogActivitySign" .. index
end

-- A colorscheme switch clears our default groups; forget them so the next render re-defines them.
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    bar_defined = {}
    sign_defined = {}
  end,
})

return M
