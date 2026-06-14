return function(t)
  local config = require("worklog.config")

  t.test("config normalizes a source and fills defaults", function()
    config.setup({
      sources = {
        ADO = {
          type = "azure_devops",
          organization = "contoso",
          project = "Platform",
          token = function()
            return "pat"
          end,
        },
      },
    })

    local source = config.get().sources.ADO
    t.eq(source.type, "azure_devops")
    t.eq(source.organization, "contoso")
    t.eq(source.project, "Platform")
    t.eq(source.ttl, 1800)
    t.eq(source.template, "{id} {title}")
    t.eq(source.api_version, "7.0")
    t.eq(source.min_query, 3)
    t.ok(type(source.token) == "function")

    config.setup()
    t.eq(config.get().sources, nil)
  end)

  t.test("config accepts an explicit min_query", function()
    config.setup({
      sources = {
        ADO = {
          type = "azure_devops",
          organization = "contoso",
          project = "Platform",
          token = function()
            return "pat"
          end,
          min_query = 1,
        },
      },
    })

    t.eq(config.get().sources.ADO.min_query, 1)
    config.setup()
  end)

  t.test("config accepts a projects list instead of a single project", function()
    config.setup({
      sources = {
        ADO = {
          type = "azure_devops",
          organization = "contoso",
          projects = { "Platform", "Data" },
          token = function()
            return "pat"
          end,
        },
      },
    })

    local source = config.get().sources.ADO
    t.eq(source.projects, { "Platform", "Data" })
    t.eq(source.project, nil)
    config.setup()
  end)

  t.test("config validates sources", function()
    local function bad(options, pattern)
      local ok, err = pcall(config.setup, options)
      t.ok(not ok)
      t.ok(tostring(err):match(pattern) ~= nil, tostring(err))
    end

    local function azure(overrides)
      local entry = {
        type = "azure_devops",
        organization = "O",
        project = "P",
        token = function() end,
      }
      for key, value in pairs(overrides) do
        entry[key] = value
      end
      return { sources = { ADO = entry } }
    end

    bad({ sources = "x" }, "setup sources must be a table")
    bad({ sources = { ["bad name"] = { type = "azure_devops" } } }, "source names must use only")
    bad({ sources = { ADO = { type = "jira" } } }, "unknown type")
    bad(
      { sources = { ADO = { type = "azure_devops", project = "P", token = function() end } } },
      "organization must be a non%-empty string"
    )
    bad(
      { sources = { ADO = { type = "azure_devops", organization = "O", token = function() end } } },
      "must set 'project' or 'projects'"
    )
    bad(azure({ token = "pat" }), "token must be a function")
    bad(azure({ query = "q", query_id = "id" }), "must not set both query and query_id")
    bad(azure({ ttl = -1 }), "ttl must be a positive integer")
    bad(azure({ min_query = 0 }), "min_query must be a positive integer")
    bad(azure({ min_query = 1.5 }), "min_query must be a positive integer")
    bad(azure({ projects = { "A" } }), "must not set both project and projects")

    local function ado(overrides)
      local entry = { type = "azure_devops", organization = "O", token = function() end }
      for key, value in pairs(overrides) do
        entry[key] = value
      end
      return { sources = { ADO = entry } }
    end

    bad(ado({ projects = {} }), "projects must be a non%-empty list")
    bad(ado({ projects = { "A", 2 } }), "projects must be a non%-empty list")
    bad(ado({ projects = { "A" }, query_id = "x" }), "cannot combine projects with query")

    config.setup()
  end)
end
