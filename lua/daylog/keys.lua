-- Keymap cheatsheet popup (shell).
--
-- :Daylog keys (and g? in the default set) opens a small float listing the daylog keymaps active
-- in daylog files, plus how to open today and reach the full command set. The line building is
-- pure (M.format) so it is unit-tested without a window; M.show owns the float.

local M = {}

local TITLE = "daylog keys (.day files)"
local FOOTER = "Open today: :Daylog    all commands: :Daylog <Tab>"

-- Pure: the cheatsheet lines for entries { { lhs, desc }, ... } (lhs already display-ready). An
-- empty list yields the "no keymaps" guidance instead of a key table.
function M.format(entries)
  local lines = { " " .. TITLE, "" }

  if #entries == 0 then
    lines[#lines + 1] = "  No keymaps set in daylog files."
    lines[#lines + 1] = "  Enable the default set with  setup({ keymaps = true })"
  else
    local width = 0
    for _, entry in ipairs(entries) do
      width = math.max(width, #entry.lhs)
    end
    for _, entry in ipairs(entries) do
      local pad = string.rep(" ", width - #entry.lhs)
      lines[#lines + 1] = "  " .. entry.lhs .. pad .. "   " .. entry.desc
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = " " .. FOOTER
  return lines
end

-- Expand <localleader>/<leader> to the real key and resolve termcodes for display.
local function display_lhs(lhs)
  local localleader = vim.g.maplocalleader
  if localleader == nil or localleader == "" then
    localleader = "\\"
  end
  local leader = vim.g.mapleader
  if leader == nil or leader == "" then
    leader = "\\"
  end
  lhs = lhs:gsub("<[lL]ocalleader>", function()
    return localleader
  end)
  lhs = lhs:gsub("<[lL]eader>", function()
    return leader
  end)
  return vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, true, true))
end

-- Shell: render the cheatsheet in a centered float; q / <Esc> / <CR> or leaving it closes it.
function M.show(entries)
  local display = {}
  for _, entry in ipairs(entries) do
    display[#display + 1] = { lhs = display_lhs(entry.lhs), desc = entry.desc }
  end
  local lines = M.format(display)

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = width + 2

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = #lines,
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  for _, key in ipairs({ "q", "<Esc>", "<CR>" }) do
    vim.keymap.set("n", key, close, { buffer = buf, nowait = true, silent = true })
  end
  vim.api.nvim_create_autocmd("BufLeave", { buffer = buf, once = true, callback = close })

  return win
end

return M
