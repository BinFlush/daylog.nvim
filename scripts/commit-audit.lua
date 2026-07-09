-- Headless git glue for the daylog commit audit (shell/tooling; runs under `nvim -l`).
--
-- Classifies a daybook commit's `.day` changes with lua/daylog/commit_audit.lua, then records the verdict
-- as a git note (ref `daylog`) and, for the other-day / needs-review cases, a lightweight
-- `daylog-other-day/<date>-<hash>` tag. Notes and tags are refs only -- the working tree is untouched, so
-- gitwatch does not re-fire. Run from inside the daybook repo (the plugin root is inferred from the
-- script path, so no --root is needed; pass --root <dir> only to override it):
--
--   nvim --clean -l /path/to/daylog.nvim/scripts/commit-audit.lua commit HEAD
--   nvim --clean -l /path/to/daylog.nvim/scripts/commit-audit.lua range HEAD~20..HEAD
--
-- Install the hook that runs this with `require("daylog").install_commit_audit_hook()`.

local NOTES_REF = "daylog"

local function die(message)
  io.stderr:write("commit-audit: " .. message .. "\n")
  os.exit(1)
end

-- Parse `[--root <dir>] <subcommand> <arg>` out of the argument vector `nvim -l` exposes as `arg`.
-- `--root` is an optional override; by default the plugin root is the script's own grandparent dir
-- (arg[0] is `.../scripts/commit-audit.lua`), so the hook needs no path baked in beyond the script path.
local function parse_args(argv)
  local root, rest = nil, {}
  local i = 1
  while i <= #argv do
    if argv[i] == "--root" then
      root = argv[i + 1]
      i = i + 2
    else
      rest[#rest + 1] = argv[i]
      i = i + 1
    end
  end
  root = root or vim.fn.fnamemodify(argv[0], ":p:h:h")
  if #rest < 2 then
    die("usage: [--root <dir>] (commit <ref> | range <rev-range>)")
  end
  return root, rest[1], rest[2]
end

-- Run a git command, returning its stdout lines and whether it succeeded (git failures are expected --
-- a blob missing from one side of a diff, a root commit with no parent).
local function git(args)
  local lines = vim.fn.systemlist(vim.list_extend({ "git" }, args))
  return lines, vim.v.shell_error == 0
end

local function git_line(args)
  local lines = git(args)
  return lines[1] or ""
end

-- The file content at a revision, or {} when the path does not exist there (add/delete side).
local function blob(rev, path)
  if not path then
    return {}
  end
  local lines, ok = git({ "show", rev .. ":" .. path })
  return ok and lines or {}
end

-- The changed `.day` files of `ref` as { path, old_lines, new_lines }. `diff-tree --root` diffs against
-- the first parent, and against the empty tree for a root commit (all files added). `path` is the day the
-- change concerns (the new name, or the old name for a delete).
local function changed_day_files(ref)
  local parent = git_line({ "rev-parse", "-q", "--verify", ref .. "^" })
  local status =
    git({ "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", ref, "--", "*.day" })

  local files = {}
  for _, line in ipairs(status) do
    local fields = vim.split(line, "\t", { plain = true })
    local code = fields[1]:sub(1, 1)
    local old_path, new_path
    if code == "A" then
      new_path = fields[2]
    elseif code == "D" then
      old_path = fields[2]
    elseif code == "R" or code == "C" then
      old_path, new_path = fields[2], fields[3]
    else -- M and friends
      old_path, new_path = fields[2], fields[2]
    end

    files[#files + 1] = {
      path = new_path or old_path,
      old_lines = (old_path and parent ~= "") and blob(parent, old_path) or {},
      new_lines = blob(ref, new_path),
    }
  end
  return files
end

local function process_commit(audit, ref, quiet)
  local full = git_line({ "rev-parse", ref })
  local short = git_line({ "rev-parse", "--short", ref })
  local commit_day = git_line({ "show", "-s", "--format=%cd", "--date=format-local:%Y-%m-%d", ref })

  local result = audit.classify(changed_day_files(ref), commit_day)

  local summary = result.classification
  if #result.log_days > 0 then
    summary = summary .. " days=" .. table.concat(result.log_days, ",")
  end
  if result.needs_review then
    summary = summary .. " needs-review"
  end

  local message = { summary }
  vim.list_extend(message, result.reasons)
  git({ "notes", "--ref=" .. NOTES_REF, "add", "-f", "-m", table.concat(message, "\n"), full })

  if result.classification == "other-day" or result.needs_review then
    git({ "tag", "-f", "daylog-other-day/" .. commit_day .. "-" .. short, full })
  end

  if not quiet then
    io.stdout:write(short .. " " .. summary .. "\n")
  end
end

local root, subcommand, target = parse_args(arg)
vim.opt.runtimepath:append(root)
local ok, audit = pcall(require, "daylog.commit_audit")
if not ok then
  die("could not load daylog.commit_audit from --root " .. root .. " (" .. tostring(audit) .. ")")
end

if subcommand == "commit" then
  process_commit(audit, target)
elseif subcommand == "range" then
  local revs, listed = git({ "rev-list", "--reverse", target })
  if not listed then
    die("bad rev-range: " .. target)
  end
  for _, ref in ipairs(revs) do
    process_commit(audit, ref, true)
  end
  io.stdout:write("audited " .. #revs .. " commit(s)\n")
else
  die("unknown subcommand: " .. subcommand)
end
