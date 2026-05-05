local M = {}

-- Build intervals from parsed entries.
-- Each entry starts an activity that continues until the next entry.
-- The final "done" line is assumed to exist and closes the last real interval.
-- Entries are assumed to already be in chronological order.
function M.build(entries)
  local intervals = {}

  for i = 1, #entries - 1 do
    local current = entries[i]
    local next = entries[i + 1]

    table.insert(intervals, {
      start = current.minutes,
      stop = next.minutes,
      duration = next.minutes - current.minutes,
      text = current.text,
      label = current.label,
      excluded = current.excluded,
    })
  end

  return intervals
end

return M
