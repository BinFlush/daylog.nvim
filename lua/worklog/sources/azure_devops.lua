local M = {}

-- Azure DevOps work-item source.
--
-- Config-driven and free of any direct Neovim API call: networking goes through
-- an injected transport (deps.transport.request) and JSON through an injected
-- codec (deps.json), so it is exercised offline in tests with a fake transport.
-- The PAT is resolved lazily via deps.token_resolver and only ever placed in the
-- request credentials -- never in an item or the cache.

local DEFAULT_WIQL = table.concat({
  "SELECT [System.Id] FROM WorkItems",
  "WHERE [System.AssignedTo] = @Me",
  "AND [System.State] <> 'Closed' AND [System.State] <> 'Removed'",
  "AND [System.ChangedDate] >= @Today - 30",
  "ORDER BY [System.ChangedDate] DESC",
}, " ")

-- Comma-separated field list and id list are passed literally (safe constants /
-- digits); only opaque path segments are percent-encoded.
local WORKITEM_FIELDS = "System.Id,System.Title,System.WorkItemType,System.State"
local MAX_ITEMS = 200

local function encode_segment(segment)
  return (
    segment:gsub("[^%w%-%._~]", function(c)
      return string.format("%%%02X", string.byte(c))
    end)
  )
end

function M.new(_name, cfg, deps)
  local transport = deps.transport
  local json = deps.json
  local token_resolver = deps.token_resolver
  local api_version = cfg.api_version or "7.0"
  local template = cfg.template or "{id} {title}"

  local base = string.format(
    "https://dev.azure.com/%s/%s/_apis/wit",
    encode_segment(cfg.organization),
    encode_segment(cfg.project)
  )

  local source = {}

  -- Issue one request and decode its JSON body, mapping any HTTP/transport/parse
  -- failure into a single "ADO sync failed" error for the caller.
  local function request(opts, cb)
    transport.request(opts, function(response, err)
      if err then
        return cb(nil, "worklog: ADO sync failed: " .. err)
      end

      if response.status < 200 or response.status >= 300 then
        return cb(nil, "worklog: ADO sync failed: HTTP " .. tostring(response.status))
      end

      local ok, decoded = pcall(json.decode, response.body)
      if not ok or type(decoded) ~= "table" then
        return cb(nil, "worklog: ADO sync failed: invalid JSON response")
      end

      cb(decoded, nil)
    end)
  end

  -- Step 2: hydrate work-item ids into display items.
  local function hydrate(auth, ids, cb)
    if #ids == 0 then
      return cb({}, nil)
    end

    if #ids > MAX_ITEMS then
      local capped = {}
      for i = 1, MAX_ITEMS do
        capped[i] = ids[i]
      end
      ids = capped
    end

    local url = string.format(
      "%s/workitems?ids=%s&fields=%s&api-version=%s",
      base,
      table.concat(ids, ","),
      WORKITEM_FIELDS,
      api_version
    )

    request({ method = "GET", url = url, auth = auth }, function(decoded, err)
      if err then
        return cb(nil, err)
      end

      local items = {}
      for _, work_item in ipairs(decoded.value or {}) do
        local fields = work_item.fields or {}
        table.insert(items, {
          id = tostring(work_item.id or fields["System.Id"] or ""),
          title = fields["System.Title"] or "",
          type = fields["System.WorkItemType"],
          state = fields["System.State"],
          url = work_item.url,
        })
      end

      cb(items, nil)
    end)
  end

  -- Resolve the token, run a WIQL request built by `build_request(auth)`, then
  -- hydrate the matching ids into items. Shared by fetch and search.
  local function collect(cb, build_request)
    local token, err = token_resolver(cfg)
    if not token then
      return cb(nil, err)
    end
    local auth = ":" .. token

    request(build_request(auth), function(decoded, wiql_err)
      if wiql_err then
        return cb(nil, wiql_err)
      end

      local ids = {}
      for _, work_item in ipairs(decoded.workItems or {}) do
        if work_item.id ~= nil then
          table.insert(ids, tostring(work_item.id))
        end
      end

      hydrate(auth, ids, cb)
    end)
  end

  -- The default set: raw query, saved query id, or the built-in default WIQL.
  function source.fetch(cb)
    collect(cb, function(auth)
      if cfg.query_id then
        return {
          method = "GET",
          url = string.format(
            "%s/wiql/%s?api-version=%s",
            base,
            encode_segment(cfg.query_id),
            api_version
          ),
          auth = auth,
        }
      end

      return {
        method = "POST",
        url = string.format("%s/wiql?api-version=%s", base, api_version),
        auth = auth,
        headers = { ["Content-Type"] = "application/json" },
        body = json.encode({ query = cfg.query or DEFAULT_WIQL }),
      }
    end)
  end

  -- Live, project-wide text search over work-item titles (used by the Telescope
  -- live picker). The wiql endpoint is already project-scoped by the URL.
  function source.search(query, cb)
    local escaped = (query or ""):gsub("'", "''")
    local wiql = string.format(
      "SELECT [System.Id] FROM WorkItems "
        .. "WHERE [System.Title] CONTAINS WORDS '%s' "
        .. "AND [System.State] <> 'Closed' AND [System.State] <> 'Removed' "
        .. "ORDER BY [System.ChangedDate] DESC",
      escaped
    )

    collect(cb, function(auth)
      return {
        method = "POST",
        url = string.format("%s/wiql?api-version=%s", base, api_version),
        auth = auth,
        headers = { ["Content-Type"] = "application/json" },
        body = json.encode({ query = wiql }),
      }
    end)
  end

  function source.format_item(item)
    if cfg.format_item then
      return cfg.format_item(item)
    end

    return string.format(
      "#%s  %s  [%s/%s]",
      item.id,
      item.title,
      item.type or "?",
      item.state or "?"
    )
  end

  function source.to_entry_text(item)
    local map = {
      id = tostring(item.id or ""),
      title = item.title or "",
      type = item.type or "",
      state = item.state or "",
    }

    -- Plain template expansion; insert_entry sanitizes the result so the title
    -- cannot inject trailing metadata.
    return (
      template:gsub("{(%w+)}", function(key)
        return map[key] ~= nil and map[key] or ("{" .. key .. "}")
      end)
    )
  end

  return source
end

return M
