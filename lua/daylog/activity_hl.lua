local palette = require("daylog.palette")

local M = {}

-- Per-activity highlight groups (shell): registers DaylogBar{n} (background, bar/legend) and
-- DaylogSign{n} (foreground, margin sign). Defined lazily with default = true (a theme or
-- :highlight wins) and forgotten on a colorscheme switch.

local bar_defined = {}
local sign_defined = {}

-- The highlight group for an activity's bar block, defined on first use; used by the bar blocks and legend swatches.
function M.bar_group(index)
  if not bar_defined[index] then
    local c = palette.color(index)
    vim.api.nvim_set_hl(0, "DaylogBar" .. index, { bg = c.gui, ctermbg = c.cterm, default = true })
    bar_defined[index] = true
  end
  return "DaylogBar" .. index
end

-- The sign name for an activity's margin indicator, defining its DaylogSign{index} group and
-- DaylogActivitySign{index} sign on first use.
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
