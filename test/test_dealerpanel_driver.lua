-- Dealer Settings DRIVER under the shim with a scripted Agent: licensing
-- registration, properties → variables, Set/Toggle Setting commands, the
-- conditional, the relay (app, state, verify, set with/without PIN, lock),
-- Composer properties updated after a web write (one truth), Composer edits
-- rebuilding the model, enforcement refusing writes, removal.
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
local SELF_ID = 777
local sent = {}
local fired = {}
local props = {}
local vars = {}
local proxySends = {}
local serverCreated = nil
local serverSent = {}
local FAKE_APP_HTML = "<title>Dealer Settings</title>" .. string.rep("<!-- app -->", 120)
C4.GetDevices = function()
  return {
    [AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
    [12] = { deviceName = "Controller", driverFileName = "control4_core3.c4i" },
  }
end
C4.GetNetworkBindingsByDevice = function()
  return {}
end
C4.GetBindingsByDevice = function()
  return { bindings = { { bindingid = 6001, info = { addr = "192.168.7.20" } } } }
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "Dealer Settings"
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
C4.FileSetDir = function() end
C4.FileExists = function(_, path)
  return path == "www/app/index.html"
end
C4.FileOpen = function(_, path)
  return path == "www/app/index.html" and 7 or -1
end
C4.FileGetSize = function(_, handle)
  return handle == 7 and #FAKE_APP_HTML or 0
end
C4.FileSetPos = function() end
C4.FileRead = function(_, handle)
  return handle == 7 and FAKE_APP_HTML or ""
end
C4.FileClose = function() end
C4.CreateServer = function(_, port, _, _, identifier)
  serverCreated = { port = port, identifier = identifier }
  return true
end
C4.ServerSend = function(_, handle, data)
  serverSent[#serverSent + 1] = { handle = handle, data = data }
end
C4.ServerCloseClient = function() end
C4.DestroyServer = function() end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-dealer-panel/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    Properties[name] = default
  end
end
Properties["Setting 1 Name"] = "Hall timeout"
Properties["Setting 1 Type"] = "Number"
Properties["Setting 1 Value"] = "120"
Properties["Setting 1 Options"] = "0..600"
Properties["Setting 2 Name"] = "Night mode"
Properties["Setting 2 Type"] = "Toggle"
Properties["Setting 2 Value"] = "Off"
Properties["Setting 3 Name"] = "Scene"
Properties["Setting 3 Type"] = "Choice"
Properties["Setting 3 Value"] = "Dim"
Properties["Setting 3 Options"] = "Dim, Bright"

dofile("drivers/smartbuildos-dealer-panel/driver.lua")

local function prop(name)
  return props[name] or Properties[name]
end
local function sentOf(command)
  local out = {}
  for _, s in ipairs(sent) do
    if s.command == command then
      out[#out + 1] = s
    end
  end
  return out
end
local function countFired(id)
  local n = 0
  for _, f in ipairs(fired) do
    if f == id then
      n = n + 1
    end
  end
  return n
end
local function lastServer()
  return serverSent[#serverSent] and serverSent[#serverSent].data or ""
end
local function relayToken()
  local url = proxySends[#proxySends] and proxySends[#proxySends].params.url or ""
  return url:match("[?&]k=(%w+)") or ""
end
local function relay(method, path, body)
  serverSent = {}
  body = body or ""
  OnServerDataIn(
    #serverSent + 100,
    method .. " " .. path .. " HTTP/1.1\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body,
    nil,
    nil,
    "dealerpanel-ui-relay"
  )
  return lastServer()
end

print("[1] start: licence registered, variables painted, relay up, URL published")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", props["Driver Status"] == "Online")
check(
  "licence registration to the Agent under the SKU",
  #sentOf("SBOS_REGISTER_DRIVER") == 1
    and sentOf("SBOS_REGISTER_DRIVER")[1].params.sku == "SBOS_DEALER_PANEL"
    and sentOf("SBOS_REGISTER_DRIVER")[1].device == AGENT_ID
)
check(
  "SETTING_1 variables",
  vars["SETTING_1"] == "120" and vars["SETTING_1_NUMBER"] == 120 and vars["SETTING_1_NAME"] == "Hall timeout"
)
check("SETTING_2 toggle variables", vars["SETTING_2"] == "Off" and vars["SETTING_2_NUMBER"] == 0)
check("SETTING_3 choice", vars["SETTING_3"] == "Dim")
check("unused slots blank", vars["SETTING_4"] == "" and vars["SETTING_4_NAME"] == "")
check("configured count", vars["SETTINGS_CONFIGURED"] == 3)
check(
  "relay listening on 47822",
  serverCreated ~= nil and serverCreated.port == 47822 and serverCreated.identifier == "dealerpanel-ui-relay"
)
local urlSend = proxySends[#proxySends]
check(
  "web view URL is the same-origin relay app with a token",
  urlSend ~= nil
    and urlSend.command == "URL_CHANGED"
    and urlSend.params.url:find("http://192.168.7.20:47822/app?k=", 1, true) == 1,
  urlSend and urlSend.params.url
)
check("App Data Relay painted", prop("App Data Relay"):find("192.168.7.20", 1, true) ~= nil)
check("no PIN → read-only status", prop("Panel Status"):find("read%-only") ~= nil and TC.PANEL_WRITABLE() == false)

print("[2] entitlement answered: tier and company painted")
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_DEALER_PANEL",
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "subscription",
  registered = "true",
  subscription_tier = "Professional",
  company_name = "Skynet AV",
})
check(
  "licence painted",
  prop("License Status"):find("Licensed") ~= nil
    and prop("Subscription Tier") == "Professional"
    and prop("SmartBuildOS Company") == "Skynet AV"
)

print("[3] relay: app, state, writes refused without a PIN configured")
check("app served tokenless", relay("GET", "/app"):find("<title>Dealer Settings</title>", 1, true) ~= nil)
check("state refused without token", relay("GET", "/state"):find("403 Forbidden", 1, true) ~= nil)
local token = relayToken()
local stateBody = relay("GET", "/state?k=" .. token)
check(
  "state served with token, carries settings and read-only flags",
  stateBody:find('"Hall timeout"', 1, true) ~= nil
    and stateBody:find('"pin_configured":false', 1, true) ~= nil
    and stateBody:find('"writable":false', 1, true) ~= nil
)
local r = relay("POST", "/set?k=" .. token, '{"name":"Hall timeout","value":"200","pin":"1234"}')
check(
  "write refused: pin_not_configured",
  r:find("403 Forbidden", 1, true) ~= nil and r:find("pin_not_configured", 1, true) ~= nil
)
check("Setting Change Refused fired, value unchanged", countFired(2) == 1 and Properties["Setting 1 Value"] == "120")

print("[4] PIN configured: verify, set, one truth")
Properties["Dealer PIN"] = "4321"
OnPropertyChanged("Dealer PIN")
check("writable now", TC.PANEL_WRITABLE() == true and prop("Panel Status"):find("writable") ~= nil)
r = relay("POST", "/verify?k=" .. token, '{"pin":"4321"}')
check("verify ok", r:find("200 OK", 1, true) ~= nil and r:find('"ok":true', 1, true) ~= nil)
r = relay("POST", "/verify?k=" .. token, '{"pin":"0000"}')
check("verify wrong", r:find("wrong_pin", 1, true) ~= nil)
fired = {}
r = relay("POST", "/set?k=" .. token, '{"name":"Hall timeout","value":"200","pin":"4321"}')
check("web write accepted", r:find("200 OK", 1, true) ~= nil and r:find('"changed":true', 1, true) ~= nil)
check(
  "Composer property updated (one truth)",
  props["Setting 1 Value"] == "200" and Properties["Setting 1 Value"] == "200"
)
check("variables follow", vars["SETTING_1"] == "200" and vars["SETTING_1_NUMBER"] == 200)
check(
  "Setting Changed fired with name and value",
  countFired(1) == 1 and vars["CHANGED_SETTING"] == "Hall timeout" and vars["CHANGED_VALUE"] == "200"
)
check("Last Change names the source", prop("Last Change"):find("web view", 1, true) ~= nil)
fired = {}
r = relay("POST", "/set?k=" .. token, '{"name":"Hall timeout","value":"200","pin":"4321"}')
check("same value again: ok, not a change, no event", r:find('"changed":false', 1, true) ~= nil and countFired(1) == 0)
r = relay("POST", "/set?k=" .. token, '{"slot":"1","value":"900","pin":"4321"}')
check(
  "out-of-range refused 422 with detail, value kept",
  r:find("422", 1, true) ~= nil and r:find("outside", 1, true) ~= nil and Properties["Setting 1 Value"] == "200"
)
r = relay("POST", "/set?k=" .. token, '{"name":"Scene","value":"bright","pin":"4321"}')
check(
  "choice canonicalised into the property",
  Properties["Setting 3 Value"] == "Bright" and vars["SETTING_3"] == "Bright"
)
r = relay("POST", "/set?k=" .. token, '{"name":"Hall timeout","value":"150","pin":"wrong"}')
check(
  "wrong PIN on set: 403, nothing written",
  r:find("403", 1, true) ~= nil and Properties["Setting 1 Value"] == "200"
)

print("[5] programming commands and conditionals")
fired = {}
EC.SET_SETTING({ NAME = "hall timeout", VALUE = "300" })
check("Set Setting by name (case-insensitive)", Properties["Setting 1 Value"] == "300" and countFired(1) == 1)
EC.SET_SETTING({ NAME = "Hall timeout", VALUE = "abc" })
check("Set Setting bad value refused", Properties["Setting 1 Value"] == "300" and countFired(2) == 1)
EC.TOGGLE_SETTING({ NAME = "Night mode" })
check("Toggle flips", Properties["Setting 2 Value"] == "On" and vars["SETTING_2_NUMBER"] == 1)
EC.TOGGLE_SETTING({ NAME = "Hall timeout" })
check("Toggle on a non-toggle refused", countFired(2) == 2)
check("conditional equals numerically", TC.SETTING_1_IS("SETTING_1_IS", { LOGIC = "EQUAL", STRING = "300.0" }) == true)
check(
  "conditional not-equal",
  TC.SETTING_1_IS("SETTING_1_IS", { LOGIC = "NOT_EQUAL", STRING = "300" }) == false
    and TC.SETTING_1_IS("SETTING_1_IS", { LOGIC = "!=", STRING = "1" }) == true
)
check("conditional on toggle text", TC.SETTING_2_IS("SETTING_2_IS", { LOGIC = "EQUAL", STRING = "on" }) == true)
check(
  "conditional on an unused slot is false",
  TC.SETTING_9_IS("SETTING_9_IS", { LOGIC = "EQUAL", STRING = "" }) == false
)

print("[6] a Composer edit rebuilds the model and reports the change")
fired = {}
Properties["Setting 1 Value"] = "45"
OnPropertyChanged("Setting 1 Value")
check("variable follows a Composer edit", vars["SETTING_1"] == "45" and vars["SETTING_1_NUMBER"] == 45)
check(
  "Setting Changed fired for the Composer edit",
  countFired(1) == 1 and prop("Last Change"):find("Composer", 1, true) ~= nil
)
Properties["Setting 4 Name"] = "Fan speed"
Properties["Setting 4 Type"] = "Choice"
Properties["Setting 4 Options"] = "Low, High"
OnPropertyChanged("Setting 4 Options")
check("a newly named slot appears with its default", vars["SETTING_4"] == "Low" and vars["SETTINGS_CONFIGURED"] == 4)
Properties["Setting 4 Value"] = "Turbo"
OnPropertyChanged("Setting 4 Value")
check(
  "a bad Composer value falls back to the default and is named in the state",
  vars["SETTING_4"] == "Low" and relay("GET", "/state?k=" .. token):find("not one of", 1, true) ~= nil
)

print("[7] PIN lock after wrong PINs")
fired = {}
for _ = 1, 5 do
  relay("POST", "/set?k=" .. token, '{"name":"Hall timeout","value":"10","pin":"nope"}')
end
check(
  "Panel Locked fired once; writes say locked",
  countFired(3) == 1
    and relay("POST", "/set?k=" .. token, '{"name":"Hall timeout","value":"10","pin":"4321"}'):find("locked", 1, true)
      ~= nil
)
check(
  "status shows the lock; conditional false",
  prop("Panel Status"):find("locked") ~= nil and TC.PANEL_WRITABLE() == false
)
advance(61000)
check("lock expires with time", TC.PANEL_WRITABLE() == true)
for _ = 1, 5 do
  relay("POST", "/set?k=" .. token, '{"name":"Hall timeout","value":"10","pin":"nope"}')
end
EC.RESET_LOCK()
check("Reset PIN Lock clears it", TC.PANEL_WRITABLE() == true)

print("[8] licence enforcement makes the panel read-only; uncertainty does not")
fired = {}
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_DEALER_PANEL",
  status = "CLOUD_VALIDATION_REQUIRED",
  registered = "true",
  enforcement = "enforce",
})
check("uncertain status + enforce: still writable", TC.PANEL_WRITABLE() == true)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_DEALER_PANEL", status = "NOT_ENTITLED", registered = "true", enforcement = "enforce" })
check("definitive denial + enforce: read-only", TC.PANEL_WRITABLE() == false and prop("Panel Status") == "unlicensed")
r = relay("POST", "/set?k=" .. token, '{"name":"Hall timeout","value":"10","pin":"4321"}')
check("web write refused: unlicensed", r:find("unlicensed", 1, true) ~= nil and Properties["Setting 1 Value"] == "45")
EC.SET_SETTING({ NAME = "Hall timeout", VALUE = "10" })
check("programming write refused too", Properties["Setting 1 Value"] == "45" and countFired(2) >= 2)
check("reads still work", relay("GET", "/state?k=" .. token):find('"read_only_reason":"unlicensed"', 1, true) ~= nil)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_DEALER_PANEL", status = "NOT_ENTITLED", registered = "true", enforcement = "observe" })
check("observe mode restores writes", TC.PANEL_WRITABLE() == true)

print("[9] JS API channel and URL healing")
local okDec, doc = pcall(function()
  return JSON:decode(UIR.DEALER_GET_STATE({}))
end)
check("UIR state is the same document", okDec and doc.configured == 4 and doc.writable == true)
local setDoc = JSON:decode(UIR.DEALER_SET({ NAME = "Hall timeout", VALUE = "77", PIN = "4321" }))
check("UIR set writes through the same gate", setDoc.ok == true and Properties["Setting 1 Value"] == "77")
proxySends = {}
Properties["App Relay Address"] = "10.0.0.5"
OnPropertyChanged("App Relay Address")
check(
  "address override republishes the URL",
  proxySends[#proxySends].params.url:find("http://10.0.0.5:47822/app", 1, true) == 1
)
check("token persisted", persisted["dealerpanel_relay_token_v1"] ~= nil)

print("[10] print actions and removal")
local okP = pcall(function()
  EC.PRINT_SETTINGS()
  EC.REFRESH_STATUS()
  EC.RELOAD_URL()
  EC.REGISTER_NOW()
end)
check("actions run", okP)
local okD = pcall(OnDriverDestroyed)
check("destroy runs", okD and clock.timers["DpStatusPaint"] == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
