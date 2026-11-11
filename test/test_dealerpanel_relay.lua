package.path = "src/?.lua;" .. package.path
local R = require("dealerpanel.relay")
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

-- A tiny JSON for the provider (string keys, flat values are all we need).
local function enc(t)
  local parts = {}
  for k, v in pairs(t) do
    local val
    if type(v) == "string" then
      val = '"' .. v .. '"'
    elseif type(v) == "table" then
      val = enc(v)
    else
      val = tostring(v)
    end
    parts[#parts + 1] = '"' .. tostring(k) .. '":' .. val
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end
local function dec(s)
  if tostring(s):sub(1, 1) ~= "{" then
    error("not JSON")
  end
  local t = {}
  for k, v in tostring(s):gmatch('"([%w_]+)"%s*:%s*"([^"]*)"') do
    t[k] = v
  end
  for k, v in tostring(s):gmatch('"([%w_]+)"%s*:%s*(%d+)') do
    t[k] = tonumber(v)
  end
  return t
end

print("== gate")
local clock = { t = 1000 }
local locked = 0
local gate = R.newGate({
  now = function()
    return clock.t
  end,
  max_attempts = 3,
  lock_seconds = 60,
  onLocked = function()
    locked = locked + 1
  end,
})
check("no PIN configured → pin_not_configured", select(2, gate:check("", "1234")) == "pin_not_configured")
check("correct PIN ok", gate:check("1234", "1234") == true)
check("wrong PIN", select(2, gate:check("1234", "0000")) == "wrong_pin")
gate:check("1234", "0000")
check("third wrong locks", select(2, gate:check("1234", "0000")) == "locked" and locked == 1 and gate:isLocked())
check("correct PIN refused while locked", select(2, gate:check("1234", "1234")) == "locked")
check("seconds left", gate:secondsLeft() == 60)
clock.t = clock.t + 61
check("lock expires", gate:isLocked() == false and gate:check("1234", "1234") == true)
gate:check("1234", "x")
gate:check("1234", "1234")
gate:check("1234", "x")
gate:check("1234", "x")
check("a correct PIN resets the failure count", gate:isLocked() == false)
gate:check("1234", "x")
check("…so the third consecutive wrong one locks", gate:isLocked() == true and locked == 2)
gate:reset()
check("reset clears the lock", gate:isLocked() == false and gate:secondsLeft() == 0)

print("== route")
local setCalls = {}
local provider = {
  appHtml = function()
    return "<html>app</html>"
  end,
  state = function()
    return '{"settings":[],"configured":0}'
  end,
  verify = function(pin)
    return gate:check("1234", pin)
  end,
  set = function(name, value, pin)
    local ok, reason = gate:check("1234", pin)
    if not ok then
      return { ok = false, reason = reason }
    end
    setCalls[#setCalls + 1] = { name = name, value = value }
    if value == "bad" then
      return { ok = false, reason = "invalid", detail = "not a number" }
    end
    return { ok = true, changed = true }
  end,
  encode = enc,
  decode = dec,
}
local TOKEN = "tok"
local function req(method, path, body)
  return R.parse(
    method .. " " .. path .. " HTTP/1.1\r\nContent-Length: " .. #(body or "") .. "\r\n\r\n" .. (body or "")
  )
end
local function route(method, path, body)
  return R.route(req(method, path, body), TOKEN, provider)
end
check("ping tokenless", route("GET", "/ping").status == "200 OK")
check("app tokenless", route("GET", "/app").body == "<html>app</html>")
check("OPTIONS preflight 204", route("OPTIONS", "/set").status == "204 No Content")
check("state needs token", route("GET", "/state").status == "403 Forbidden")
check("state with token", route("GET", "/state?k=tok").body:find("configured") ~= nil)
check("state POST → 405", route("POST", "/state?k=tok", "{}").status == "405 Method Not Allowed")
check("unknown path 404", route("GET", "/nope?k=tok").status == "404 Not Found")
check("set GET → 405", route("GET", "/set?k=tok").status == "405 Method Not Allowed")
check(
  "set with junk body → 400",
  route("POST", "/set?k=tok", "not json").status == "400 Bad Request"
    or route("POST", "/set?k=tok", "").status == "400 Bad Request"
)
local r = route("POST", "/verify?k=tok", '{"pin":"1234"}')
check("verify ok", r.status == "200 OK" and r.body:find('"ok":true') ~= nil)
r = route("POST", "/verify?k=tok", '{"pin":"9"}')
check("verify wrong → 403 with reason", r.status == "403 Forbidden" and r.body:find("wrong_pin") ~= nil)
r = route("POST", "/set?k=tok", '{"name":"Hall timeout","value":"200","pin":"1234"}')
check("set ok", r.status == "200 OK" and setCalls[1].name == "Hall timeout" and setCalls[1].value == "200")
r = route("POST", "/set?k=tok", '{"slot":"2","value":"bad","pin":"1234"}')
check("set invalid value → 422", r.status == "422 Unprocessable Entity" and r.body:find("not a number") ~= nil)
r = route("POST", "/set?k=tok", '{"name":"x","value":"1","pin":"0"}')
check("set wrong PIN → 403, no write", r.status == "403 Forbidden" and #setCalls == 2)
check(
  "malformed request line → 400",
  R.route(R.parse("GARBAGE\r\n\r\n"), TOKEN, provider).status == "400 Bad Request"
)
local rendered = R.render(route("GET", "/ping"))
check(
  "render carries CORS and length",
  rendered:find("Access%-Control%-Allow%-Origin: %*") ~= nil and rendered:find("Content%-Length: ") ~= nil
)
check("chunked body waits", R.parse('POST /set HTTP/1.1\r\nContent-Length: 10\r\n\r\n{"a"') == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
