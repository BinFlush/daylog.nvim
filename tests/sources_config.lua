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
    t.ok(type(source.token) == "function")

    config.setup()
    t.eq(config.get().sources, nil)
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
      "project must be a non%-empty string"
    )
    bad(azure({ token = "pat" }), "token must be a function")
    bad(azure({ query = "q", query_id = "id" }), "must not set both query and query_id")
    bad(azure({ ttl = -1 }), "ttl must be a positive integer")

    config.setup()
  end)
end
