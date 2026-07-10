-- Tests for the lazy token resolver injected into every source: its two failure branches (a throwing
-- token(), a non-string/empty token) were previously unexercised.
return function(t)
  local wire = require("daylog.sources.wire")

  t.test("resolve_token returns the token from a valid token()", function()
    local token, err = wire.resolve_token({
      token = function()
        return "secret-pat"
      end,
    })
    t.eq(token, "secret-pat")
    t.eq(err, nil)
  end)

  t.test("resolve_token reports a throwing token()", function()
    local token, err = wire.resolve_token({
      token = function()
        error("pass exited 1")
      end,
    })
    t.eq(token, nil)
    t.ok(err:find("source token() errored", 1, true) ~= nil, "surfaces the throw")
  end)

  t.test("resolve_token rejects an empty or non-string token", function()
    t.eq(
      ({ wire.resolve_token({
        token = function()
          return ""
        end,
      }) })[2],
      "daylog: source token() did not return a non-empty string"
    )
    t.eq(
      ({ wire.resolve_token({
        token = function()
          return nil
        end,
      }) })[2],
      "daylog: source token() did not return a non-empty string"
    )
  end)
end
