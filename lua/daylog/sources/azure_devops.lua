local M = {}

-- Azure DevOps work-item source (PURE via dependency injection).
--
-- Networking goes through an injected transport and JSON through an injected codec, so it runs
-- offline in tests. The PAT is resolved lazily via deps.token_resolver and only ever placed in
-- the request credentials -- never in an item or the cache.

-- Field/id lists are literal (safe constants/digits); only opaque path segments are encoded.
local WORKITEM_FIELDS =
  "System.Id,System.Title,System.WorkItemType,System.State,System.TeamProject,System.ChangedDate"
local MAX_ITEMS = 200

-- Broadest "involves me" predicate WIQL expresses cleanly; shared by fetch and search.
local INVOLVES_ME = "([System.AssignedTo] = @Me OR [System.CreatedBy] = @Me)"
local STATE_OPEN = "[System.State] <> 'Closed' AND [System.State] <> 'Removed'"
local ORDER_NEWEST = "ORDER BY [System.ChangedDate] DESC, [System.Id] DESC"

local function encode_segment(segment)
  return (
    segment:gsub("[^%w%-%._~]", function(c)
      return string.format("%%%02X", string.byte(c))
    end)
  )
end

-- JSON codecs decode `null` to a truthy sentinel (vim.NIL) that `or` fallbacks miss; admit only
-- genuinely typed values at the decode boundary.
local function str(v)
  if type(v) == "string" then
    return v
  end
  return nil
end

local function tbl(v)
  if type(v) == "table" then
    return v
  end
  return {}
end

