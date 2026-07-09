-- Tests for install_commit_audit_hook: it writes an executable post-commit hook (path baked in) into a
-- daybook git repo, defaults to the configured daybook.root, refuses to clobber, and warns off a non-repo.
return function(t)
  local daylog = require("daylog")
  local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
  local with_captured_notify = helpers.with_captured_notify

  local function git_init(dir)
    vim.fn.mkdir(dir, "p")
    vim.fn.system({ "git", "-C", dir, "init" })
  end

  local function read(path)
    return table.concat(vim.fn.readfile(path), "\n")
  end

  t.test("install writes an executable post-commit hook with the script path baked in", function()
    local dir = vim.fn.tempname()
    git_init(dir)

    with_captured_notify(function(messages)
      local hook = daylog.install_commit_audit_hook({ dir = dir })

      t.eq(hook, dir .. "/.git/hooks/post-commit")
      t.eq(vim.fn.filereadable(hook), 1)
      t.ok(vim.fn.getfperm(hook):match("^rwx") ~= nil, "hook is owner-executable")

      local body = read(hook)
      t.ok(body:find("scripts/commit-audit.lua", 1, true) ~= nil, "script path is baked in")
      t.ok(body:find('nvim --clean -l "$SCRIPT" commit HEAD', 1, true) ~= nil, "invokes the script")

      t.eq(#messages, 1)
      t.eq(messages[1].level, vim.log.levels.INFO)
    end)
  end)

  t.test("install defaults to the configured daybook.root", function()
    local dir = vim.fn.tempname()
    git_init(dir)

    helpers.with_daylog_setup({ daybook = { root = dir, directory = "%Y" } }, function()
      t.eq(daylog.install_commit_audit_hook(), dir .. "/.git/hooks/post-commit")
    end)
  end)

  t.test("install refuses to clobber an existing hook unless forced", function()
    local dir = vim.fn.tempname()
    git_init(dir)
    daylog.install_commit_audit_hook({ dir = dir })

    with_captured_notify(function(messages)
      t.eq(daylog.install_commit_audit_hook({ dir = dir }), nil)
      t.eq(messages[1].level, vim.log.levels.WARN)
      t.ok(
        messages[1].message:find("already exists", 1, true) ~= nil,
        "warns about the existing hook"
      )
    end)

    t.eq(
      daylog.install_commit_audit_hook({ dir = dir, force = true }),
      dir .. "/.git/hooks/post-commit"
    )
  end)

  t.test("install warns when the target is not a git repository", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p") -- created, but never `git init`ed

    with_captured_notify(function(messages)
      t.eq(daylog.install_commit_audit_hook({ dir = dir }), nil)
      t.eq(messages[1].level, vim.log.levels.WARN)
      t.ok(
        messages[1].message:find("not a git repository", 1, true) ~= nil,
        "warns it is not a repo"
      )
    end)
  end)
end
