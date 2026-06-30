local activity_hl = require("daylog.activity_hl")
local config = require("daylog.config")
local entry = require("daylog.entry")
local highlight = require("daylog.highlight")
local timebar = require("daylog.timebar")

local M = {}

-- The colour-coded time bar (shell).
--
-- A legend row above a bar row, shown in a fixed-height split reserved at the bottom of the daylog
-- window. Reserving real space means it is always visible (it does not scroll with the log) and
-- never overlays the summary/totals (the log window is shortened to make room). Its segments are the
-- active log's intervals -- width proportional to real duration, colour per activity. A global
-- on/off (the `time_bar` config is the initial state) carried across every daylog file; the buffer
-- shell redraws it on each highlight pass via M.render. This module owns the panel: its window/split
-- lifecycle, the scratch-buffer rendering, and the on/off state -- buffer.lua just calls in.

-- Highlights for the strip's own scratch buffer (not the daylog buffer's namespace).
local strip_namespace = vim.api.nvim_create_namespace("daylog-timebar")

-- Global on/off, so a toggle carries across daylog files rather than being per-buffer (nil = follow
-- the `time_bar` config default until first toggled).
local time_bar_on = nil

-- Whether the bar is on, from the global toggle, falling back to the config default.
function M.enabled()
  if time_bar_on == nil then
    return config.get().time_bar
  end
  return time_bar_on
end

-- Flip the global on/off; the caller redraws the affected buffers. Returns the new state.
function M.toggle()
  time_bar_on = not M.enabled()
  return time_bar_on
end

-- Owner window id -> { win, buf } for the bar's reserved bottom split (its window + scratch buffer).
-- Keying by the window the strip sits under (not the buffer) lets navigating between daylog files in
-- one window reuse the strip. `strip_autocmds_set` guards the one-time lifecycle autocmd setup.
local bar_strips = {}
local strip_autocmds_set = false

-- The hover tooltip: a single reusable, non-focusable float showing the time + activity under the
-- mouse (opt-in via `time_bar_hover`). Created lazily; hiding closes the window but reuses the buffer.
local hover_win = nil
local hover_buf = nil

local function hide_hover()
  if hover_win and vim.api.nvim_win_is_valid(hover_win) then
    pcall(vim.api.nvim_win_close, hover_win, true)
  end
  hover_win = nil
end