function M.new(_name, cfg, deps)
  local transport = deps.transport
  local json = deps.json
  local token_resolver = deps.token_resolver
  local api_version = cfg.api_version or "7.0"
  local template = cfg.template or "{id} {title}"

  -- A single `project` scopes requests via URL segment; otherwise org-scoped, with a `projects`
  -- list narrowing the WIQL by team-project filter (neither spans the whole org).
  local base
  local project_filter = ""
  if cfg.project then
    base = string.format(
      "https://dev.azure.com/%s/%s/_apis/wit",
      encode_segment(cfg.organization),
      encode_segment(cfg.project)
    )
  else
    base = string.format("https://dev.azure.com/%s/_apis/wit", encode_segment(cfg.organization))
    if cfg.projects then
      local quoted = {}
      for _, project in ipairs(cfg.projects) do
        quoted[#quoted + 1] = "'" .. project:gsub("'", "''") .. "'"
      end
      project_filter = " AND [System.TeamProject] IN (" .. table.concat(quoted, ", ") .. ")"
    end
  end

  -- Default set: items involving you, active, recently changed, plus the team-project filter
  -- (in the WHERE clause before ORDER BY; "" for a single project or org-wide).
  local default_wiql = table.concat({
    "SELECT [System.Id] FROM WorkItems",
    "WHERE " .. INVOLVES_ME,
    "AND " .. STATE_OPEN,
    "AND [System.ChangedDate] >= @Today - 30" .. project_filter,
    -- Id tiebreaker so the 200-item cap is deterministic when items share a ChangedDate.
    ORDER_NEWEST,
  }, " ")

  local source = {}

  -- Issue one request and decode its JSON body, mapping any HTTP/transport/parse
  -- failure into a single "ADO sync failed" error for the caller.
  local function request(opts, cb)
    transport.request(opts, function(response, err)
      if err then
        return cb(nil, "daylog: ADO sync failed: " .. err)
      end

      -- ADO answers an invalid/expired PAT with HTTP 203 + an HTML sign-in page; name the real
      -- problem instead of failing opaquely in the JSON decode below.
      if response.status == 203 then
        return cb(nil, "daylog: ADO sync failed: authentication failed (check your PAT)")
      end

      if response.status < 200 or response.status >= 300 then
        return cb(nil, "daylog: ADO sync failed: HTTP " .. tostring(response.status))
      end

      local ok, decoded = pcall(json.decode, response.body)
      if not ok or type(decoded) ~= "table" then
        return cb(nil, "daylog: ADO sync failed: invalid JSON response")
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
      for _, value in ipairs(tbl(tbl(decoded).value)) do
        local work_item = tbl(value)
        local fields = tbl(work_item.fields)
        local raw_id = work_item.id or fields["System.Id"]
        local id = (type(raw_id) == "string" or type(raw_id) == "number") and tostring(raw_id) or ""
        -- Skip a malformed entry with no id rather than emit an empty-id item.
        if id ~= "" then
          table.insert(items, {
            id = id,
            title = str(fields["System.Title"]) or "",
            type = str(fields["System.WorkItemType"]),
            state = str(fields["System.State"]),
            -- A recency signal for the (cross-source) ranker; ADO returns ISO-8601.
            updated = str(fields["System.ChangedDate"]),
            project = str(fields["System.TeamProject"]),
            url = str(work_item.url),
          })
        end
      end

      cb(items, nil)
    end)
  end

  -- The WIQL POST request for a query string, shared by fetch (default / raw query) and search.
  local function wiql_post(auth, query)
    return {
      method = "POST",
      url = string.format("%s/wiql?api-version=%s", base, api_version),
      auth = auth,
      headers = { ["Content-Type"] = "application/json" },
      body = json.encode({ query = query }),
    }
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
      for _, work_item in ipairs(tbl(tbl(decoded).workItems)) do
        local id = tbl(work_item).id
        if type(id) == "string" or type(id) == "number" then
          table.insert(ids, tostring(id))
        end
      end

      -- A tree/one-hop saved query returns `workItemRelations`, not `workItems`, hydrating to an
      -- empty picker indistinguishable from "no items"; surface the misconfiguration instead.
      if #ids == 0 and tbl(decoded).workItemRelations ~= nil then
        return cb(
          nil,
          "daylog: this Azure DevOps query returns linked items; use a flat work-item query"
        )
      end

      -- Report the full match count so the picker can flag hydrate's 200-item cap truncation.
      local total = #ids
      hydrate(auth, ids, function(items, hydrate_err)
        cb(items, hydrate_err, total)
      end)
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

      return wiql_post(auth, cfg.query or default_wiql)
    end)
  end

  -- Optional live title search (Telescope), scoped like fetch. Off by default (the offline cache
  -- is the picker); enabled per source with `search = true`.
  local function run_search(query, cb)
    local escaped = (query or ""):gsub("'", "''")
    local wiql = string.format(
      "SELECT [System.Id] FROM WorkItems "
        .. "WHERE [System.Title] CONTAINS WORDS '%s' "
        .. "AND "
        .. INVOLVES_ME
        .. " AND "
        .. STATE_OPEN
        .. "%s"
        .. " "
        .. ORDER_NEWEST,
      escaped,
      project_filter
    )

    collect(cb, function(auth)
      return wiql_post(auth, wiql)
    end)
  end

  if cfg.search then
    source.search = run_search
  end

  -- One item's picker line: the rendered name (to_entry_text) leads, then [type/state] and the
  -- project trail as metadata. Not column-aligned on purpose -- padding to the widest name would
  -- shove metadata off the right when titles vary, so it trails each name directly.
  function source.format_item(item)
    if cfg.format_item then
      return cfg.format_item(item)
    end

    local cells = {
      source.to_entry_text(item),
      string.format("[%s/%s]", item.type or "?", item.state or "?"),
    }
    if cfg.projects then
      cells[#cells + 1] = item.project or "?"
    end
    return (table.concat(cells, "  "):gsub("%s+$", ""))
  end

  function source.to_entry_text(item)
    local map = {
      id = tostring(item.id or ""),
      title = item.title or "",
      type = item.type or "",
      state = item.state or "",
      project = item.project or "",
    }

    -- insert_entry sanitizes the result so the title cannot inject trailing metadata.
    return (
      template:gsub("{(%w+)}", function(key)
        return map[key] ~= nil and map[key] or ("{" .. key .. "}")
      end)
    )
  end

  return source
end

return M
