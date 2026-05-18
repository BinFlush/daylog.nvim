local M = {}

local function trim_trailing_slashes(value)
  return value:gsub("/+$", "")
end

local function trim_directory_slashes(value)
  local trimmed = trim_trailing_slashes(value)
  return trimmed:gsub("^/+", "")
end

local function expanded_root(root)
  return trim_trailing_slashes(vim.fn.expand(root))
end

function M.directory_path(journal, now)
  local path = expanded_root(journal.root)
  local directory = trim_directory_slashes(os.date(journal.directory, now))

  if directory == "" then
    return path
  end

  return path .. "/" .. directory
end

function M.filename(now)
  return os.date("%Y-%m-%d", now) .. ".wkl"
end

function M.today_path(journal, now)
  return M.directory_path(journal, now) .. "/" .. M.filename(now)
end

return M
