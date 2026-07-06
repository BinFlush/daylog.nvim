local M = {}

-- Small text helpers with no dependencies and no Neovim API (PURE).

-- Collapse internal whitespace runs to one space and trim the ends.
function M.normalize(s)
  return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Whether `lines` holds no log content (nil, empty, or only whitespace); the one predicate
-- every layer shares, so a nil line list counts as empty rather than erroring.
function M.is_empty(lines)
  if lines == nil then
    return true
  end

  for _, line in ipairs(lines) do
    if line:find("%S") then
      return false
    end
  end

  return true
end

return M