-- The legend and bar as virtual-line chunk lists ({ {text, hl}, ... } per line), legend above the
-- bar. The bar is one coloured run of spaces per segment; the legend is a swatch + name per activity
-- in colour order, stopping before it would overflow `width`.
local function bar_virt_lines(layout, width)
  local bar = {}
  local col = 0
  for _, seg in ipairs(layout.segments) do
    local group = activity_hl.bar_group(seg.color_index)
    -- Split the segment around the "now" marker -- a thin line glyph on the segment's own colour, so
    -- it reads as a subtle tick rather than a solid block -- when it falls inside the segment.
    if layout.now_col and layout.now_col > col and layout.now_col <= col + seg.width then
      local before = layout.now_col - 1 - col
      if before > 0 then
        bar[#bar + 1] = { string.rep(" ", before), group }
      end
      bar[#bar + 1] = { "▏", group }
      local after = seg.width - before - 1
      if after > 0 then
        bar[#bar + 1] = { string.rep(" ", after), group }
      end
    else
      bar[#bar + 1] = { string.rep(" ", seg.width), group }
    end
    col = col + seg.width
  end

  local legend = {}
  local used = 0
  for _, item in ipairs(timebar.fit_legend(layout.legend, width)) do
    local name = " " .. item.text .. "  "
    -- fit_legend already abbreviated/evicted by character count; this guards the true display width
    -- so a double-width (CJK/emoji) label can never overflow the bar.
    local item_width = 2 + vim.fn.strdisplaywidth(name)
    if used + item_width > width then
      break
    end
    legend[#legend + 1] = { "  ", activity_hl.bar_group(item.color_index) }
    legend[#legend + 1] = { name, "DaylogBarLabel" }
    used = used + item_width
  end

  local rows = {}
  if #legend > 0 then
    rows[#rows + 1] = legend
  end
  rows[#rows + 1] = bar
  return rows
end

-- The current local time in minutes, but only when `buf` is today's dated daylog file -- so the
-- "now" marker appears only on the current day. nil for any other day, or a non-dated file.
local function today_now_minutes(buf)
  local daybook = require("daylog.daybook")
  local basename = vim.api.nvim_buf_get_name(buf):match("[^/\\]+$") or ""
  local file_date = daybook.parse_date_label(basename)
  if not file_date or not daybook.same_date(file_date, os.time()) then
    return nil
  end
  local clock = os.date("*t")
  return clock.hour * 60 + clock.min
end

-- Flatten a virtual-line chunk list ({text, hl}) into a real line string plus its byte-range
-- highlights, for the strip's scratch buffer. `line` is the 0-based scratch row.
local function flatten_chunks(chunks, line)
  local parts = {}
  local hls = {}
  local byte = 0
  for _, chunk in ipairs(chunks) do
    parts[#parts + 1] = chunk[1]
    hls[#hls + 1] = { line = line, col_start = byte, col_end = byte + #chunk[1], group = chunk[2] }
    byte = byte + #chunk[1]
  end
  return table.concat(parts), hls
end

-- Close and forget the strip belonging to window `owner`, if any (restoring its height). pcall'd
-- because teardown can run while Neovim is mid-close, where a stray failure must not propagate.
local function close_strip(owner)
  local strip = bar_strips[owner]
  if not strip then
    return
  end
  if strip.win and vim.api.nvim_win_is_valid(strip.win) then
    pcall(vim.api.nvim_win_close, strip.win, true)
  end
  if strip.buf and vim.api.nvim_buf_is_valid(strip.buf) then
    pcall(vim.api.nvim_buf_delete, strip.buf, { force = true })
  end
  bar_strips[owner] = nil
  hide_hover()
end

-- Lifecycle autocmds for the strips, set up once on first use. A strip is a real window, so it must
-- not outlive its log window or block :q -- and closing one inside BufWinLeave aborts the quit. So
-- teardown runs from QuitPre (before a quit) and WinClosed (after any close), never during it.
local function ensure_strip_autocmds()
  if strip_autocmds_set then
    return
  end
  strip_autocmds_set = true
  local group = vim.api.nvim_create_augroup("DaylogTimeBarStrip", { clear = true })

  -- A window closed: drop its strip (its log window went away), or forget a strip closed directly.
  -- Deferred so the window is closed cleanly first.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local closed = tonumber(args.match)
      if not closed then
        return
      end
      vim.schedule(function()
        close_strip(closed)
        for owner, strip in pairs(bar_strips) do
          if strip.win == closed then
            bar_strips[owner] = nil
            break
          end
        end
      end)
    end,
  })

  -- Close the current window's strip before a :q so the strip never blocks the quit.
  vim.api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      close_strip(vim.api.nvim_get_current_win())
    end,
  })

  -- A window that owned a strip now shows a non-daylog buffer: drop the strip (a daylog buffer
  -- instead re-renders through the ftplugin).
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      local win = vim.fn.bufwinid(args.buf)
      if win ~= -1 and bar_strips[win] and vim.bo[args.buf].filetype ~= "daylog" then
        close_strip(win)
      end
    end,
  })
end

-- The window/buffer transition events the split + focus restore fire; ignored while opening the
-- strip so it cannot recurse back into the highlighter (via the ftplugin's BufWinEnter) -- targeted
-- rather than "all" so a plugin's unrelated autocmds still run during that instant.
local STRIP_OPEN_EVENTS = table.concat({
  "BufEnter",
  "BufLeave",
  "BufWinEnter",
  "BufWinLeave",
  "WinEnter",
  "WinLeave",
  "WinNew",
  "WinClosed",
  "WinScrolled",
  "WinResized",
}, ",")

-- Open a fixed-height split below `dwin` showing `sbuf` (the bar), without leaving the user's focus
-- moved. Returns the new window or nil. eventignore guards against recursing into the highlighter;
-- the focus restore and eventignore reset run even if the split itself fails.
local function open_bar_strip(dwin, sbuf, height)
  if not vim.api.nvim_win_is_valid(dwin) then
    return nil
  end
  local cur = vim.api.nvim_get_current_win()
  local saved = vim.o.eventignore
  vim.o.eventignore = STRIP_OPEN_EVENTS
  local strip_win
  pcall(function()
    vim.api.nvim_set_current_win(dwin)
    vim.cmd("belowright " .. height .. "split")
    strip_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(strip_win, sbuf)
    vim.api.nvim_win_set_height(strip_win, height)
    local wo = vim.wo[strip_win]
    wo.winfixheight = true
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = "no"
    wo.foldcolumn = "0"
    wo.cursorline = false
    wo.list = false
    wo.wrap = false
    wo.statusline = " "
  end)
  if vim.api.nvim_win_is_valid(cur) then
    vim.api.nvim_set_current_win(cur)
  end
  vim.o.eventignore = saved
  return strip_win
end

-- Render the time bar for `buf` into a reserved split at the bottom of its window. The buffer shell
-- calls this every highlight pass (with the shared `analysis`): it refreshes the strip's content in
-- place, creating the split on first show (shortening the log window) and tearing it down whenever
-- the bar is off or the buffer has no window. The strip is keyed by the window, so navigating
-- between daylog files reuses it.
function M.render(buf, lines, analysis)
  local dwin = vim.fn.bufwinid(buf)
  if not M.enabled() or #lines == 0 then
    if dwin ~= -1 then
      close_strip(dwin)
    end
    return
  end
  if dwin == -1 then
    return
  end
  local width = vim.api.nvim_win_get_width(dwin)
  if width < 1 then
    close_strip(dwin)
    return
  end
  local entries = highlight.active_entries(lines, analysis)
  local layout = entries and timebar.layout(entries, width, today_now_minutes(buf))
  if not layout then
    close_strip(dwin)
    return
  end

  ensure_strip_autocmds()

  local content, hls = {}, {}
  for i, row in ipairs(bar_virt_lines(layout, width)) do
    local line_text, row_hls = flatten_chunks(row, i - 1)
    content[i] = line_text
    for _, h in ipairs(row_hls) do
      hls[#hls + 1] = h
    end
  end

  local strip = bar_strips[dwin]
  local sbuf = strip and strip.buf
  if not (sbuf and vim.api.nvim_buf_is_valid(sbuf)) then
    sbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[sbuf].bufhidden = "hide"
  end
  vim.bo[sbuf].modifiable = true
  vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, content)
  vim.bo[sbuf].modifiable = false
  vim.api.nvim_buf_clear_namespace(sbuf, strip_namespace, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(sbuf, strip_namespace, h.line, h.col_start, {
      end_col = h.col_end,
      hl_group = h.group,
    })
  end

  local strip_win = strip and strip.win
  if strip_win and vim.api.nvim_win_is_valid(strip_win) then
    if vim.api.nvim_win_get_buf(strip_win) ~= sbuf then
      vim.api.nvim_win_set_buf(strip_win, sbuf)
    end
    if vim.api.nvim_win_get_height(strip_win) ~= #content then
      vim.api.nvim_win_set_height(strip_win, #content)
    end
  else
    strip_win = open_bar_strip(dwin, sbuf, #content)
  end

  if strip_win and vim.api.nvim_win_is_valid(strip_win) then
    bar_strips[dwin] = {
      win = strip_win,
      buf = sbuf,
      first_minutes = entries[1].minutes,
      last_minutes = entries[#entries].minutes,
      segments = layout.segments,
    }
  else
    close_strip(dwin)
  end
end

-- Show (or reposition) the hover tooltip one row above the pointer, reusing its window/buffer.
local function show_hover(pos, text)
  if not (hover_buf and vim.api.nvim_buf_is_valid(hover_buf)) then
    hover_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[hover_buf].bufhidden = "hide"
  end
  vim.bo[hover_buf].modifiable = true
  vim.api.nvim_buf_set_lines(hover_buf, 0, -1, false, { " " .. text .. " " })
  vim.bo[hover_buf].modifiable = false

  local width = vim.fn.strdisplaywidth(text) + 2
  local placement = {
    relative = "editor",
    width = width,
    height = 1,
    row = math.max(0, pos.screenrow - 2),
    col = math.min(math.max(0, pos.screencol - 1), math.max(0, vim.o.columns - width)),
  }
  if hover_win and vim.api.nvim_win_is_valid(hover_win) then
    vim.api.nvim_win_set_config(hover_win, placement)
  else
    placement.style = "minimal"
    placement.focusable = false
    placement.noautocmd = true
    placement.zindex = 200
    hover_win = vim.api.nvim_open_win(hover_buf, false, placement)
  end
end

-- The strip record whose own window is `win`, or nil. Strips are keyed by their owner (log) window,
-- so a hover hit-test scans for the strip window itself.
local function strip_by_win(win)
  for _, strip in pairs(bar_strips) do
    if strip.win == win then
      return strip
    end
  end
  return nil
end

-- Mouse-move handler, installed buffer-locally in daylog files when `time_bar_hover` is on (and only
-- effective once the user has set `mousemoveevent`). Over a bar strip, it shows the clock time +
-- activity at the hovered column; anywhere else it hides the tooltip.
function M.on_mouse_move()
  local pos = vim.fn.getmousepos()
  local strip = strip_by_win(pos.winid)
  if not (strip and strip.first_minutes and pos.wincol >= 1) then
    hide_hover()
    return
  end
  local width = vim.api.nvim_win_get_width(strip.win)
  local minutes = timebar.time_at_column(strip.first_minutes, strip.last_minutes, width, pos.wincol)
  local text = entry.minutes_string(minutes)
  local label = timebar.segment_label_at(strip.segments, pos.wincol)
  if label then
    text = text .. "  " .. label
  end
  show_hover(pos, text)
end

return M
