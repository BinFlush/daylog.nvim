local M = {}

-- Azure DevOps work-item source.
--
-- Config-driven and free of any direct Neovim API call: networking goes through
-- an injected transport (deps.transport.request) and JSON through an injected
-- codec (deps.json), so it is exercised offline in tests with a fake transport.
-- The PAT is resolved lazily via deps.token_resolver and only ever placed in the
-- request credentials -- never in an item or the cache.

-- Comma-separated field list and id list are passed literally (safe constants /
-- digits); only opaque path segments are percent-encoded.
local WORKITEM_FIELDS =
  "System.Id,System.Title,System.WorkItemType,System.State,System.TeamProject,System.ChangedDate"
local MAX_ITEMS = 200

-- The broadest "this item involves me" predicate WIQL can express cleanly (mentions and
-- watching are not queryable). Shared by the default fetch and the live search, so both
-- stay scoped to your work.
local INVOLVES_ME = "([System.AssignedTo] = @Me OR [System.CreatedBy] = @Me)"

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

  -- Scope: a single `project` keeps requests project-scoped (URL segment). Otherwise the
  -- request is organization-scoped -- a `projects` list narrows the WIQL to that subset with a
  -- team-project filter, and neither (the default) spans the whole org.
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

  -- Default set: items that involve you (assigned or created), active, recently changed --
  -- plus the team-project filter when organization-scoped. The filter sits in the WHERE
  -- clause, before the trailing ORDER BY; it is "" for a single project or org-wide.
  local default_wiql = table.concat({
    "SELECT [System.Id] FROM WorkItems",
    "WHERE " .. INVOLVES_ME,
    "AND [System.State] <> 'Closed' AND [System.State] <> 'Removed'",
    "AND [System.ChangedDate] >= @Today - 30" .. project_filter,
    -- Id is a tiebreaker so the 200-item cap is deterministic when several items
    -- (possibly from different projects) share a ChangedDate.
    "ORDER BY [System.ChangedDate] DESC, [System.Id] DESC",
  }, " ")

  local source = {}

  -- Issue one request and decode its JSON body, mapping any HTTP/transport/parse
  -- failure into a single "ADO sync failed" error for the caller.
  local function request(opts, cb)
    transport.request(opts, function(response, err)
      if err then
        return cb(nil, "daylog: ADO sync failed: " .. err)
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
      for _, work_item in ipairs(decoded.value or {}) do
        local fields = work_item.fields or {}
        local id = tostring(work_item.id or fields["System.Id"] or "")
        -- Skip a malformed entry with no id rather than emit an empty-id item.
        if id ~= "" then
          table.insert(items, {
            id = id,
            title = fields["System.Title"] or "",
            type = fields["System.WorkItemType"],
            state = fields["System.State"],
            -- A recency signal for the (cross-source) ranker; ADO returns ISO-8601.
            updated = fields["System.ChangedDate"],
            project = fields["System.TeamProject"],
            url = work_item.url,
          })
        end
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

      -- Report the full match count so the picker can flag when hydrate's 200-item
      -- cap truncated the results; fetch's callers simply ignore the extra arg.
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

      return {
        method = "POST",
        url = string.format("%s/wiql?api-version=%s", base, api_version),
        auth = auth,
        headers = { ["Content-Type"] = "application/json" },
        body = json.encode({ query = cfg.query or default_wiql }),
      }
    end)
  end

  -- Optional live text search over work-item titles (the Telescope live picker),
  -- scoped like fetch by the URL and/or the team-project filter. Off by default --
  -- the offline cache is the picker -- and enabled per source with `search = true`.
  local function run_search(query, cb)
    local escaped = (query or ""):gsub("'", "''")
    local wiql = string.format(
      "SELECT [System.Id] FROM WorkItems "
        .. "WHERE [System.Title] CONTAINS WORDS '%s' "
        .. "AND "
        .. INVOLVES_ME
        .. " AND [System.State] <> 'Closed' AND [System.State] <> 'Removed'"
        .. "%s"
        .. " ORDER BY [System.ChangedDate] DESC, [System.Id] DESC",
      escaped,
      project_filter
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

  if cfg.search then
    source.search = run_search
  end

  -- One item's picker line: the rendered name (`to_entry_text` -- exactly what gets inserted)
  -- leads, so it shows on the far left lined up with the plain activity rows; [type/state], then
  -- the project when several are configured, trail as metadata right after it. The id already
  -- lives inside the rendered name, so it is not repeated. The metadata is not column-aligned
  -- across items on purpose: padding the variable-width name to the widest one would shove the
  -- metadata off the right of the picker when titles vary, so it trails each name directly and
  -- always stays visible. (No format_items, so the display contract falls back to this per item.)
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
