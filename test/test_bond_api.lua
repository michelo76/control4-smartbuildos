-- Tests for src/bond/api.lua.
--
-- The client is loaded against a fake `lib.http`, so every assertion is about
-- what the client decided to send. The invariants under test:
--
--   * Address normalization: bare host → http://, https:// is DOWNGRADED to
--     http:// (the Bond serves no TLS — leaving https would fail identically
--     to a wrong address), paths/queries cut, garbage → "".
--   * The BOND-Token header rides every authenticated request and is ABSENT
--     while no token is set (version probe / token poll work tokenless).
--   * Actions: no argument sends the literal object "{}" (an empty Lua table
--     could encode as []), scalar and table arguments wrap as {argument=X}.
--   * idsFromTree lists only real child ids — every underscore-prefixed
--     reserved key ("_", "__modified") is bookkeeping, not a device.
--   * parseBpup handles the four frame shapes (ack / state update / other
--     topic / error) and returns nil for garbage, because BPUP is Beta and
--     noise must not look like failure.
--
-- Run from the driver root:
--   make test

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

-- ─── Fakes ────────────────────────────────────────────────────────────────────

--- Every request the client handed to lib.http, newest last.
local requests = {}

local function settled(isOk, value)
  return {
    next = function(_, onOk, onErr)
      if isOk then
        if onOk then
          onOk(value)
        end
      elseif onErr then
        onErr(value)
      end
    end,
  }
end

package.preload["lib.http"] = function()
  return {
    request = function(_, method, url, data, headers, options)
      table.insert(requests, { method = method, url = url, data = data, headers = headers, options = options })
      return settled(true, { url = url, code = 200, headers = {}, body = {} })
    end,
    get = function(self, url, headers, options)
      return self:request("GET", url, nil, headers, options)
    end,
    put = function(self, url, data, headers, options)
      return self:request("PUT", url, data, headers, options)
    end,
    patch = function(self, url, data, headers, options)
      return self:request("PATCH", url, data, headers, options)
    end,
  }
end

JSON = require("JSON")

local Bond = require("bond.api")

