-- Variable Inspector DRIVER under the shim: licensing registration, the LAN
-- relay (device list / open / watch / unwatch / set with and without PIN),
-- live changes → history + event + LAST_CHANGE, listeners released when a
-- device is closed, Print actions, persistence across a reload, enforcement
-- making the page read-only.
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

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")

-- ── timers ──────────────────────────────────────────────────────────────────
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    clock.timers[id] = nil
  end
  function KillAllTimers()
    clock.timers = {}
  end
  return true
end
local function advance(ms)
  local target = clock.now + ms
  while true do
    local bestId, bestAt
    for id, t in pairs(clock.timers) do
      if t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and id < bestId)) then
        bestId, bestAt = id, t.at
      end
    end
    if not bestId then
      break
    end
    clock.now = bestAt
    local t = clock.timers[bestId]
    if t.every then
      t.at = clock.now + t.every
    else
      clock.timers[bestId] = nil
    end
    t.cb()
  end
  clock.now = target
end
local realTime = os.time
local base = 1800000000
os.time = function(t)
  if t then
    return realTime(t)
  end
  return base + math.floor(clock.now / 1000)
end
local realDate = os.date
os.date = function(fmt, t)
  return realDate(fmt, t or os.time())
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end

-- ── persist (in memory) ─────────────────────────────────────────────────────
local persisted = {}
package.preload["lib.persist"] = function()
  local P = {}
  local EMPTY = {}
  function P:get(key, default)
    if default == nil then
      default = EMPTY
    end
    if persisted[key] == nil then
      return default
    end
    return persisted[key]
  end
  function P:set(key, value)
    persisted[key] = value
  end
  function P:delete(key)
    persisted[key] = nil
  end
  function P:reset() end
  return P
end

