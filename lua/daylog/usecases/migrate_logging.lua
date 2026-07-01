local analyze = require("daylog.analyze")
local document = require("daylog.document")
local support = require("daylog.usecases.support")

local M = {}

-- One-time migration for the v0.1.x single-level `!L` (summary-logged), which is now the LOCATION
-- marker. Under the current grammar an old `!L` parses as a location-level logged marker (`logged.l`);
-- this rewrites every such entry to the summary marker `!S` -- the meaning it had in v0.1.x. Parse-based
-- (never a raw find/replace), so only genuine trailing markers move and activity text like
-- "look at !Slamas" is untouched. Run ONCE right after upgrading, before typing any new location `!L`;
-- the shell follows it with a summary refresh.
--
-- Each edit rewrites one entry line in place (no line-count change), so edits across blocks are
-- independent and need no ordering.

local function migrate_override(item)
  local logged = item.logged
  if not (logged and logged.l ~= nil) then
    return nil
  end

  -- Guard: never overwrite a genuine summary value. It cannot occur in a clean v0.1.x file (no `!S`
  -- existed), but this keeps a re-run or a hand-mixed `!S`+`!L` file from silently losing the `!S`.
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
