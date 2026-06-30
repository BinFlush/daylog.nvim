-- Activity colour assignment (PURE).
--
-- The single source of truth for which colour an activity gets, shared by the time bar's blocks, the
-- left-margin indicator, and the summary rows -- so an activity is the same colour everywhere. The
-- index is assigned by order of first appearance (not by duration), so a colour stays put as the day
-- grows: adding time to an activity never reshuffles the palette.

local M = {}

-- Map each activity (a resolved label, `intervals[i].text`) to a 1-based colour index by order of
-- first appearance. Returns the { [label] = index } map and the labels in that order.
function M.indices(intervals)
  local index = {}
  local order = {}
  for _, interval in ipairs(intervals) do
    if index[interval.text] == nil then
      order[#order + 1] = interval.text
      index[interval.text] = #order
    end
  end
  return index, order
end

return M
