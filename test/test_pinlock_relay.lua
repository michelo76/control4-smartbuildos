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
check(
  "wrong token: 403",
  relay.route(req("POST", "/unlock", { k = "x" }, "{}"), "tok", provider).status == "403 Forbidden"
)
check("no server token: 403", relay.route(req("GET", "/config", { k = "" }), "", provider).status == "403 Forbidden")
check("a provider call never happens behind the wall", seen.unlock == nil)

print("[3] routes")
r = relay.route(req("GET", "/config", { k = "tok" }), "tok", provider)
check(
  "config returns ok + actions",
  r.status == "200 OK" and JSON:decode(r.body).ok == true and #JSON:decode(r.body).actions == 1
)
r = relay.route(req("POST", "/unlock", { k = "tok" }, '{"action":1,"pin":"4826"}'), "tok", provider)
check(
  "unlock reaches the provider with the body",
  r.status == "200 OK" and seen.unlock.pin == "4826" and seen.unlock.action == 1
)
check("the reply echoes no PIN", r.body:find("4826", 1, true) == nil)
r = relay.route(req("POST", "/unlock", { k = "tok" }, "not json"), "tok", provider)
check("non-JSON body: 400", r.status == "400 Bad Request")
r = relay.route(req("POST", "/admin/login", { k = "tok" }, "{}"), "tok", provider)
check(
  "a provider that throws is a 500 with no detail",
  r.status == "500 Internal Server Error" and r.body:find("boom") == nil
)
r = relay.route(req("POST", "/admin/state", { k = "tok" }, '{"session":"x"}'), "tok", provider)
check("provider status passes through (401)", r.status == "401 Unauthorized")
check(
  "unknown POST route: 404",
  relay.route(req("POST", "/admin/nope", { k = "tok" }, "{}"), "tok", provider).status == "404 Not Found"
)
check(
  "route without a provider function: 404",
  relay.route(req("POST", "/admin/save", { k = "tok" }, "{}"), "tok", provider).status == "404 Not Found"
)
check(
  "GET on a POST route: 405",
  relay.route(req("GET", "/unlock", { k = "tok" }), "tok", provider).status == "405 Method Not Allowed"
)
check(
  "PUT refused",
  relay.route(req("PUT", "/unlock", { k = "tok" }), "tok", provider).status == "405 Method Not Allowed"
)

print("[4] parsing: a PIN in the URL is never required")
local parsed = relay.parse('POST /unlock?k=tok HTTP/1.1\r\nContent-Length: 27\r\n\r\n{"action":1,"pin":"4826"}  ')
check("body is parsed separately from the query", parsed ~= nil and parsed.query.k == "tok" and parsed.query.pin == nil)

print("[5] /verify: tokenless, closed body, a closed reply whatever the provider says")
do
  local PIN = "7391" -- test value
  local CH = string.rep("ab", 16)
  local got
  local answer
  local vp = {
    encode = provider.encode,
    decode = provider.decode,
    verify = function(id, pin)
      got = { id = id, pin = pin }
      return answer
    end,
  }
  local function post(body, method)
    return relay.route(req(method or "POST", "/verify", {}, body), "tok", vp)
  end
  local function noLeak(res, label)
    local raw = relay.render(res)
    check(label .. ": no PIN in the response bytes", raw:find(PIN, 1, true) == nil)
    check(label .. ": no code name in the response bytes", raw:find("Marta", 1, true) == nil)
    check(label .. ": no role in the response bytes", raw:find("owner", 1, true) == nil)
  end

  -- A provider that over-shares: the router must not copy any of it.
  answer = { ok = true, code = "Owner Marta", role = "owner", slot = 1, pin = PIN }
  local res = post('{"challenge_id":"' .. CH .. '","pin":"' .. PIN .. '"}')
  check(
    'no page token needed: verified → 200 {"ok":true}',
    res.status == "200 OK" and res.body == '{"ok":true}',
    res.body
  )
  check("the provider got the challenge id and the PIN", got.id == CH and got.pin == PIN)
  noLeak(res, "verified")

  answer = { ok = false, code = "Owner Marta", reason = "not_owner", role = "guest" }
  res = post('{"challenge_id":"' .. CH .. '","pin":"' .. PIN .. '"}')
  check(
    'not verified → 401 {"ok":false} exactly',
    res.status == "401 Unauthorized" and res.body == '{"ok":false}',
    res.body
  )
  noLeak(res, "not verified")

  answer = { ok = false, locked = true, retry_in = 241.7, code = "Owner Marta", reason = "locked_out" }
  res = post('{"challenge_id":"' .. CH .. '","pin":"' .. PIN .. '"}')
  check(
    "locked → 429 {ok:false, locked, retry_in} exactly",
    res.status == "429 Too Many Requests" and res.body == '{"ok":false,"locked":true,"retry_in":241}',
    res.body
  )
  noLeak(res, "locked")

  answer = nil
  res = post('{"challenge_id":"' .. CH .. '","pin":"' .. PIN .. '"}')
  check('a provider answering nothing → {"ok":false}', res.body == '{"ok":false}')

  got = nil
  res = post('{"challenge_id":"' .. CH .. '","pin":"' .. PIN .. '","k":"tok"}')
  check("an extra body key → 400, provider not called", res.status == "400 Bad Request" and got == nil)
  res = post('{"challenge_id":"' .. CH .. '"}')
  check("no PIN → 400, provider not called", res.status == "400 Bad Request" and got == nil)
  res = post('{"challenge_id":"' .. CH .. '","pin":7391}')
  check("a numeric PIN → 400, provider not called", res.status == "400 Bad Request" and got == nil)
  res = post("not json")
  check("non-JSON → 400 with no echo", res.status == "400 Bad Request" and res.body:find("not json") == nil)
  res = post("", "GET")
  check("GET /verify → 405", res.status == "405 Method Not Allowed")
  res = relay.route(req("OPTIONS", "/verify"), "tok", vp)
  check("preflight for /verify answered", res.status == "204 No Content")
  check(
    "CORS headers let another driver's page POST JSON",
    relay.render(res):find("Access-Control-Allow-Origin: *", 1, true) ~= nil
      and relay.render(res):find("Access-Control-Allow-Headers: Content-Type", 1, true) ~= nil
  )
  vp.verify = function()
    error("boom " .. PIN)
  end
  res = post('{"challenge_id":"' .. CH .. '","pin":"' .. PIN .. '"}')
  check(
    "a provider that throws → 500 with no detail",
    res.status == "500 Internal Server Error" and res.body == '{"ok":false}'
  )
  res = relay.route(req("POST", "/verify", {}, '{"challenge_id":"x","pin":"1"}'), "tok", provider)
  check("a provider without verify → 404", res.status == "404 Not Found")
  check("/verify never reaches the page's unlock", seen.unlock.pin == "4826")
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
