-- PIN Lock relay router: token wall, routes, body handling, and that the
-- router adds nothing to a provider's reply and keeps no copy of a body.
--
-- Run from the driver root: make test

package.path = "src/?.lua;" .. package.path
require("drivers-common-public.global.lib")
local relay = require("pinlock.relay")

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

local JSON = require("JSON")
local seen = {}
local provider = {
  appHtml = function()
    return "<html>page</html>"
  end,
  config = function()
    return { actions = { { n = 1, name = "Unlock" } } }
  end,
  unlock = function(body)
    seen.unlock = body
    return 200, { ok = true, message = "Unlock" }
  end,
  login = function()
    error("boom")
  end,
  state = function()
    return 401, { ok = false, error = "sign in again" }
  end,
  encode = function(t)
    return JSON:encode(t)
  end,
  decode = function(s)
    return JSON:decode(s)
  end,
}
local function req(method, path, query, body)
  return { method = method, path = path, query = query or {}, body = body or "" }
end

print("[1] open routes")
local r = relay.route(req("GET", "/ping"), "tok", provider)
check("ping is tokenless", r.status == "200 OK" and r.body:find("pin-lock", 1, true) ~= nil)
r = relay.route(req("GET", "/app"), "tok", provider)
check("the page is served without a token", r.status == "200 OK" and r.contentType:find("text/html") ~= nil)
r = relay.route(req("OPTIONS", "/unlock"), "tok", provider)
check("preflight answered", r.status == "204 No Content")
r = relay.route({ method = "BAD", path = "/", query = {}, body = "" }, "tok", provider)
check("malformed request is a 400", r.status == "400 Bad Request")

print("[2] token wall")
check("no token: 403", relay.route(req("GET", "/config"), "tok", provider).status == "403 Forbidden")
check("wrong token: 403", relay.route(req("POST", "/unlock", { k = "x" }, "{}"), "tok", provider).status == "403 Forbidden")
check("no server token: 403", relay.route(req("GET", "/config", { k = "" }), "", provider).status == "403 Forbidden")
check("a provider call never happens behind the wall", seen.unlock == nil)

print("[3] routes")
r = relay.route(req("GET", "/config", { k = "tok" }), "tok", provider)
check("config returns ok + actions", r.status == "200 OK" and JSON:decode(r.body).ok == true and #JSON:decode(r.body).actions == 1)
r = relay.route(req("POST", "/unlock", { k = "tok" }, '{"action":1,"pin":"4826"}'), "tok", provider)
check("unlock reaches the provider with the body", r.status == "200 OK" and seen.unlock.pin == "4826" and seen.unlock.action == 1)
check("the reply echoes no PIN", r.body:find("4826", 1, true) == nil)
r = relay.route(req("POST", "/unlock", { k = "tok" }, "not json"), "tok", provider)
check("non-JSON body: 400", r.status == "400 Bad Request")
r = relay.route(req("POST", "/admin/login", { k = "tok" }, "{}"), "tok", provider)
check("a provider that throws is a 500 with no detail", r.status == "500 Internal Server Error" and r.body:find("boom") == nil)
r = relay.route(req("POST", "/admin/state", { k = "tok" }, '{"session":"x"}'), "tok", provider)
check("provider status passes through (401)", r.status == "401 Unauthorized")
check("unknown POST route: 404", relay.route(req("POST", "/admin/nope", { k = "tok" }, "{}"), "tok", provider).status == "404 Not Found")
check("route without a provider function: 404", relay.route(req("POST", "/admin/save", { k = "tok" }, "{}"), "tok", provider).status == "404 Not Found")
check("GET on a POST route: 405", relay.route(req("GET", "/unlock", { k = "tok" }), "tok", provider).status == "405 Method Not Allowed")
check("PUT refused", relay.route(req("PUT", "/unlock", { k = "tok" }), "tok", provider).status == "405 Method Not Allowed")

print("[4] parsing: a PIN in the URL is never required")
local parsed = relay.parse("POST /unlock?k=tok HTTP/1.1\r\nContent-Length: 27\r\n\r\n{\"action\":1,\"pin\":\"4826\"}  ")
check("body is parsed separately from the query", parsed ~= nil and parsed.query.k == "tok" and parsed.query.pin == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
