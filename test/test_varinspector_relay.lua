package.path = "src/?.lua;" .. package.path
require("drivers-common-public.global.lib")
local JSON = require("JSON")
local relay = require("varinspector.relay")
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

local TOKEN = "tok123"
local calls = {}
local provider = {
  appHtml = function()
    return "<html>app</html>"
  end,
  devices = function(q)
    calls[#calls + 1] = { "devices", q }
    return { { id = 1, name = "A" } }
  end,
  openDevice = function(id)
    calls[#calls + 1] = { "open", id }
    if id == 12 then
      return { { id = 1001, name = "LIGHT_LEVEL", value = 75 } }
    end
    return nil, "no such device"
  end,
  closeDevice = function()
    calls[#calls + 1] = { "close" }
    return true
  end,
  state = function()
    return { watched = 1 }
  end,
  watch = function(d, v)
    calls[#calls + 1] = { "watch", d, v }
    return d == 12, d == 12 and "watching" or "nope"
  end,
  unwatch = function(d, v)
    calls[#calls + 1] = { "unwatch", d, v }
    return true, "released"
  end,
  set = function(d, v, value, pin)
    calls[#calls + 1] = { "set", d, v, value, pin }
    return pin == "4321", pin == "4321" and "sent" or "Dealer PIN required"
  end,
  clear = function()
    calls[#calls + 1] = { "clear" }
  end,
  encode = function(t)
    return JSON:encode(t)
  end,
  decode = function(s)
    return JSON:decode(s)
  end,
}
local function get(path)
  return relay.route(relay.parse("GET " .. path .. " HTTP/1.1\r\nHost: x\r\n\r\n"), TOKEN, provider)
end
local function post(path, body)
  body = body or ""
  return relay.route(
    relay.parse("POST " .. path .. " HTTP/1.1\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body),
    TOKEN,
    provider
  )
end
local function body(r)
  return JSON:decode(r.body)
end

print("== tokenless routes")
check("ping", get("/ping").status == "200 OK" and body(get("/ping")).service == "variable-inspector")
check("app served as html", get("/app").contentType:find("text/html") ~= nil and get("/app").body == "<html>app</html>")
check(
  "options preflight 204",
  relay.route(relay.parse("OPTIONS /set HTTP/1.1\r\n\r\n"), TOKEN, provider).status == "204 No Content"
)
check("malformed 400", relay.route(relay.parse("garbage\r\n\r\n"), TOKEN, provider).status == "400 Bad Request")

print("== token wall")
check("devices without token 403", get("/devices").status == "403 Forbidden")
check("wrong token 403", get("/devices?k=nope").status == "403 Forbidden")
check(
  "empty token configured → 403",
  relay.route(relay.parse("GET /devices?k= HTTP/1.1\r\n\r\n"), "", provider).status == "403 Forbidden"
)

print("== reads")
local r = get("/devices?k=" .. TOKEN .. "&q=kit")
check("devices with filter", r.status == "200 OK" and body(r).devices[1].name == "A" and calls[#calls][2] == "kit")
r = get("/device?k=" .. TOKEN .. "&id=12")
check(
  "device open returns variables",
  r.status == "200 OK" and body(r).device_id == 12 and body(r).variables[1].name == "LIGHT_LEVEL"
)
r = get("/device?k=" .. TOKEN .. "&id=77")
check("unknown device 404 with reason", r.status == "404 Not Found" and body(r).error == "no such device")
r = get("/state?k=" .. TOKEN)
check("state", r.status == "200 OK" and body(r).watched == 1 and body(r).ok == true)
check("GET on a POST route 405", get("/set?k=" .. TOKEN).status == "405 Method Not Allowed")
check("unknown GET 404", get("/nothing?k=" .. TOKEN).status == "404 Not Found")

print("== writes")
r = post("/watch?k=" .. TOKEN, '{"device_id":12,"variable_id":1001}')
check(
  "watch accepted",
  r.status == "200 OK" and body(r).ok == true and calls[#calls][2] == 12 and calls[#calls][3] == 1001
)
r = post("/watch?k=" .. TOKEN, '{"device_id":20,"variable_id":1}')
check("watch refused → 422 with reason", r.status == "422 Unprocessable Entity" and body(r).reason == "nope")
r = post("/unwatch?k=" .. TOKEN, '{"device_id":12,"variable_id":1001}')
check("unwatch", r.status == "200 OK" and calls[#calls][1] == "unwatch")
r = post("/set?k=" .. TOKEN, '{"device_id":12,"variable_id":1001,"value":"50","pin":"4321"}')
check(
  "set with pin",
  r.status == "200 OK" and body(r).ok == true and calls[#calls][4] == "50" and calls[#calls][5] == "4321"
)
r = post("/set?k=" .. TOKEN, '{"device_id":12,"variable_id":1001,"value":"50"}')
check("set without pin → 422", r.status == "422 Unprocessable Entity" and body(r).detail == "Dealer PIN required")
check("pin never echoed", r.body:find("4321") == nil)
r = post("/set?k=" .. TOKEN, "not json")
check("bad json body → refused, not crash", r.status == "422 Unprocessable Entity")
check("close", post("/close?k=" .. TOKEN).status == "200 OK" and calls[#calls][1] == "close")
check("clear", post("/clear?k=" .. TOKEN).status == "200 OK" and calls[#calls][1] == "clear")
check(
  "post without token 403",
  relay.route(relay.parse("POST /close HTTP/1.1\r\nContent-Length: 0\r\n\r\n"), TOKEN, provider).status
    == "403 Forbidden"
)
check("unknown POST 404", post("/nope?k=" .. TOKEN).status == "404 Not Found")

print("== chunked parse and render")
local req = "POST /watch?k=" .. TOKEN .. " HTTP/1.1\r\nContent-Length: 31\r\n\r\n" .. '{"device_id":12,"variable_id":1}'
check("incomplete body → nil", relay.parse(req:sub(1, 60)) == nil)
check("complete body parses", relay.parse(req) ~= nil and relay.parse(req).body:find("variable_id") ~= nil)
local rendered = relay.render(get("/ping"))
check(
  "render has content-length and CORS",
  rendered:find("Content%-Length: %d+") ~= nil and rendered:find("Access%-Control%-Allow%-Origin: %*") ~= nil
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
