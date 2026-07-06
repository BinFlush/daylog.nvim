local analyze = require("daylog.analyze")
local document = require("daylog.document")
local support = require("daylog.usecases.support")

local M = {}

-- One-time migration for the v0.1.x `!L` (summary-logged), which the current grammar parses as the
-- location marker (`logged.l`); rewrites every such entry to `!S`, its v0.1.x meaning. Parse-based,
-- so only genuine trailing markers move (text like "look at !Slamas" is untouched). Run ONCE after
-- upgrading, before typing any new location `!L`. Each edit rewrites one line in place, so edits
-- across blocks are independent and need no ordering.

local function migrate_override(item)
  local logged = item.logged
  if not (logged and logged.l ~= nil) then
    return nil
  end

  -- Guard: never overwrite a genuine `!S`; keeps a re-run or hand-mixed `!S`+`!L` file from silently losing it.
  if logged.s ~= nil then
    return nil
  end

  -- Move the location value to the summary level, keeping any other levels (`!T`/`!W`) intact.
  local migrated = analyze.copy_logged(logged)
  migrated.s = migrated.l
  migrated.l = nil
  return { logged = migrated }
end

function M.run(lines)
  local analysis = analyze.analyze(document.parse(lines))

  local edits = {}
  for _, block in ipairs(analysis.log_blocks) do
    for _, edit in ipairs(support.rewrite_entry_lines(block, migrate_override)) do
      edits[#edits + 1] = edit
    end
  end

  return { edits = edits }
end

return M
