-- Activity colour assignment (PURE): the single source of truth for an activity's colour,
-- shared by the bar, margin, and summary. The index is by order of first appearance (not
-- duration), so a colour stays put as the day grows.

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
