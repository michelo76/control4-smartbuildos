package.path = "src/?.lua;" .. package.path
local Relay = require("usermanual.relay")
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

local refreshed = 0
local provider = {
  appHtml = function()
    return "<!doctype html><title>Home Guide</title>"
  end,
  manual = function()
    return '{"home_name":"Beta","rooms":[]}'
  end,
  refresh = function()
    refreshed = refreshed + 1
  end,
}
local TOKEN = "abc123"
local function req(line, body)
  body = body or ""
  return Relay.parse(line .. "\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body)
end

print("== tokenless routes")
local r = Relay.route(req("OPTIONS /manual HTTP/1.1"), TOKEN, provider)
check("preflight 204", r.status:find("^204") ~= nil)
r = Relay.route(req("GET /ping HTTP/1.1"), TOKEN, provider)
check("ping names the service", r.status:find("^200") ~= nil and r.body:find("home%-guide") ~= nil)
r = Relay.route(req("GET /app HTTP/1.1"), TOKEN, provider)
check(
  "app served as html",
  r.contentType:find("text/html", 1, true) ~= nil and r.body:find("Home Guide", 1, true) ~= nil
)
r = Relay.route(req("GET /app HTTP/1.1"), TOKEN, {
  appHtml = function()
    return nil
  end,
})
check("app missing → 503", r.status:find("^503") ~= nil)

print("== token wall")
r = Relay.route(req("GET /manual HTTP/1.1"), TOKEN, provider)
check("no token → 403", r.status:find("^403") ~= nil)
r = Relay.route(req("GET /manual?k=wrong HTTP/1.1"), TOKEN, provider)
check("wrong token → 403", r.status:find("^403") ~= nil)
r = Relay.route(req("GET /manual?k=abc123 HTTP/1.1"), "", provider)
check("empty configured token refuses everything", r.status:find("^403") ~= nil)

print("== manual and refresh")
r = Relay.route(req("GET /manual?k=abc123 HTTP/1.1"), TOKEN, provider)
check("manual JSON", r.status:find("^200") ~= nil and r.body:find('"home_name"', 1, true) ~= nil)
r = Relay.route(req("POST /manual?k=abc123 HTTP/1.1"), TOKEN, provider)
check("POST /manual → 405", r.status:find("^405") ~= nil)
r = Relay.route(req("GET /manual?k=abc123 HTTP/1.1"), TOKEN, {
  manual = function()
    error("boom")
  end,
})
check("manual failure → 503, never a crash", r.status:find("^503") ~= nil)
r = Relay.route(req("POST /refresh?k=abc123 HTTP/1.1"), TOKEN, provider)
check("refresh runs the provider", r.status:find("^200") ~= nil and refreshed == 1)
r = Relay.route(req("GET /refresh?k=abc123 HTTP/1.1"), TOKEN, provider)
check("GET /refresh → 405", r.status:find("^405") ~= nil)
r = Relay.route(req("GET /nothing?k=abc123 HTTP/1.1"), TOKEN, provider)
check("unknown → 404", r.status:find("^404") ~= nil)
r = Relay.route(Relay.parse("garbage\r\n\r\n"), TOKEN, provider)
check("malformed → 400", r.status:find("^400") ~= nil)
check("incomplete request parses to nil", Relay.parse("GET /ping HTTP/1.1\r\n") == nil)

print("== render")
local bytes = Relay.render(Relay.route(req("GET /ping HTTP/1.1"), TOKEN, provider))
check(
  "HTTP/1.1 status line and CORS",
  bytes:find("^HTTP/1.1 200 OK") ~= nil and bytes:find("Access%-Control%-Allow%-Origin: %*") ~= nil
)
check("content length matches body", bytes:find("Content%-Length: " .. #'{"ok":true,"service":"home-guide"}') ~= nil)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
