local M = {}

-- Small text predicates with no dependencies and no Neovim API (PURE).

-- Whether `lines` holds no worklog content: nil, empty, or only blank/whitespace
-- lines. Every layer agrees on what "empty" means through this one predicate -- the
-- shell's buffer check, new_worklog's create-in-place guard, and the journal
-- report's empty-day skip -- so a nil line list counts as empty rather than erroring.
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
