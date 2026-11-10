-- Home Guide DRIVER under the shim with a scripted Agent: lifecycle, manual
-- build from a fake project, relay server + URL publishing, relay routes
-- (/ping tokenless, /app, /manual with token, /refresh), property-driven
-- rebuild, Composer action/command, licence registration and enforcement
-- halting/restoring the relay, destroy.
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
-- The clock follows the timers, as in the other driver tests.
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
local agentPresent = false
local sent = {}
local fired = {}
local proxySends = {}
local props = {}
local vars = {}
local serverCreated = nil
local serverDestroyed = 0
local serverSent = {}
local FAKE_APP_HTML = "<!doctype html><html><head><title>Home Guide</title></head><body>"
  .. string.rep("<p>x</p>", 80)
  .. "</body></html>"
local devices = {
  [12] = { deviceName = "Kitchen Pendants", driverFileName = "light_v2.c4i", roomId = 3, roomName = "Kitchen" },
  [14] = {
    deviceName = "Fridge Keypad",
    driverFileName = "control4_lux_configurable_keypad.c4i",
    roomId = 3,
    roomName = "Kitchen",
  },
  [20] = { deviceName = "Front Door", driverFileName = "lock_yale_zwave.c4z", roomId = 1, roomName = "Entry" },
  [30] = { deviceName = "Apple TV", driverFileName = "appleTV.c4z", roomId = 5, roomName = "Living" },
  [60] = { deviceName = "CORE 1", driverFileName = "control4_core1.c4i", roomId = 9, roomName = "Equipment Room" },
  [SELF_ID] = {
    deviceName = "Home Guide",
    driverFileName = "smartbuildos-user-manual.c4z",
    roomId = 9,
    roomName = "Equipment Room",
  },
}
C4.GetDevices = function()
  local d = {}
  for k, v in pairs(devices) do
    d[k] = v
  end
  if agentPresent then
    d[AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" }
  end
  return d
end
C4.GetNetworkBindingsByDevice = function(_, id)
  if id == 60 then
    return { bindings = { { addr = "192.168.7.20" } } }
  end
  return {}
end
C4.GetBindingsByDevice = function()
  return {}
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "Home Guide"
  end
  return "20261109.000000"
end
C4.SendToDevice = function(_, device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
end
SendToDevice = function(device, command, params)
  C4.SendToDevice(C4, device, command, params)
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
C4.FileExists = function()
  return true
end
C4.FileOpen = function()
  return 7
end
C4.FileGetSize = function()
  return #FAKE_APP_HTML
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
C4.DestroyServer = function()
  serverDestroyed = serverDestroyed + 1
end
C4.HMAC = function(_, _, seed)
  local h = 0
  for i = 1, #seed do
    h = (h * 31 + seed:byte(i)) % 4294967296
  end
  return string.rep(string.format("%08x", h), 8)
end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-user-manual/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    Properties[name] = default
  end
end
Properties["Dealer Name"] = "Skynet AV"
Properties["Dealer Phone"] = "555-0100"
Properties["Room Note 1"] = "Kitchen: Pendants dim from the fridge keypad."

-- The relay's own address check (lib.relayhost): a candidate address is
-- published only once THIS relay has answered /ping on it. Here the relay
-- answers on the controller's address and nowhere else.
RELAY_ANSWERS_ON = { ["192.168.7.20"] = true }
RELAY_PINGS = {}
require("lib.relayhost").get = function(url, done)
  RELAY_PINGS[#RELAY_PINGS + 1] = url
  local host = url:match("^http://([%d%.]+):")
  if RELAY_ANSWERS_ON[host] then
    done(true, '{"ok":true,"service":"home-guide"}')
  else
    done(false)
  end
end

dofile("drivers/smartbuildos-user-manual/driver.lua")

local function prop(name)
  return props[name] or Properties[name]
end
local function lastProxy(command)
  for i = #proxySends, 1, -1 do
    if proxySends[i].command == command then
      return proxySends[i]
    end
  end
  return nil
end
local function hasFired(id)
  for _, f in ipairs(fired) do
    if f == id then
      return true
    end
  end
  return false
end
local function lastSent(command)
  for i = #sent, 1, -1 do
    if sent[i].command == command then
      return sent[i]
    end
  end
  return nil
end
local function request(line)
  serverSent = {}
  OnServerDataIn(99, line .. "\r\n\r\n", nil, nil, "home-guide-ui-relay")
  return serverSent[1] and serverSent[1].data or ""
end

print("[1] starts without an Agent: manual built, relay up, URL published")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", props["Driver Status"] == "Online")
check(
  "manual built from the project: 4 devices in 3 rooms",
  prop("Devices In Manual"):find("4 device%(s%) in 3 room%(s%)") ~= nil,
  prop("Devices In Manual")
)
check(
  "self and the controller excluded",
  prop("Devices In Manual"):find("2 not shown") ~= nil,
  prop("Devices In Manual")
)
check("Manual Rebuilt fired", hasFired(1))
check(
  "relay server created on 47821 with its identifier",
  serverCreated ~= nil and serverCreated.port == 47821 and serverCreated.identifier == "home-guide-ui-relay"
)
local url = lastProxy("URL_CHANGED")
check("URL_CHANGED to the uibutton proxy", url ~= nil and url.binding == 5001)
check(
  "same-origin relay URL with the discovered host",
  url ~= nil and url.params.url:find("^http://192%.168%.7%.20:47821/app%?k=%w+$") ~= nil,
  url and url.params.url
)
local token = url and url.params.url:match("k=(%w+)") or ""
check("token minted and persisted", #token >= 16 and persisted["hg_relay_token_v1"] == token)
check(
  "relay status painted",
  prop("App Data Relay"):find("Listening :47821", 1, true) ~= nil
    and prop("App Data Relay"):find("192.168.7.20", 1, true) ~= nil,
  prop("App Data Relay")
)
check("status serving", prop("Manual Status") == "serving" and vars["MANUAL_STATUS"] == "serving")
check(
  "variables",
  vars["MANUAL_ROOMS"] == 3 and vars["MANUAL_DEVICES"] == 4 and tostring(vars["LAST_REBUILT"]):find("T") ~= nil
)
check("licence shows no Agent", prop("License Status") == "No SmartBuildOS Agent Found")
check("no licence registration sent without an Agent", lastSent("SBOS_REGISTER_DRIVER") == nil)

print("[2] relay routes")
local r = request("GET /ping HTTP/1.1")
check("/ping tokenless", r:find("^HTTP/1.1 200 OK") ~= nil and r:find("home%-guide") ~= nil)
r = request("GET /app HTTP/1.1")
check(
  "/app serves the page tokenless",
  r:find("text/html", 1, true) ~= nil and r:find("<title>Home Guide</title>", 1, true) ~= nil
)
r = request("GET /manual HTTP/1.1")
check("/manual without token → 403", r:find("403 Forbidden", 1, true) ~= nil)
r = request("GET /manual?k=" .. token .. " HTTP/1.1")
check(
  "/manual with token → JSON of this project",
  r:find("200 OK", 1, true) ~= nil
    and r:find('"Kitchen Pendants"', 1, true) ~= nil
    and r:find('"Skynet AV"', 1, true) ~= nil
)
check("manual carries the kitchen note", r:find("Pendants dim from the fridge keypad.", 1, true) ~= nil)
check(
  "manual never lists the agent or the controller",
  r:find("CORE 1", 1, true) == nil and r:find("smartbuildos-user-manual", 1, true) == nil
)
r = request("GET /manual?k=wrong HTTP/1.1")
check("bad token → 403", r:find("403 Forbidden", 1, true) ~= nil)
fired = {}
r = request("POST /refresh?k=" .. token .. " HTTP/1.1")
check("/refresh rebuilds", r:find("200 OK", 1, true) ~= nil and hasFired(1))
check(
  "a frame from another server is ignored",
  (function()
    serverSent = {}
    OnServerDataIn(5, "GET /ping HTTP/1.1\r\n\r\n", nil, nil, "someone-else")
    return #serverSent == 0
  end)()
)
check(
  "a chunked request waits for the rest",
  (function()
    serverSent = {}
    OnServerDataIn(77, "GET /pi", nil, nil, "home-guide-ui-relay")
    local none = #serverSent == 0
    OnServerDataIn(77, "ng HTTP/1.1\r\n\r\n", nil, nil, "home-guide-ui-relay")
    return none and #serverSent == 1
  end)()
)

print("[3] project and property changes rebuild")
devices[40] =
  { deviceName = "Garage Door", driverFileName = "garagedoor_relay_control.c4i", roomId = 7, roomName = "Garage" }
EC.REFRESH_MANUAL()
check(
  "new device after Refresh Manual",
  prop("Devices In Manual"):find("5 device%(s%) in 4 room%(s%)") ~= nil,
  prop("Devices In Manual")
)
Properties["Dealer Email"] = "help@skynet.example"
OnPropertyChanged("Dealer Email")
r = request("GET /manual?k=" .. token .. " HTTP/1.1")
check("dealer property change reflected", r:find("help@skynet.example", 1, true) ~= nil)
fired = {}
advance(3600 * 1000 + 100)
check("hourly rebuild", hasFired(1))
EC.REBUILD_MANUAL({})
check("programming command rebuilds without error", prop("Manual Status") == "serving")

print("[4] the Agent appears: licence registration under the SKU")
agentPresent = true
EC.REGISTER_NOW()
local reg = lastSent("SBOS_REGISTER_DRIVER")
check(
  "registration to the Agent with SBOS_USER_MANUAL",
  reg ~= nil and reg.device == AGENT_ID and reg.params.sku == "SBOS_USER_MANUAL"
)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_USER_MANUAL",
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "subscription",
  registered = "true",
  subscription_tier = "Professional",
  company_name = "Skynet AV",
})
check(
  "licence painted",
  prop("License Status"):find("Licensed") ~= nil and prop("SmartBuildOS Company") == "Skynet AV",
  prop("License Status")
)
check("still serving", prop("Manual Status") == "serving")

print("[5] enforcement halts the relay; uncertainty never does")
fired = {}
proxySends = {}
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_USER_MANUAL",
  status = "CLOUD_VALIDATION_REQUIRED",
  registered = "true",
  enforcement = "enforce",
})
check("uncertain + enforce changes nothing", serverDestroyed == 0 and prop("Manual Status") == "serving")
EC.SBOS_ENTITLEMENT({ sku = "SBOS_USER_MANUAL", status = "NOT_ENTITLED", registered = "true", enforcement = "enforce" })
check(
  "definitive denial + enforce stops the relay",
  serverDestroyed == 1 and prop("Manual Status") == "unlicensed",
  prop("Manual Status")
)
check("Guide Unavailable fired", hasFired(2))
check(
  "relay status says stopped and read-only",
  prop("App Data Relay"):find("^Stopped") ~= nil and prop("License Status"):find("read%-only") ~= nil,
  prop("App Data Relay")
)
local haltedUrl = lastProxy("URL_CHANGED")
check(
  "URL republished as controller:// (no relay)",
  haltedUrl ~= nil and haltedUrl.params.url == "controller://driver/smartbuildos-user-manual/app/index.html",
  haltedUrl and haltedUrl.params.url
)
serverCreated = nil
EC.SBOS_ENTITLEMENT({ sku = "SBOS_USER_MANUAL", status = "NOT_ENTITLED", registered = "true", enforcement = "observe" })
check(
  "observe mode restores the relay",
  serverCreated ~= nil and serverCreated.port == 47821 and prop("Manual Status") == "serving"
)
check("Guide Restored fired", hasFired(3))
local backUrl = lastProxy("URL_CHANGED")
check("URL back to the relay", backUrl ~= nil and backUrl.params.url:find("^http://192%.168%.7%.20:47821/app") ~= nil)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_USER_MANUAL", status = "AUTHORIZED_SUBSCRIPTION", registered = "true" })

