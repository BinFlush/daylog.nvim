local M = {}

-- Curl-based async HTTP transport. This is the only file in the source layer that
-- performs network IO (via vim.fn.jobstart). It knows nothing about worklog or
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

  return { status = tonumber(status_text) or 0, body = body }, nil
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

  if opts.auth then
    table.insert(args, "--user")
    table.insert(args, opts.auth)
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

  local function on_exit(_, code)
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
    return cb(nil, "failed to start curl")
  end

  if opts.body then
    vim.fn.chansend(job, opts.body)
  end
  vim.fn.chanclose(job, "stdin")
end

return M
