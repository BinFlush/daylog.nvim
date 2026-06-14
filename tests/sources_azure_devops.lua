return function(t)
  local azure = require("worklog.sources.azure_devops")

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
              },
            },
            {
              id = 42,
              fields = {
                ["System.Title"] = "Docs",
                ["System.WorkItemType"] = "Task",
                ["System.State"] = "New",
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
      { id = "1234", title = "Fix login", type = "Bug", state = "Active" },
      { id = "42", title = "Docs", type = "Task", state = "New" },
    })

    -- The PAT only ever appears in the request credentials, never in an item.
    t.eq(transport.seen[1].method, "POST")
    t.eq(transport.seen[1].auth, ":secret-pat")
    t.ok(transport.seen[1].url:match("/wiql%?api%-version=7%.0$") ~= nil)
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
    t.ok(vim.json.decode(transport.seen[1].body).query:match("@Me") ~= nil)
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
      return nil, "worklog: token missing"
    end)

    local captured
    source.fetch(function(items, err)
      captured = { items = items, err = err }
    end)

    t.eq(captured.items, nil)
    t.eq(captured.err, "worklog: token missing")
    t.eq(#transport.seen, 0)
  end)

  t.test("to_entry_text expands the template (sanitization happens at insert)", function()
    local source = new_source(base_cfg(), fake_transport(function() end))
    t.eq(source.to_entry_text({ id = "5", title = "Fix login" }), "5 Fix login")
    t.eq(source.to_entry_text({ id = "5", title = "Rework #flaky" }), "5 Rework #flaky")
  end)

  t.test("format_item defaults include id, title, type and state", function()
    local source = new_source(base_cfg(), fake_transport(function() end))
    t.eq(
      source.format_item({ id = "5", title = "Fix", type = "Bug", state = "Active" }),
      "#5  Fix  [Bug/Active]"
    )
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
      return nil, "worklog: token missing"
    end)

    local captured
    source.search("x", function(items, err)
      captured = { items = items, err = err }
    end)

    t.eq(captured.items, nil)
    t.eq(captured.err, "worklog: token missing")
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

    -- format_item labels the project when several are configured.
    t.eq(source.format_item(result.items[1]), "#7  Cross-project  [Bug/Active]  Data")
  end)

  t.test("a project name with a single quote is escaped in the WIQL", function()
    local transport = fake_transport(function(opts)
      if opts.url:match("/wiql%?") then
        return { status = 200, body = vim.json.encode({ workItems = {} }) }
      end
      return { status = 200, body = vim.json.encode({ value = {} }) }
    end)

    local source =
      new_source({ organization = "contoso", projects = { "Pro'ject", "B" } }, transport)
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