print("[6] relay address override and unknown host")
Properties["App Relay Address"] = "10.0.0.5"
OnPropertyChanged("App Relay Address")
check("manual address wins", lastProxy("URL_CHANGED").params.url:find("^http://10%.0%.0%.5:47821/app") ~= nil)
Properties["App Relay Address"] = "Auto"
devices[60] = nil
OnPropertyChanged("App Relay Address")
check(
  "no controller device → controller:// URL and a status asking for the address",
  lastProxy("URL_CHANGED").params.url == "controller://driver/smartbuildos-user-manual/app/index.html"
    and prop("App Data Relay"):find("UNKNOWN", 1, true) ~= nil,
  prop("App Data Relay")
)
devices[60] = { deviceName = "CORE 1", driverFileName = "control4_core1.c4i", roomId = 9, roomName = "Equipment Room" }

print("[6b] another Control4 device on the network is not mistaken for the controller")
-- Bench, 10 Nov 2026: the tile was published at a remote's address.
do
  devices[40] =
    { deviceName = "Living Remote", driverFileName = "control4_remote_halo.c4z", roomId = 1, roomName = "Living" }
  local savedBindings = C4.GetNetworkBindingsByDevice
  C4.GetNetworkBindingsByDevice = function(_, id)
    if id == 40 then
      return { networkbindings = { { addr = "192.168.7.31" } } }
    end
    return savedBindings(C4, id)
  end
  RELAY_PINGS = {}
  OnPropertyChanged("App Relay Address")
  local published = lastProxy("URL_CHANGED").params.url
  check(
    "the remote was asked, and did not answer",
    (RELAY_PINGS[1] or ""):find("192.168.7.31:47821/ping", 1, true) ~= nil
  )
  check(
    "the tile is published at the address the relay answered on",
    published:find("^http://192%.168%.7%.20:47821/app%?k=") ~= nil,
    published
  )
  check(
    "and the status says the same",
    prop("App Data Relay"):find("192.168.7.20", 1, true) ~= nil,
    prop("App Data Relay")
  )
  -- The controller stops answering there (a new lease): nothing wrong is left up.
  RELAY_ANSWERS_ON = {}
  advance(16 * 60 * 1000)
  check(
    "when nothing answers any more, no address is published",
    lastProxy("URL_CHANGED").params.url == "controller://driver/smartbuildos-user-manual/app/index.html"
      and prop("App Data Relay"):find("UNKNOWN", 1, true) ~= nil,
    prop("App Data Relay")
  )
  RELAY_ANSWERS_ON = { ["192.168.7.20"] = true }
  advance(2 * 60 * 1000)
  check(
    "and it comes back by itself",
    lastProxy("URL_CHANGED").params.url:find("^http://192%.168%.7%.20:47821/app") ~= nil,
    lastProxy("URL_CHANGED").params.url
  )
  devices[40] = nil
  C4.GetNetworkBindingsByDevice = savedBindings
end

print("[7] print and destroy")
check("print outline runs", pcall(EC.PRINT_OUTLINE))
serverDestroyed = 0
OnDriverDestroyed()
check("destroy stops the relay and timers", serverDestroyed == 1 and next(clock.timers) == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
