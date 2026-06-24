local M = {}

-- Pure helpers for the live-search picker. No Telescope and no Neovim API, so the
-- pooling/loop-guard logic stays unit-testable; log.telescope wires these into
-- the actual finder/refresh glue.

-- Union of the cached/default items and freshly fetched server results, deduped by
-- id with the cached items first. Live search grows the pool without ever dropping
-- cached items or emptying it.
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

-- Render rows of cells as aligned columns. Each column but the last is padded with
-- spaces to its widest cell and joined by two spaces, so the trailing columns line
-- up regardless of the variable-width content before them (a work-item title, say).
-- The last column is left unpadded -- put the widest, free-flowing field there.
-- Byte width is used, which is exact for the ASCII id/type/state columns sources
-- align on. Trailing whitespace is trimmed (e.g. an empty final cell).
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

-- A resolver from a work item to its picker display line: pre-aligned through the
-- source's optional format_items (so columns line up across the whole pool `items`),
-- else the per-item format_item fallback. Both the Telescope finder and the
-- vim.ui.select fallback resolve display lines through this, so the source display
-- contract lives in one place.
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

-- The byte range of the trailing metadata in a picker display line -- everything after the leading
-- rendered name (`text`, what gets inserted) -- as `start, finish` (0-based, end-exclusive, ready
-- for a Telescope highlight / nvim_buf_add_highlight). Returns nil when there is nothing to dim: an
-- activity row (display == text) or a source whose display does not lead with the rendered name.
-- PURE.
function M.meta_range(display, text)
  if not text or text == "" then
    return nil
  end
  if #display <= #text or display:sub(1, #text) ~= text then
    return nil
  end
  return #text, #display
end

-- Whether a prompt change should trigger a fresh server search: at least min_len
-- characters and different from the last query we issued. min_len gates the
-- network so short, broad prompts only filter the cached pool client-side; it
-- defaults to 1 and is clamped to >= 1 so an empty prompt never searches. A picker
-- refresh re-fires the input hook with the same prompt, so the last_query check
-- breaks that loop.
function M.should_query(prompt, last_query, min_len)
  min_len = min_len or 1
  if min_len < 1 then
    min_len = 1
  end
  return #prompt >= min_len and prompt ~= last_query
end

return M
