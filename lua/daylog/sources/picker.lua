local M = {}

-- Pure helpers for the live-search picker (no Telescope/Neovim API); telescope.lua
-- wires them into the actual finder/refresh glue.

-- Union of cached items and freshly fetched results, deduped by id with cached first;
-- live search grows the pool without dropping cached items or emptying it.
function M.merge(initial, extra)
  local seen, out = {}, {}
  for _, list in ipairs({ initial or {}, extra or {} }) do
    for _, item in ipairs(list) do
      local key = tostring(item.id)
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = item
      end
    end
  end
  return out
end

-- Render rows of cells as columns: every column but the last is padded to its widest cell and
-- joined by two spaces (put the widest free-flowing field last). Byte width, exact for the ASCII
-- id/type/state columns sources align on; trailing whitespace is trimmed.
function M.align(rows)
  local widths = {}
  for _, cells in ipairs(rows) do
    for column = 1, #cells - 1 do
      widths[column] = math.max(widths[column] or 0, #cells[column])
    end
  end

  local lines = {}
  for _, cells in ipairs(rows) do
    local parts = {}
    for column, cell in ipairs(cells) do
      if column < #cells then
        parts[column] = cell .. string.rep(" ", widths[column] - #cell)
      else
        parts[column] = cell
      end
    end
    lines[#lines + 1] = (table.concat(parts, "  "):gsub("%s+$", ""))
  end

  return lines
end

-- Resolve a work item to its picker display line via the source's optional format_items
-- (aligned across the pool), else per-item format_item; both finders resolve through this
-- so the source display contract lives in one place.
function M.display_for(source, items)
  local lines = source.format_items and source.format_items(items)
  local by_item = {}
  if lines then
    for index, item in ipairs(items) do
      by_item[item] = lines[index]
    end
  end

  return function(item)
    return by_item[item] or source.format_item(item)
  end
end

-- Byte range of the trailing metadata in a display line (after the rendered `text`) as
-- `start, finish` (0-based, end-exclusive, for nvim_buf_add_highlight); nil when there is
-- nothing to dim. PURE.
function M.meta_range(display, text)
  if not text or text == "" then
    return nil
  end
  if #display <= #text or display:sub(1, #text) ~= text then
    return nil
  end
  return #text, #display
end

-- Whether a prompt change should trigger a server search: at least min_len chars (clamped
-- >= 1, so an empty prompt never searches) and different from last_query, which breaks the
-- refresh re-fire loop.
function M.should_query(prompt, last_query, min_len)
  min_len = min_len or 1
  if min_len < 1 then
    min_len = 1
  end
  return #prompt >= min_len and prompt ~= last_query
end

return M
