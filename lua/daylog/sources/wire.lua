-- Source instantiation: injects the shell transport, JSON codec, and token resolver (shell).

local buffer = require("daylog.buffer")
local config = require("daylog.config")
local sources_http = require("daylog.sources.http")
local sources_registry = require("daylog.sources.registry")

local M = {}

-- Resolve a source's PAT lazily: call its `token()` (pcall'd so a throw is reported, not fatal) and
-- require a non-empty string. Returns the token, or nil and a specific daylog: message. Named so the
-- two error branches are directly testable.
function M.resolve_token(source_cfg)
  local ok, token = pcall(source_cfg.token)
  if not ok then
    return nil, "daylog: source token() errored: " .. tostring(token)
  end
  if type(token) ~= "string" or token == "" then
    return nil, "daylog: source token() did not return a non-empty string"
  end
  return token
end

-- Build and register the sources declared in config, injecting the shell transport, JSON
-- codec, and a lazy token resolver; clears first so repeated setup() starts from a clean registry.
function M.instantiate()
  sources_registry.clear()

  local sources = config.get().sources
  if not sources then
    return
  end

  for name, source_config in pairs(sources) do
    local source, err = sources_registry.instantiate(name, source_config, {
      transport = sources_http,
      json = vim.json,
      token_resolver = M.resolve_token,
    })

    if source then
      sources_registry.register(name, source)
    else
      buffer.warn(err)
    end
  end
end

return M
