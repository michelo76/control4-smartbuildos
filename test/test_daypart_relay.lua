-- Daypart Scheduler relay router: token wall, tokenless ping and page,
-- PIN-gate reasons become 403s, validation failures 422s. Pure, no sockets.
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

local Relay = require("daypart.relay")
local JSON = require("JSON")

local seen = {}
local provider = {
  appHtml = function()
    return "<html>page</html>"
  end,
  state = function()
    return '{"zones":[]}'
  end,
  verify = function(pin)
    return pin == "1234", pin ~= "1234" and "wrong_pin" or nil
  end,
  edit = function(doc)
    seen[#seen + 1] = doc
    if doc.pin ~= "1234" then
      return { ok = false, reason = "wrong_pin", error = "no" }
    end
    if doc.op == "bad" then
      return { ok = false, error = "Overlaps" }
    end
    if doc.op == "boom" then
      error("kaboom")
    end
    return { ok = true }
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
local TOKEN = "tok123"

local r = Relay.route(req("GET", "/ping"), TOKEN, provider)
check("ping is tokenless and names the service", r.status:find("200") and r.body:find('"daypart"'))
r = Relay.route(req("GET", "/app"), TOKEN, provider)
check(
  "the page is tokenless html",
  r.status:find("200") and r.contentType:find("text/html") and r.body == "<html>page</html>"
)
r = Relay.route(req("GET", "/app"), TOKEN, {
  appHtml = function()
    return nil
  end,
})
check("a page that cannot load is a 503", r.status:find("503"))
r = Relay.route(req("OPTIONS", "/edit"), TOKEN, provider)
check("CORS preflight answered before the token wall", r.status:find("204"))
r = Relay.route(req("GET", "/state"), TOKEN, provider)
check("state without a token is 403", r.status:find("403"))
r = Relay.route(req("GET", "/state", { k = "wrong" }), TOKEN, provider)
check("state with a wrong token is 403", r.status:find("403"))
r = Relay.route(req("GET", "/state", { k = TOKEN }), TOKEN, provider)
check("state with the token", r.status:find("200") and r.body == '{"zones":[]}')
r = Relay.route(req("GET", "/state", { k = "x" }), "", provider)
check("an empty server token never matches", r.status:find("403"))
r = Relay.route(req("POST", "/state", { k = TOKEN }), TOKEN, provider)
check("state is GET only", r.status:find("405"))
r = Relay.route(req("GET", "/edit", { k = TOKEN }), TOKEN, provider)
check("edit is POST only", r.status:find("405"))
r = Relay.route(req("POST", "/nothing", { k = TOKEN }, "{}"), TOKEN, provider)
check("unknown routes are 404", r.status:find("404"))
r = Relay.route(req("POST", "/edit", { k = TOKEN }, "not json"), TOKEN, provider)
check("a body that is not JSON is 400", r.status:find("400"))
r = Relay.route(req("POST", "/edit", { k = TOKEN }, '"a string"'), TOKEN, provider)
check("a JSON string is not an object: 400", r.status:find("400"))
r = Relay.route(req("POST", "/verify", { k = TOKEN }, '{"pin":"1234"}'), TOKEN, provider)
check("verify with the right PIN", r.status:find("200") and r.body:find('"ok":true'))
r = Relay.route(req("POST", "/verify", { k = TOKEN }, '{"pin":"0"}'), TOKEN, provider)
check(
  "verify with a wrong PIN is 403 and never echoes it",
  r.status:find("403") and not r.body:find('"0"') and r.body:find("wrong_pin")
)
r = Relay.route(req("POST", "/edit", { k = TOKEN }, '{"pin":"1234","op":"x"}'), TOKEN, provider)
check("a good edit", r.status:find("200"))
r = Relay.route(req("POST", "/edit", { k = TOKEN }, '{"pin":"0","op":"x"}'), TOKEN, provider)
check("a PIN refusal is 403", r.status:find("403"))
r = Relay.route(req("POST", "/edit", { k = TOKEN }, '{"pin":"1234","op":"bad"}'), TOKEN, provider)
check("a validation refusal is 422", r.status:find("422") and r.body:find("Overlaps"))
r = Relay.route(req("POST", "/edit", { k = TOKEN }, '{"pin":"1234","op":"boom"}'), TOKEN, provider)
check("a provider that throws is a 500, not a crash", r.status:find("500"))
r = Relay.route({ method = "BAD", path = "/", query = {}, body = "" }, TOKEN, provider)
check("a malformed request is 400", r.status:find("400"))
local parsed = Relay.parse("POST /edit?k=abc HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}")
check(
  "the request parser is the shared one",
  parsed ~= nil and parsed.method == "POST" and parsed.query.k == "abc" and parsed.body == "{}"
)
check("the gate is the shared PIN gate", type(Relay.newGate) == "function")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
