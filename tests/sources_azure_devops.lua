return function(t)
  local azure = require("daylog.sources.azure_devops")

  -- A fake transport returns canned responses by request and records what it saw,
  -- so the provider is exercised entirely offline.
  local function fake_transport(responder)
    local seen = {}
    return {
      seen = seen,
      request = function(opts, cb)
        table.insert(seen, opts)
        local response, err = responder(opts)
        cb(response, err)
      end,
    }
  end

  local function base_cfg(overrides)
    local cfg = {
      organization = "contoso",
      project = "Platform",
      api_version = "7.0",
      template = "{id} {title}",
      -- Live search is opt-in; enable it by default here so the search tests below
      -- exercise it (the default-off behavior is covered by its own test).
      search = true,
    }
    for key, value in pairs(overrides or {}) do
      cfg[key] = value
    end
    return cfg
  end

  local function new_source(cfg, transport, token_resolver)
    return azure.new("ADO", cfg, {
      transport = transport,
      json = vim.json,
      token_resolver = token_resolver or function()
        return "secret-pat"
      end,
    })
  end

  t.test("fetch runs WIQL then hydrates work items", function()
    local transport = fake_transport(function(opts)
      if opts.url:match("/wiql%?") then
        return {
          status = 200,
          body = vim.json.encode({ workItems = { { id = 1234 }, { id = 42 } } }),
        }
      end

      return {
        status = 200,
        body = vim.json.encode({
          value = {
            {
              id = 1234,
              fields = {
                ["System.Title"] = "Fix login",
                ["System.WorkItemType"] = "Bug",
                ["System.State"] = "Active",
                ["System.ChangedDate"] = "2026-06-20T08:00:00Z",
              },
            },
            {
              id = 42,
              fields = {
                ["System.Title"] = "Docs",
                ["System.WorkItemType"] = "Task",
                ["System.State"] = "New",
                ["System.ChangedDate"] = "2026-06-19T10:00:00Z",
              },
            },
          },
        }),
      }
    end)

    local source = new_source(base_cfg(), transport)
    local result
    source.fetch(function(items, err)
      result = { items = items, err = err }
    end)

    t.eq(result.err, nil)
    t.eq(result.items, {
      -- `updated` (System.ChangedDate, ISO-8601) is carried for the cross-source ranker.
      {
        id = "1234",
        title = "Fix login",
        type = "Bug",
        state = "Active",
        updated = "2026-06-20T08:00:00Z",
      },
      { id = "42", title = "Docs", type = "Task", state = "New", updated = "2026-06-19T10:00:00Z" },
    })

    -- The PAT only ever appears in the request credentials, never in an item.
    t.eq(transport.seen[1].method, "POST")
    t.eq(transport.seen[1].auth, ":secret-pat")
    t.ok(transport.seen[1].url:match("/wiql%?api%-version=7%.0$") ~= nil)
  end)

  t.test("fetch errors on a non-flat (tree/one-hop) query instead of an empty picker", function()
    local hydrated = false
    local transport = fake_transport(function(opts)
      if opts.url:match("/wiql%?") then
        return {
          status = 200,
          body = vim.json.encode({
            queryType = "tree",
            workItemRelations = { { target = { id = 1234 } }, { target = { id = 42 } } },
          }),
        }
      end
      hydrated = true
      return { status = 200, body = vim.json.encode({ value = {} }) }
    end)

    local result
    new_source(base_cfg(), transport).fetch(function(items, err)
      result = { items = items, err = err }
    end)

    t.eq(result.items, nil)
    t.eq(
      result.err,
      "daylog: this Azure DevOps query returns linked items; use a flat work-item query"
    )
    t.ok(not hydrated, "hydrate is not called for a non-flat query")
  end)

  t.test("fetch uses the default WIQL when no query is configured", function()
    local transport = fake_transport(function(opts)
      if opts.url:match("/wiql%?") then
        return { status = 200, body = vim.json.encode({ workItems = {} }) }
      end
      return { status = 200, body = vim.json.encode({ value = {} }) }
    end)

    local source = new_source(base_cfg(), transport)
    local items
    source.fetch(function(result)
      items = result
    end)

    t.eq(items, {})
    -- Only the WIQL request happens when there are no ids to hydrate.
    t.eq(#transport.seen, 1)
    -- "Involves me" = assigned or created.
    local body = vim.json.decode(transport.seen[1].body)
    t.ok(body.query:match("%[System%.AssignedTo%] = @Me") ~= nil, body.query)
    t.ok(body.query:match("%[System%.CreatedBy%] = @Me") ~= nil, body.query)
  end)

  t.test("fetch with no project or projects runs organization-wide", function()
    local transport = fake_transport(function(opts)
      if opts.url:match("/wiql%?") then
        return { status = 200, body = vim.json.encode({ workItems = {} }) }
      end
      return { status = 200, body = vim.json.encode({ value = {} }) }
    end)

    -- Neither project nor projects -> org-scoped URL, no team-project filter.
    local source = new_source({
      organization = "contoso",
      api_version = "7.0",
      template = "{id} {title}",
    }, transport)
    source.fetch(function() end)

    t.ok(
      transport.seen[1].url:match("dev%.azure%.com/contoso/_apis/wit/wiql") ~= nil,
      transport.seen[1].url
    )
    local body = vim.json.decode(transport.seen[1].body)
    t.ok(body.query:match("%[System%.AssignedTo%] = @Me") ~= nil, body.query)
    t.ok(body.query:match("%[System%.CreatedBy%] = @Me") ~= nil, body.query)
    t.ok(body.query:match("TeamProject") == nil, body.query)
  end)

  t.test("fetch runs a saved query by id with GET", function()
    local transport = fake_transport(function(opts)
      if opts.url:match("/wiql/") then
        return { status = 200, body = vim.json.encode({ workItems = {} }) }
      end
      return { status = 200, body = vim.json.encode({ value = {} }) }
    end)

    local source = new_source(base_cfg({ query_id = "abc-123" }), transport)
    source.fetch(function() end)

    t.eq(transport.seen[1].method, "GET")
    t.ok(transport.seen[1].url:match("/wiql/abc%-123%?") ~= nil)
  end)

  t.test("fetch surfaces an HTTP error", function()
    local transport = fake_transport(function()
      return { status = 401, body = "" }
    end)

    local source = new_source(base_cfg(), transport)
    local captured
    source.fetch(function(items, err)
      captured = { items = items, err = err }
    end)

    t.eq(captured.items, nil)
    t.ok(captured.err:match("ADO sync failed") ~= nil)
    t.ok(captured.err:match("401") ~= nil)
  end)

  t.test("fetch reports a token failure without calling the transport", function()
    local transport = fake_transport(function()
      return { status = 200, body = "{}" }
    end)

    local source = new_source(base_cfg(), transport, function()
      return nil, "daylog: token missing"
    end)

    local captured
    source.fetch(function(items, err)
      captured = { items = items, err = err }
    end)

    t.eq(captured.items, nil)
    t.eq(captured.err, "daylog: token missing")
    t.eq(#transport.seen, 0)
  end)

  t.test("to_entry_text expands the template (sanitization happens at insert)", function()
    local source = new_source(base_cfg(), fake_transport(function() end))
    t.eq(source.to_entry_text({ id = "5", title = "Fix login" }), "5 Fix login")
    t.eq(source.to_entry_text({ id = "5", title = "Rework #flaky" }), "5 Rework #flaky")
  end)

  t.test("format_item leads with the rendered name, the metadata trailing", function()
    -- The rendered name (to_entry_text) is first so it lines up with plain activity rows; the
    -- metadata trails it directly on each row.
    local source = new_source(base_cfg(), fake_transport(function() end))
    t.eq(
      source.format_item({ id = "5", title = "Fix", type = "Bug", state = "Active" }),
      "5 Fix  [Bug/Active]"
    )
    -- A long title does not push the metadata away: there is no cross-item column padding
    -- (no format_items), so it stays adjacent and visible in the picker.
    t.eq(source.format_items, nil)
    t.eq(
      source.format_item({
        id = "105210",
        title = "Investigate auth timeout",
        type = "Bug",
        state = "Active",
      }),
      "105210 Investigate auth timeout  [Bug/Active]"
    )
  end)

  t.test("search is omitted unless enabled (offline by default)", function()
    local transport = fake_transport(function()
      return { status = 200, body = "{}" }
    end)

    -- No `search` key (the real default after config normalization) -> no method,
    -- so the picker stays cache-only.
    local off = new_source({
      organization = "contoso",
      project = "Platform",
      api_version = "7.0",
      template = "{id} {title}",
    }, transport)
    t.eq(off.search, nil)

    t.ok(type(new_source(base_cfg(), transport).search) == "function")
  end)

  t.test("search runs a WIQL CONTAINS WORDS query then hydrates", function()
    local transport = fake_transport(function(opts)
      if opts.url:match("/wiql%?") then
        return { status = 200, body = vim.json.encode({ workItems = { { id = 55 } } }) }
      end
      return {
        status = 200,
        body = vim.json.encode({
          value = {
            {
              id = 55,
              fields = {
                ["System.Title"] = "Login flow",
                ["System.WorkItemType"] = "Bug",
                ["System.State"] = "Active",
              },
            },
          },
        }),
      }
    end)

    local source = new_source(base_cfg(), transport)
    local result
    source.search("login", function(items, err)
      result = { items = items, err = err }
    end)

    t.eq(result.err, nil)
    t.eq(result.items, { { id = "55", title = "Login flow", type = "Bug", state = "Active" } })

    t.eq(transport.seen[1].method, "POST")
    local body = vim.json.decode(transport.seen[1].body)
    t.ok(body.query:match("CONTAINS WORDS 'login'") ~= nil, body.query)
    -- Search is scoped to your items too, so it can't surface another team's.
    t.ok(body.query:match("%[System%.CreatedBy%] = @Me") ~= nil, body.query)
  end)

  t.test("search escapes single quotes in the query", function()
    local transport = fake_transport(function(opts)
      if opts.url:match("/wiql%?") then
        return { status = 200, body = vim.json.encode({ workItems = {} }) }
      end
      return { status = 200, body = vim.json.encode({ value = {} }) }
    end)

    local source = new_source(base_cfg(), transport)
    source.search("o'brien", function() end)

    local body = vim.json.decode(transport.seen[1].body)
    t.ok(body.query:match("CONTAINS WORDS 'o''brien'") ~= nil, body.query)
  end)

  t.test("search reports a token failure without calling the transport", function()
    local transport = fake_transport(function()
      return { status = 200, body = "{}" }
    end)
    local source = new_source(base_cfg(), transport, function()
      return nil, "daylog: token missing"
    end)

    local captured
    source.search("x", function(items, err)
      captured = { items = items, err = err }
    end)

    t.eq(captured.items, nil)
    t.eq(captured.err, "daylog: token missing")
    t.eq(#transport.seen, 0)
  end)

  t.test("search caps hydration at 200 and reports the full match total", function()
    local refs = {}
    for i = 1, 250 do
      refs[i] = { id = i }
    end

    local transport = fake_transport(function(opts)
      if opts.url:match("/wiql%?") then
        return { status = 200, body = vim.json.encode({ workItems = refs }) }
      end

      -- Hydrate echoes one item per requested id; the cap means 200 reach here.
      local value = {}
      local ids_str = opts.url:match("ids=([%d,]+)") or ""
      for id in ids_str:gmatch("%d+") do
        table.insert(value, {
          id = tonumber(id),
          fields = { ["System.Title"] = "Item " .. id },
        })
      end
      return { status = 200, body = vim.json.encode({ value = value }) }
    end)

    local source = new_source(base_cfg(), transport)
    local result
    source.search("widespread", function(items, err, total)
      result = { items = items, err = err, total = total }
    end)

    t.eq(result.err, nil)
    t.eq(#result.items, 200)
    t.eq(result.total, 250)
  end)

  t.test("a projects list runs org-scoped WIQL filtered by team project", function()
    local transport = fake_transport(function(opts)
      if opts.url:match("/wiql%?") then
        return { status = 200, body = vim.json.encode({ workItems = { { id = 7 } } }) }
      end
      return {
        status = 200,
        body = vim.json.encode({
          value = {
            {
              id = 7,
              fields = {
                ["System.Title"] = "Cross-project",
                ["System.WorkItemType"] = "Bug",
                ["System.State"] = "Active",
                ["System.TeamProject"] = "Data",
              },
            },
          },
        }),
      }
    end)

    local cfg = {
      organization = "contoso",
      projects = { "Platform", "Data" },
      api_version = "7.0",
      template = "{id} {title}",
      search = true,
    }
    local source = new_source(cfg, transport)
    local result
    source.search("cross", function(items, err)
      result = { items = items, err = err }
    end)

    t.eq(result.err, nil)
    t.eq(result.items, {
      { id = "7", title = "Cross-project", type = "Bug", state = "Active", project = "Data" },
    })

    -- Organization-scoped: no /<project>/ segment before _apis on either request.
    t.ok(
      transport.seen[1].url:match("dev%.azure%.com/contoso/_apis/wit/wiql") ~= nil,
      transport.seen[1].url
    )
    t.ok(
      transport.seen[2].url:match("dev%.azure%.com/contoso/_apis/wit/workitems") ~= nil,
      transport.seen[2].url
    )

    local body = vim.json.decode(transport.seen[1].body)
    t.ok(body.query:match("%[System%.TeamProject%] IN %('Platform', 'Data'%)") ~= nil, body.query)

    -- format_item labels the project when several are configured (rendered name first).
    t.eq(source.format_item(result.items[1]), "7 Cross-project  [Bug/Active]  Data")
  end)

  t.test("a project name with a single quote is escaped in the WIQL", function()
    local transport = fake_transport(function(opts)
      if opts.url:match("/wiql%?") then
        return { status = 200, body = vim.json.encode({ workItems = {} }) }
      end
      return { status = 200, body = vim.json.encode({ value = {} }) }
    end)

    local source = new_source(
      { organization = "contoso", projects = { "Pro'ject", "B" }, search = true },
      transport
    )
    source.search("x", function() end)

    local body = vim.json.decode(transport.seen[1].body)
    t.ok(body.query:match("IN %('Pro''ject', 'B'%)") ~= nil, body.query)
  end)

  t.test("hydrate skips work items that have no id", function()
    local transport = fake_transport(function(opts)
      if opts.url:match("/wiql%?") then
        return { status = 200, body = vim.json.encode({ workItems = { { id = 1 }, { id = 2 } } }) }
      end
      return {
        status = 200,
        body = vim.json.encode({
          value = {
            { id = 1, fields = { ["System.Title"] = "Real" } },
            { fields = {} }, -- malformed: no id
          },
        }),
      }
    end)

    local source = new_source(base_cfg(), transport)
    local result
    source.fetch(function(items, err)
      result = { items = items, err = err }
    end)

    t.eq(result.err, nil)
    t.eq(result.items, { { id = "1", title = "Real" } })
  end)
end
