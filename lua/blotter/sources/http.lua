local M = {}

-- Curl-based async HTTP transport. This is the only file in the source layer that
-- performs network IO (via vim.fn.jobstart). It knows nothing about blotter or
-- Azure DevOps -- it runs a request and hands back { status, body }.

local DEFAULT_TIMEOUT_MS = 30000

function M.is_available()
  return vim.fn.executable("curl") == 1
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Turn curl's exit code and buffered stdout/stderr line lists into
-- { status = integer, body = string } or nil, err. Pure (no Neovim API), so the
-- exit handling stays unit-testable. The status code rides on its own trailing
-- line, appended via curl's --write-out, so it splits off cleanly from the body.
function M.parse_response(code, stdout, stderr)
  if code ~= 0 then
    local message = trim(table.concat(stderr or {}, "\n"))
    if message == "" then
      message = "curl exited with code " .. tostring(code)
    end
    return nil, message
  end

  local output = table.concat(stdout or {}, "\n")
  local body, status_text = output:match("^(.*)\n([^\n]*)$")
  if not status_text then
    body, status_text = "", output
  end

  -- curl always appends %{http_code}; a non-numeric tail means no usable response,
  -- so report that rather than fabricating a status 0.
  local status = tonumber(status_text)
  if not status then
    return nil, "curl returned no HTTP status"
  end

  return { status = status, body = body }, nil
end

-- opts: { method, url, headers = { [name] = value }, body = string|nil,
--         auth = "user:pass"|nil, timeout_ms = number|nil }
-- cb(response, err) where response = { status = integer, body = string }.
function M.request(opts, cb)
  if not M.is_available() then
    return cb(nil, "curl is not available on PATH")
  end

  local args = {
    "curl",
    "--silent",
    "--show-error",
    "--max-time",
    tostring((opts.timeout_ms or DEFAULT_TIMEOUT_MS) / 1000),
    "-X",
    opts.method or "GET",
    -- Append the status code on its own trailing line so it splits off cleanly
    -- regardless of the body's contents.
    "--write-out",
    "\n%{http_code}",
  }

  -- Pass credentials through a private curl config file rather than --user, which
  -- would expose the token in the process argv (ps / /proc/<pid>/cmdline). The
  -- file lives in Neovim's 0700 temp dir, is locked to the owner, and is removed
  -- once curl exits. Escape backslashes and quotes so the quoted value is intact.
  local config_file
  if opts.auth then
    config_file = vim.fn.tempname()
    local escaped = (opts.auth:gsub("\\", "\\\\"):gsub('"', '\\"'))
    vim.fn.writefile({ 'user = "' .. escaped .. '"' }, config_file)
    vim.fn.setfperm(config_file, "rw-------")
    table.insert(args, "--config")
    table.insert(args, config_file)
  end

  for header_name, value in pairs(opts.headers or {}) do
    table.insert(args, "-H")
    table.insert(args, header_name .. ": " .. value)
  end

  if opts.body then
    table.insert(args, "--data-binary")
    table.insert(args, "@-")
  end

  table.insert(args, opts.url)

  local stdout = {}
  local stderr = {}

  local function cleanup()
    if config_file then
      os.remove(config_file)
      config_file = nil
    end
  end

  local function on_exit(_, code)
    cleanup()
    cb(M.parse_response(code, stdout, stderr))
  end

  local job = vim.fn.jobstart(args, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout = data
    end,
    on_stderr = function(_, data)
      stderr = data
    end,
    on_exit = on_exit,
  })

  if job <= 0 then
    cleanup()
    return cb(nil, "failed to start curl")
  end

  if opts.body then
    vim.fn.chansend(job, opts.body)
  end
  vim.fn.chanclose(job, "stdin")
end

return M