local function lastRequest()
  return requests[#requests]
end

-- ─── normalizeAddress ─────────────────────────────────────────────────────────

print("normalizeAddress")
check("bare host gains http://", Bond.normalizeAddress("192.168.1.50") == "http://192.168.1.50")
check("host with port kept", Bond.normalizeAddress("192.168.1.50:8080") == "http://192.168.1.50:8080")
check("https downgraded to http", Bond.normalizeAddress("https://192.168.1.50") == "http://192.168.1.50")
check("path cut", Bond.normalizeAddress("http://192.168.1.50/v2/devices") == "http://192.168.1.50")
check("whitespace trimmed", Bond.normalizeAddress("  bond-zzbl12345.local  ") == "http://bond-zzbl12345.local")
check("empty → empty", Bond.normalizeAddress("") == "")
check("nil → empty", Bond.normalizeAddress(nil) == "")
check("scheme only → empty", Bond.normalizeAddress("http://") == "")

-- ─── configuration + headers ──────────────────────────────────────────────────

print("configuration")
local bond = Bond:new()
check("unconfigured has no address", bond:hasAddress() == false)
check("unconfigured is not configured", bond:isConfigured() == false)

bond:configure("192.168.1.50", nil)
check("address alone: hasAddress", bond:hasAddress() == true)
check("address alone: not configured", bond:isConfigured() == false)

requests = {}
bond:getVersion()
local r = lastRequest()
check("version probe hits /v2/sys/version", r.url == "http://192.168.1.50/v2/sys/version")
check("no token → no BOND-Token header", r.headers["BOND-Token"] == nil)

bond:configure("192.168.1.50", "deadbeef01")
check("address + token: configured", bond:isConfigured() == true)

requests = {}
bond:getDevices()
r = lastRequest()
check("devices hits /v2/devices", r.url == "http://192.168.1.50/v2/devices")
check("token rides as BOND-Token", r.headers["BOND-Token"] == "deadbeef01")
check("timeout below lib default", type(r.options) == "table" and r.options.timeout == 10)

requests = {}
bond:getDevice("aabbccdd")
check("device info path", lastRequest().url == "http://192.168.1.50/v2/devices/aabbccdd")
bond:getDeviceState("aabbccdd")
check("state path", lastRequest().url == "http://192.168.1.50/v2/devices/aabbccdd/state")
bond:getDeviceProperties("aabbccdd")
check("properties path", lastRequest().url == "http://192.168.1.50/v2/devices/aabbccdd/properties")
bond:getToken()
check("token path", lastRequest().url == "http://192.168.1.50/v2/token")

-- ─── actions ──────────────────────────────────────────────────────────────────

print("actions")
requests = {}
bond:action("aabbccdd", "TurnOn")
r = lastRequest()
check("action is a PUT", r.method == "PUT")
check("action path", r.url == "http://192.168.1.50/v2/devices/aabbccdd/actions/TurnOn")
check("no argument sends literal {}", r.data == "{}")
check("literal body carries Content-Type", r.headers["Content-Type"] == "application/json")

requests = {}
bond:action("aabbccdd", "SetSpeed", 3)
r = lastRequest()
check("scalar argument wraps", type(r.data) == "table" and r.data.argument == 3)

requests = {}
bond:action("aabbccdd", "SetBreeze", { 1, 20, 90 })
r = lastRequest()
check(
  "table argument passes through",
  type(r.data) == "table" and type(r.data.argument) == "table" and r.data.argument[3] == 90
)

-- ─── scenes + token ───────────────────────────────────────────────────────────

print("scenes and token")
requests = {}
bond:getScenes()
check("scenes path", lastRequest().url == "http://192.168.1.50/v2/scenes")
bond:getScene("scene1")
check("scene path", lastRequest().url == "http://192.168.1.50/v2/scenes/scene1")
bond:runScene("scene1")
r = lastRequest()
check("run scene is a PUT", r.method == "PUT")
check("run scene path", r.url == "http://192.168.1.50/v2/scenes/scene1/run")
check("run scene sends literal {}", r.data == "{}")

requests = {}
bond:patchToken(0, "1234")
r = lastRequest()
check("token unlock is a PATCH", r.method == "PATCH")
check("token unlock path", r.url == "http://192.168.1.50/v2/token")
check("unlock body carries locked=0 + pin", type(r.data) == "table" and r.data.locked == 0 and r.data.pin == "1234")
bond:patchToken(1)
r = lastRequest()
check("relock body carries locked=1, no pin", type(r.data) == "table" and r.data.locked == 1 and r.data.pin == nil)

-- ─── sidekicks ────────────────────────────────────────────────────────────────

print("sidekicks")
requests = {}
bond:getSidekicks()
check("sidekicks path", lastRequest().url == "http://192.168.1.50/v2/sidekicks")
bond:getSidekick("sk1")
check("sidekick path", lastRequest().url == "http://192.168.1.50/v2/sidekicks/sk1")
bond:getSidekickState("ws1")
check("weather state path", lastRequest().url == "http://192.168.1.50/v2/sidekicks/ws1/state")
bond:openSidekickLearn()
r = lastRequest()
check("learn is a PATCH", r.method == "PATCH")
check("learn path", r.url == "http://192.168.1.50/v2/sidekicks/_learn")
check("learn window defaults to 60s", type(r.data) == "table" and r.data.learn_window_ms == 60000)

-- ─── idsFromTree ──────────────────────────────────────────────────────────────

print("idsFromTree")
local ids = Bond.idsFromTree({
  ["_"] = "7fdf7e66",
  ["__modified"] = 1642788966,
  ["aabbccdd"] = { ["_"] = "9a5211cc" },
  ["11223344"] = { ["_"] = "016e6b34" },
})
check("two ids found", #ids == 2)
check("sorted deterministically", ids[1] == "11223344" and ids[2] == "aabbccdd")
check("nil tree → empty list", #Bond.idsFromTree(nil) == 0)
check("string tree → empty list", #Bond.idsFromTree("nope") == 0)

-- ─── parseBpup ────────────────────────────────────────────────────────────────

print("parseBpup")
local frame = Bond.parseBpup('{"B":"ZZBL12345"}\n')
check("ack frame recognized", frame ~= nil and frame.ack == true and frame.bondId == "ZZBL12345")

frame = Bond.parseBpup(
  '{"B":"ZZBL12345","t":"devices/aabbccdd/state","i":"00112233bbeeeeff","s":200,"m":0,"f":255,'
    .. '"b":{"_":"ab9284ef","power":1,"speed":2}}\n'
)
check("state frame: device id from topic", frame ~= nil and frame.deviceId == "aabbccdd")
check("state frame: body is the state doc", frame ~= nil and frame.state ~= nil and frame.state.speed == 2)
check("state frame: status carried", frame ~= nil and frame.status == 200)

frame = Bond.parseBpup('{"B":"ZZBL12345","t":"groups/0000000000000002/state","s":200,"b":{"_":"x"}}\n')
check("non-device topic: not a state frame", frame ~= nil and frame.deviceId == nil)
check("non-device topic: topic passed through", frame ~= nil and frame.topic == "groups/0000000000000002/state")

frame = Bond.parseBpup('{"B":"ZZBL12345","err_id":631,"err_msg":"BPUP client timeout"}\n')
check("error frame recognized", frame ~= nil and frame.error ~= nil and frame.error.id == 631)

check("garbage → nil", Bond.parseBpup("not json\n") == nil)
check("empty → nil", Bond.parseBpup("") == nil)
check("nil → nil", Bond.parseBpup(nil) == nil)
check("bare newline → nil", Bond.parseBpup("\n") == nil)

-- Two datagrams can arrive coalesced; the parser reads the FIRST line only —
-- splitting is the socket handler's job, and this pins that contract.
frame = Bond.parseBpup('{"B":"ZZBL12345"}\n{"B":"OTHER"}\n')
check("coalesced datagrams: first line wins", frame ~= nil and frame.bondId == "ZZBL12345")

-- ─── decodeBody ───────────────────────────────────────────────────────────────

print("decodeBody")
check("table passes through", Bond.decodeBody({ a = 1 }).a == 1)
check("json string decodes", Bond.decodeBody('{"a":1}').a == 1)
check("non-json string → nil", Bond.decodeBody("<html>") == nil)
check("empty string → nil", Bond.decodeBody("") == nil)
check("nil → nil", Bond.decodeBody(nil) == nil)

-- ─── Summary ──────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