-- ── fake Director ───────────────────────────────────────────────────────────
local AGENT_ID = 50
local SELF_ID = 12345
local sent, fired, proxySends, serverSent = {}, {}, {}, {}
local listeners, regCalls, unregCalls = {}, 0, 0
local setCalls = {}
local props, vars = {}, {}
local serverCreated = nil
local devices = {
  [12] = { deviceName = "Kitchen Pendants", driverFileName = "light.c4z", roomId = 3, roomName = "Kitchen" },
  [20] = { deviceName = "Front Lock", driverFileName = "lock.c4z", roomId = 1, roomName = "Entry" },
  [7] = { deviceName = "Controller", driverFileName = "control4_core3.c4i", roomId = 9, roomName = "Rack" },
  [AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
  [SELF_ID] = { deviceName = "Variable Inspector", driverFileName = "smartbuildos-variable-inspector.c4z" },
}
local variables = {
  [12] = { ["1001"] = { name = "LIGHT_LEVEL", value = "75" }, ["1002"] = { name = "LIGHT_STATE", value = "True" } },
  [20] = { ["2001"] = { name = "LockStatus", value = "Locked" }, ["2002"] = { name = "USER_CODE_1", value = "1234" } },
}
C4.GetDevices = function()
  return devices
end
C4.GetDeviceVariables = function(_, id)
  return variables[tonumber(id)]
end
C4.GetDeviceDisplayName = function(_, id)
  local d = devices[tonumber(id)]
  return d and d.deviceName or nil
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "Variable Inspector"
  end
  return "20261109.000000"
end
C4.SendToDevice = function(_, device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
end
C4.SendToProxy = function(_, binding, command, params)
  proxySends[#proxySends + 1] = { binding = binding, command = command, params = params }
end
C4.FireEventByID = function(_, id)
  fired[#fired + 1] = id
end
C4.FireEvent = function() end
C4.RegisterVariableListener = function(_, d, v)
  regCalls = regCalls + 1
  listeners[d .. ":" .. v] = true
end
C4.UnregisterVariableListener = function(_, d, v)
  unregCalls = unregCalls + 1
  listeners[d .. ":" .. v] = nil
end
C4.SetDeviceVariable = function(_, d, v, value)
  setCalls[#setCalls + 1] = { d, v, value }
  variables[d][tostring(v)].value = value
end
C4.SetVariable = function(_, name, value)
  vars[name] = value
end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.UpdateProperty = function(_, name, value)
  props[name] = value
  Properties[name] = value
end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end
C4.GetNetworkBindingsByDevice = function()
  return { bindings = { { addr = "192.168.7.20" } } }
end
C4.CreateServer = function(_, port, _, _, identifier)
  serverCreated = { port = port, identifier = identifier }
  return true
end
C4.ServerSend = function(_, handle, data)
  serverSent[#serverSent + 1] = { handle = handle, data = data }
end
C4.ServerCloseClient = function() end
C4.DestroyServer = function() end
local FAKE_APP = "<!DOCTYPE html><html><body>" .. string.rep("inspector ", 80) .. "</body></html>"
C4.FileExists = function()
  return true
end
C4.FileOpen = function()
  return 7
end
C4.FileGetSize = function()
  return #FAKE_APP
end
C4.FileRead = function(_, handle)
  return handle == 7 and FAKE_APP or ""
end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-variable-inspector/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    Properties[name] = default
  end
end

-- The relay's own address check (lib.relayhost): a candidate address is
-- published only once THIS relay has answered /ping on it. Here the relay
-- answers on the controller's address and nowhere else.
RELAY_ANSWERS_ON = { ["192.168.7.20"] = true }
RELAY_PINGS = {}
require("lib.relayhost").get = function(url, done)
  RELAY_PINGS[#RELAY_PINGS + 1] = url
  local host = url:match("^http://([%d%.]+):")
  if RELAY_ANSWERS_ON[host] then
    done(true, '{"ok":true,"service":"variable-inspector"}')
  else
    done(false)
  end
end

dofile("drivers/smartbuildos-variable-inspector/driver.lua")

local function prop(name)
  return props[name] or Properties[name]
end
local function lastSent(command)
  local out = nil
  for _, s in ipairs(sent) do
    if s.command == command then
      out = s
    end
  end
  return out
end
local function hasFired(id)
  for _, f in ipairs(fired) do
    if f == id then
      return true
    end
  end
  return false
end
local function countSubs()
  local n = 0
  for _ in pairs(listeners) do
    n = n + 1
  end
  return n
end
local function lastUrl()
  local u = nil
  for _, p in ipairs(proxySends) do
    if p.command == "URL_CHANGED" then
      u = p.params.url
    end
  end
  return u
end
local handleSeq = 100
local function http(method, pathAndQuery, body)
  body = body or ""
  handleSeq = handleSeq + 1
  local before = #serverSent
  local req = method .. " " .. pathAndQuery .. " HTTP/1.1\r\nHost: x\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
  -- deliver in two chunks to exercise reassembly
  local cut = math.floor(#req / 2)
  OnServerDataIn(handleSeq, req:sub(1, cut), nil, nil, "varinspector-ui-relay")
  OnServerDataIn(handleSeq, req:sub(cut + 1), nil, nil, "varinspector-ui-relay")
  local raw = serverSent[#serverSent] and serverSent[#serverSent].data or ""
  if #serverSent == before then
    return nil, nil
  end
  local status = raw:match("^HTTP/1%.1 (%d+)")
  local payload = raw:match("\r\n\r\n(.*)$") or ""
  local ok, decoded = pcall(function()
    return JSON:decode(payload)
  end)
  return tonumber(status), ok and decoded or payload
end

print("[1] start: licence registration, relay listening, URL published")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", props["Driver Status"] == "Online")
check(
  "licence registered under the inspector SKU",
  lastSent("SBOS_REGISTER_DRIVER") ~= nil and lastSent("SBOS_REGISTER_DRIVER").params.sku == "SBOS_VARIABLE_INSPECTOR"
)
check(
  "relay listening on 47823",
  serverCreated ~= nil
    and serverCreated.port == 47823
    and prop("App Data Relay") == "Listening :47823 - serving http://192.168.7.20:47823 to the app",
  prop("App Data Relay")
)
local url = lastUrl()
check(
  "same-origin app URL with token published",
  url ~= nil and url:find("^http://192%.168%.7%.20:47823/app%?k=%w+$") ~= nil,
  url
)
local TOKEN = url:match("k=(%w+)$")
check(
  "read-only without a Dealer PIN",
  prop("Inspector Mode"):find("read%-only") ~= nil and TC.INSPECTOR_READ_ONLY() == true,
  prop("Inspector Mode")
)
check("no listeners yet", countSubs() == 0)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_VARIABLE_INSPECTOR",
  status = "AUTHORIZED_SUBSCRIPTION",
  registered = "true",
  subscription_tier = "Professional",
  company_name = "Skynet AV",
})
check("licence painted", prop("License Status"):find("Licensed") ~= nil and prop("Subscription Tier") == "Professional")

print("[2] relay: tokenless and token-walled routes")
local status, body = http("GET", "/ping")
check("ping", status == 200 and body.service == "variable-inspector")
status, body = http("GET", "/app")
check("app served from the c4z", status == 200 and tostring(body):find("inspector") ~= nil)
status = http("GET", "/devices")
check("devices without token 403", status == 403)
status, body = http("GET", "/devices?k=" .. TOKEN)
check(
  "device list excludes self, includes rooms",
  status == 200 and #body.devices == 4 and body.devices[#body.devices].room == "Rack"
)
status, body = http("GET", "/devices?k=" .. TOKEN .. "&q=lock")
check("filter", status == 200 and #body.devices == 1 and body.devices[1].id == 20)

print("[3] open a device: live variables, masking, listeners")
status, body = http("GET", "/device?k=" .. TOKEN .. "&id=20")
check(
  "open lock → 2 variables, credential masked",
  status == 200
    and #body.variables == 2
    and body.variables[2].name == "USER_CODE_1"
    and body.variables[2].masked == true
    and body.variables[2].value ~= "1234"
)
check(
  "listener only for the unmasked variable",
  listeners["20:2001"] and listeners["20:2002"] == nil and countSubs() == 1
)
OnWatchedVariableChanged(20, 2001, "Unlocked")
status, body = http("GET", "/state?k=" .. TOKEN)
check(
  "state shows the live value on the open device",
  status == 200 and body.open_device == 20 and body.open_variables[1].value == "Unlocked"
)
check("no Composer event for an unwatched change", not hasFired(1))
status, body = http("GET", "/device?k=" .. TOKEN .. "&id=12")
check(
  "opening another device releases the first",
  listeners["20:2001"] == nil and listeners["12:1001"] and listeners["12:1002"] and countSubs() == 2
)
status, body = http("GET", "/device?k=" .. TOKEN .. "&id=999")
check("unknown device 404", status == 404)

print("[4] writes are refused while read-only (no Dealer PIN)")
status, body = http("POST", "/watch?k=" .. TOKEN, '{"device_id":12,"variable_id":1001}')
check("watch refused read-only", status == 422 and body.reason:find("read%-only") ~= nil, body and body.reason)
status, body = http("POST", "/set?k=" .. TOKEN, '{"device_id":12,"variable_id":1001,"value":"10","pin":""}')
check("set refused read-only", status == 422 and #setCalls == 0)
check("Set Refused event fired", hasFired(3))

print("[5] with a Dealer PIN: watch, change, history, event, LAST_CHANGE")
Properties["Dealer PIN"] = "4321"
OnPropertyChanged("Dealer PIN")
check("writable now", prop("Inspector Mode"):find("writable") ~= nil and TC.INSPECTOR_READ_ONLY() == false)
status, body = http("POST", "/watch?k=" .. TOKEN, '{"device_id":12,"variable_id":1001}')
check("watch accepted", status == 200 and body.ok == true)
check("watch persisted", persisted["vi_watches_v1"] ~= nil and persisted["vi_watches_v1"][1].name == "LIGHT_LEVEL")
status, body = http("POST", "/watch?k=" .. TOKEN, '{"device_id":20,"variable_id":2002}')
check("masked variable cannot be watched", status == 422 and body.reason:find("never watched") ~= nil)
fired = {}
clock.now = clock.now + 5000
OnWatchedVariableChanged(12, 1001, "40")
advance(2500)
check("Watched Variable Changed fired", hasFired(1))
check(
  "LAST_CHANGE variables",
  vars["LAST_CHANGE"] == "Kitchen Pendants: LIGHT_LEVEL = 40"
    and vars["LAST_CHANGE_DEVICE"] == 12
    and vars["LAST_CHANGE_VALUE"] == "40",
  vars["LAST_CHANGE"]
)
check(
  "Last Change / Watched painted",
  prop("Last Change"):find("LIGHT_LEVEL = 40", 1, true) ~= nil and prop("Watched") == "1 of 64",
  prop("Watched")
)
status, body = http("GET", "/state?k=" .. TOKEN)
check(
  "history carries previous value",
  status == 200 and body.watches[1].history[1].value == 40 and body.watches[1].history[1].previous == 75
)
http("POST", "/close?k=" .. TOKEN)
check(
  "closing keeps the watched listener only",
  listeners["12:1001"] and listeners["12:1002"] == nil and countSubs() == 1
)

print("[6] set: PIN gate and the probe path")
status, body = http("POST", "/set?k=" .. TOKEN, '{"device_id":12,"variable_id":1001,"value":"55","pin":"0000"}')
check("wrong PIN refused", status == 422 and body.detail:find("PIN") ~= nil and #setCalls == 0)
status, body = http("POST", "/set?k=" .. TOKEN, '{"device_id":12,"variable_id":1001,"value":"55","pin":"4321"}')
check(
  "right PIN → SetDeviceVariable called with text",
  status == 200 and #setCalls == 1 and setCalls[1][1] == 12 and setCalls[1][2] == 1001 and setCalls[1][3] == "55"
)
check("result says verify on read", body.detail:find("verify") ~= nil)
check("Value Set From Page fired", hasFired(2))
status, body = http("POST", "/set?k=" .. TOKEN, '{"device_id":20,"variable_id":2002,"value":"9999","pin":"4321"}')
check("credential-named never written", status == 422 and body.detail:find("never written") ~= nil and #setCalls == 1)
check("PIN never echoed", serverSent[#serverSent].data:find("4321") == nil)

print("[7] Composer programming commands and print actions")
EC.WATCH_VARIABLE({ DEVICE = "20", VARIABLE = "lockstatus" })
check(
  "Watch Variable by name (case-insensitive)",
  listeners["20:2001"] and countSubs() == 2 and prop("Watched") == "2 of 64"
)
EC.WATCH_VARIABLE({ DEVICE = "20", VARIABLE = "NOPE" })
check("unknown name named in Last Error", prop("Last Error"):find("no variable named NOPE") ~= nil, prop("Last Error"))
EC.UNWATCH_VARIABLE({ DEVICE = "20", VARIABLE = "LockStatus" })
check("Unwatch Variable releases it", listeners["20:2001"] == nil and countSubs() == 1)
Properties["Inspect Device ID"] = "12"
local okP = pcall(function()
  EC.PRINT_DEVICE()
  EC.PRINT_WATCHES()
  EC.REFRESH_STATUS()
  EC.REPUBLISH_URL()
  Properties["Inspect Device ID"] = ""
  EC.PRINT_DEVICE()
end)
check("print actions run", okP)
EC.CLEAR_HISTORY()
status, body = http("GET", "/state?k=" .. TOKEN)
check("history cleared", #body.watches[1].history == 0)

print("[8] licence enforcement makes the inspector read-only; uncertainty does not")
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_VARIABLE_INSPECTOR",
  status = "CLOUD_VALIDATION_REQUIRED",
  registered = "true",
  enforcement = "enforce",
})
check("uncertain status: still writable", TC.INSPECTOR_READ_ONLY() == false)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_VARIABLE_INSPECTOR",
  status = "NOT_ENTITLED",
  registered = "true",
  enforcement = "enforce",
})
check(
  "definitive denial + enforce → read-only",
  TC.INSPECTOR_READ_ONLY() == true and prop("Inspector Mode"):find("licence") ~= nil,
  prop("Inspector Mode")
)
status, body = http("POST", "/set?k=" .. TOKEN, '{"device_id":12,"variable_id":1001,"value":"1","pin":"4321"}')
check("set refused under enforcement even with the PIN", status == 422 and #setCalls == 1)
status, body = http("GET", "/device?k=" .. TOKEN .. "&id=12")
check("reading still works", status == 200 and #body.variables == 2)
check("watched listener kept", listeners["12:1001"])
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_VARIABLE_INSPECTOR",
  status = "NOT_ENTITLED",
  registered = "true",
  enforcement = "observe",
})
check("observe mode → writable again", TC.INSPECTOR_READ_ONLY() == false)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_VARIABLE_INSPECTOR", status = "AUTHORIZED_SUBSCRIPTION", registered = "true" })

print("[9] reload: watch list restored, listeners rebuilt, token stable")
OnDriverDestroyed()
check("destroy released every listener", countSubs() == 0)
listeners = {}
proxySends = {}
OnDriverInit()
OnDriverLateInit("DIT_UPDATING")
check("watch restored and listening", listeners["12:1001"] and countSubs() == 1 and prop("Watched") == "1 of 64")
check("same token after reload", lastUrl():match("k=(%w+)$") == TOKEN)
status, body = http("GET", "/state?k=" .. TOKEN)
check("state after reload", status == 200 and body.watches[1].name == "LIGHT_LEVEL")

print("[10] relay address override and controller:// fallback")
Properties["App Relay Address"] = "10.0.0.5"
OnPropertyChanged("App Relay Address")
check("override changes the published URL", lastUrl():find("^http://10%.0%.0%.5:47823/app") ~= nil, lastUrl())
local savedBindings = C4.GetNetworkBindingsByDevice
C4.GetNetworkBindingsByDevice = function()
  return {}
end
Properties["App Relay Address"] = "Auto"
OnPropertyChanged("App Relay Address")
check(
  "no address known → controller:// page without a relay pointer",
  lastUrl() == "controller://driver/smartbuildos-variable-inspector/app/index.html",
  lastUrl()
)
C4.GetNetworkBindingsByDevice = savedBindings

print("[11] relay robustness")
local before = #serverSent
OnServerDataIn(555, string.rep("A", 70 * 1024), nil, nil, "varinspector-ui-relay")
check("oversized request dropped without a reply", #serverSent == before)
OnServerDataIn(556, "GET /ping HTTP/1.1\r\n\r\n", nil, nil, "some-other-server")
check("other server identifiers ignored", #serverSent == before)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
