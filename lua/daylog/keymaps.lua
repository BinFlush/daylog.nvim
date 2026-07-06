-- Opt-in buffer-local keymaps for daylog files: the default set, applying, and re-setup (shell).

local config = require("daylog.config")

local M = {}

-- The opt-in default key set (setup({ keymaps = true })): buffer-local in daylog files. ]d / [d
-- navigate days (deliberately overriding the diagnostic jumps inside daylog buffers, and
-- count-aware -- 3]d steps three logged days on); the editing verbs sit under the <leader>d
-- namespace (gitsigns-style: rides whatever <leader> you set, and only shadows a global
-- <leader>d* inside daylog buffers); g? shows the cheatsheet. Each entry carries a description so
-- which-key (and :Daylog keys) can label it.
local DEFAULT_KEYMAPS = {
  {
    lhs = "]d",
    desc = "next day",
    rhs = function()
      require("daylog").next_day(vim.v.count1)
    end,
  },
  {
    lhs = "[d",
    desc = "previous day",
    rhs = function()
      require("daylog").prev_day(vim.v.count1)
    end,
  },
  {
    lhs = "<leader>di",
    desc = "insert (stamp the current time)",
    rhs = function()
      require("daylog").insert()
    end,
  },
  {
    lhs = "<leader>dI",
    desc = "insert from picker (what to log)",
    rhs = function()
      require("daylog").insert({ pick = true })
    end,
  },
  {
    lhs = "<leader>dr",
    desc = "repeat the activity under the cursor",
    rhs = function()
      require("daylog").repeat_()
    end,
  },
  {
    lhs = "<leader>dn",
    desc = "new log block",
    rhs = function()
      require("daylog").new_log()
    end,
  },
  {
    lhs = "<leader>dc",
    desc = "copy the active log",
    rhs = function()
      require("daylog").copy()
    end,
  },
  {
    lhs = "<leader>do",
    desc = "order entries by time",
    rhs = function()
      require("daylog").order()
    end,
  },
  {
    lhs = "<leader>dl",
    desc = "toggle logged on the summary row",
    rhs = function()
      require("daylog").log()
    end,
  },
  {
    lhs = "<leader>dm",
    desc = "map to a report label",
    rhs = function()
      require("daylog").map({})
    end,
  },
  {
    lhs = "<leader>dm",
    desc = "map the selection (visual)",
    mode = "x",
    rhs = ":Daylog map<CR>",
  },
  {
    lhs = "<leader>dR",
    desc = "rename the entry / tag / location",
    rhs = function()
      require("daylog").rename({})
    end,
  },
  {
    lhs = "<leader>dR",
    desc = "rename the selection (visual)",
    mode = "x",
    rhs = ":Daylog rename<CR>",
  },
  {
    lhs = "<leader>df",
    desc = "refresh summaries",
    rhs = function()
      require("daylog").refresh()
    end,
  },
  {
    lhs = "<leader>db",
    desc = "toggle the time bar",
    rhs = function()
      require("daylog").bar()
    end,
  },
  {
    lhs = "g?",
    desc = "show daylog keys",
    rhs = function()
      require("daylog").keys()
    end,
  },
}

-- The keymap cheatsheet entries ({ lhs, desc }) for the active config: the default set, a custom
-- table (generic label), or empty when keymaps are off. Read by :Daylog keys / g?.
function M.help_entries()
  local keymaps = config.get().keymaps
  if keymaps == true then
    local entries = {}
    for _, m in ipairs(DEFAULT_KEYMAPS) do
      entries[#entries + 1] = { lhs = m.lhs, desc = m.desc }
    end
    return entries
  end

  if type(keymaps) == "table" then
    local entries = {}
    for lhs in pairs(keymaps) do
      entries[#entries + 1] = { lhs = lhs, desc = "your mapping" }
    end
    table.sort(entries, function(a, b)
      return a.lhs < b.lhs
    end)
    return entries
  end

  return {}
end

-- Remove the daylog keymaps a previous apply recorded on `buf` (b:daylog_applied_maps), so a
-- re-setup replaces the set instead of stacking a custom table on top of the defaults.
local function clear_applied_keymaps(buf)
  for _, m in ipairs(vim.b[buf].daylog_applied_maps or {}) do
    pcall(vim.keymap.del, m.mode, m.lhs, { buffer = buf })
  end
  vim.b[buf].daylog_applied_maps = nil
end

-- Apply the configured keymaps buffer-locally to a daylog buffer (true -> the default set, a
-- table -> the user's own lhs -> rhs), first clearing any previously applied set. Each map
-- carries a description so which-key can label it; the applied { mode, lhs } pairs are recorded
-- in b:daylog_applied_maps so a later setup() can remove them.
local function apply_keymaps(buf)
  clear_applied_keymaps(buf)

  local keymaps = config.get().keymaps
  if not keymaps then
    return
  end

  local applied = {}
  local function set_map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = desc })
    applied[#applied + 1] = { mode = mode, lhs = lhs }
  end

  if keymaps == true then
    for _, m in ipairs(DEFAULT_KEYMAPS) do
      set_map(m.mode or "n", m.lhs, m.rhs, "Daylog: " .. m.desc)
    end
  else
    for lhs, rhs in pairs(keymaps) do
      set_map("n", lhs, rhs, "Daylog (user map)")
    end
  end

  vim.b[buf].daylog_applied_maps = applied
end

local function each_loaded_daylog_buffer(fn)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "daylog" then
      fn(buf)
    end
  end
end

-- (Re)install the FileType hook applying the opt-in keymaps to each daylog buffer. The augroup
-- clears on re-setup so a config change never stacks hooks; already-open daylog buffers get the
-- new maps immediately (their previous set cleared), and turning keymaps off removes it.
function M.setup()
  local group = vim.api.nvim_create_augroup("DaylogKeymaps", { clear = true })
  if not config.get().keymaps then
    each_loaded_daylog_buffer(clear_applied_keymaps)
    return
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "daylog",
    callback = function(opts)
      apply_keymaps(opts.buf)
    end,
  })

  each_loaded_daylog_buffer(apply_keymaps)
end

return M
