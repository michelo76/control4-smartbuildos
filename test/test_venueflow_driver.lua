-- VenueFlow DRIVER (drivers/smartbuildos-venueflow/driver.lua) under the test
-- shim with a scripted Director: lifecycle, licence registration with the
-- Agent, the relay socket (raw HTTP into OnServerDataIn), the Navigator
-- bridge (ExecuteCommand + SendDataToUI), the Control4 adapter's actual
-- commands and variable listeners in Live mode, Composer programming,
-- conditionals, properties, the licence gate, and a driver restart.
--
-- The Director here is a FAKE. This proves the driver's own logic and which
-- commands it sends; it proves nothing about how a controller answers.
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end
local function eq(name, got, want)
  check(name, got == want, string.format("got %s, want %s", tostring(got), tostring(want)))
end

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")

-- ── a clock with named timers ───────────────────────────────────────────────
local clock = { now = 0, timers = {}, base = 1794225600 }
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
      if
        t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and tostring(id) < tostring(bestId)))
      then
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
os.time = function()
  return clock.base + math.floor(clock.now / 1000)
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end

-- ── persistence that outlives a driver reload ───────────────────────────────
local persisted = {}
local function deep(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = deep(x)
  end
  return out
end
package.preload["lib.persist"] = function()
  local P = {}
  function P:get(key, default)
    if persisted[key] == nil then
      return default
    end
    return deep(persisted[key])
  end
  function P:set(key, value)
    persisted[key] = deep(value)
  end
  function P:delete(key)
    persisted[key] = nil
  end
  function P:reset() end
  return P
end

-- ── fake Director ───────────────────────────────────────────────────────────
local AGENT_ID, RECORDER_ID, SELF_ID = 50, 60, 12345
local sent, fired, vars, props, uiData, listeners = {}, {}, {}, {}, {}, {}
local rooms = {} -- roomId -> { POWER_STATE, CURRENT_VOLUME, IS_MUTED, CURRENT_VIDEO_DEVICE, CURRENT_AUDIO_DEVICE }
local VAR_IDS = {
  CURRENT_AUDIO_DEVICE = 1001,
  CURRENT_VIDEO_DEVICE = 1002,
  POWER_STATE = 1010,
  CURRENT_VOLUME = 1011,
  IS_MUTED = 1018,
}
C4.GetDevices = function()
  return {
    [AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
    [SELF_ID] = { deviceName = "VenueFlow", driverFileName = "smartbuildos-venueflow.c4z" },
    [1101] = {
      deviceName = "Bar TV 1 Room",
      driverFileName = "roomdevice.c4i",
      roomId = 1101,
      roomName = "Bar TV 1",
    },
    [2101] = {
      deviceName = "Bar TV 1",
      driverFileName = "tv_samsung.c4z",
      roomId = 1101,
      roomName = "Bar TV 1",
      proxies = { { proxy = "tv" } },
    },
    [3001] = {
      deviceName = "Sat Box 1",
      driverFileName = "satellite_x.c4z",
      roomId = 9,
      roomName = "Rack",
      proxies = { { proxy = "satellite" } },
    },
  }
end
C4.GetDevicesByC4iName = function(_, file)
  if file == "smartbuildos.c4z" then
    return { [AGENT_ID] = {} }
  elseif file == "smartbuildos-flight-recorder.c4z" then
    return { [RECORDER_ID] = {} }
  end
  return {}
end
C4.GetProjectItems = function()
  return ""
end
C4.GetDeviceVariables = function(_, id)
  local room = rooms[id]
  if room == nil then
    return {}
  end
  local out = {}
  for name, value in pairs(room) do
    out[VAR_IDS[name]] = { name = name, value = value }
  end
  return out
end
C4.RegisterVariableListener = function(_, device, variable)
  listeners[device .. ":" .. variable] = true
end
C4.UnregisterVariableListener = function(_, device, variable)
  listeners[device .. ":" .. variable] = nil
end
C4.GetDeviceDisplayName = function(_, id)
  return "Device " .. tostring(id)
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
    return "VenueFlow"
  end
  return "20261114.000000"
end
C4.GetTimeZone = function()
  return "America/New_York"
end
C4.SendToDevice = function(_, device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
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
  return { version = "4.3.0.0" }
end
C4.SendDataToUI = function(_, command, params)
  uiData[#uiData + 1] = { command = command, params = params }
end
local urlPublished = nil
C4.SendToProxy = function(_, _, command, params)
  if command == "URL_CHANGED" then
    urlPublished = params.url
  end
end
local servers = {}
C4.CreateServer = function(_, port, _, _, identifier)
  servers[port] = identifier or true
end
C4.DestroyServer = function(_, port)
  servers[port] = nil
end
local replies, closed = {}, {}
C4.ServerSend = function(_, handle, data)
  replies[handle] = data
end
C4.ServerCloseClient = function(_, handle)
  closed[handle] = true
end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-venueflow/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    Properties[name] = block:match("<default>(.-)</default>") or ""
  end
end
Properties["App Relay Address"] = "192.0.2.10" -- a documentation address, used as written

local function loadDriver()
  dofile("drivers/smartbuildos-venueflow/driver.lua")
end
loadDriver()

local function prop(name)
  return props[name] or Properties[name]
end
local function commands(device, command)
  local out = {}
  for _, s in ipairs(sent) do
    if (device == nil or s.device == device) and (command == nil or s.command == command) then
      out[#out + 1] = s
    end
  end
  return out
end
local function firedCount(id)
  local n = 0
  for _, f in ipairs(fired) do
    if f == id then
      n = n + 1
    end
  end
  return n
end

-- ── raw HTTP into the relay ─────────────────────────────────────────────────
local RELAY_ID = "venueflow-ui-relay"
local nextHandle = 0
local function raw(text, address)
  nextHandle = nextHandle + 1
  OnServerDataIn(nextHandle, text, address or "192.0.2.77", 47861, RELAY_ID)
  local reply = replies[nextHandle] or ""
  return tonumber(reply:match("^HTTP/1%.1 (%d+)")), reply:match("\r\n\r\n(.*)$") or "", reply, nextHandle
end
local function http(method, target, body)
  body = body or ""
  return raw(string.format("%s %s HTTP/1.1\r\nContent-Length: %d\r\n\r\n%s", method, target, #body, body))
end
local seq = 0
local tile = nil
local function api(command, payload, opts)
  opts = opts or {}
  seq = seq + 1
  local target = "/api" .. (opts.tile and ("?k=" .. tile) or "")
  local status, text = http(
    "POST",
    target,
    JSON:encode({ requestId = "d" .. seq, command = command, payload = payload or {}, session = opts.session })
  )
  local ok, doc = pcall(function()
    return JSON:decode(text)
  end)
  return ok and doc or nil, status
end

-- ════════════════════════════════════════════════════════════════════════════
print("[1] start: online in Simulation, registered with the Agent, relay listening")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
local reg = commands(AGENT_ID, "SBOS_REGISTER_DRIVER")[1]
check("registered with the SmartBuildOS Agent", reg ~= nil)
eq("under the VenueFlow SKU", reg and reg.params.sku, "SBOS_VENUEFLOW")
eq("Driver Status", prop("Driver Status"), "Online - Simulation")
eq("Control Mode defaults to Simulation", prop("Control Mode"), "Simulation")
eq("the relay listens on its port", servers[47861], RELAY_ID)
check(
  "the web view URL points at the relay",
  urlPublished ~= nil and urlPublished:match("^http://192%.0%.2%.10:47861/app%?k=%x+$") ~= nil,
  urlPublished
)
tile = urlPublished:match("k=(%x+)$")
check("the tile token is long", #tile >= 32)
eq(
  "Installer Studio is off without a passcode",
  prop("Installer Studio"),
  "Off - set an Installer Passcode (6+ characters)"
)
eq("Configuration", prop("Configuration"), "Not published [SIMULATION]")
check("no room command at start", #commands(1101) == 0)
check("a start marker went to the Flight Recorder", commands(RECORDER_ID, "RECORD_EVENT")[1] ~= nil)

print("[2] the relay socket")
local status, body = http("GET", "/ping")
eq("ping", status, 200)
eq("ping names the service", body, '{"ok":true,"service":"venueflow"}')
status, body = http("GET", "/app")
eq("the operator page is served from the embedded module", status, 200)
check("it is the VenueFlow page", body:find("<title>VenueFlow</title>", 1, true) ~= nil)
status, body = http("GET", "/studio")
check("the Studio page is served", status == 200 and body:find("Installer Studio", 1, true) ~= nil)
check("the connection is closed after a reply", closed[nextHandle] == true)
status = raw("garbage\r\n\r\n")
eq("garbage is a 400", status, 400)
status = raw("POST /api HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n")
eq("a declared oversize body is a 413", status, 413)
-- a request arriving in pieces on one connection
do
  nextHandle = nextHandle + 1
  local h = nextHandle
  local text = "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n"
  OnServerDataIn(h, text:sub(1, 10), "192.0.2.77", 47861, RELAY_ID)
  check("half a request: no reply yet", replies[h] == nil)
  OnServerDataIn(h, text:sub(11), "192.0.2.77", 47861, RELAY_ID)
  check("the rest: replied", replies[h] ~= nil and replies[h]:match("^HTTP/1%.1 200") ~= nil)
end
-- an abandoned connection leaves nothing behind
do
  nextHandle = nextHandle + 1
  OnServerDataIn(nextHandle, "POST /api HTTP/1.1\r\nContent-Length: 500\r\n\r\n{", "192.0.2.77", 47861, RELAY_ID)
  OnServerConnectionStatusChanged(nextHandle, 47861, "OFFLINE", "192.0.2.77", RELAY_ID)
  OnServerDataIn(nextHandle, "GET /ping HTTP/1.1\r\n\r\n", "192.0.2.77", 47861, RELAY_ID)
  check(
    "a dropped connection's partial request is forgotten",
    replies[nextHandle] ~= nil and replies[nextHandle]:match("^HTTP/1%.1 200") ~= nil
  )
end
OnServerDataIn(9999, "GET /ping HTTP/1.1\r\n\r\n", "192.0.2.77", 47861, "someone-elses-server")
check("data for another server is ignored", replies[9999] == nil)

print("[3] nothing is configured, and the Studio is off")
local r = api("HELLO", {}, { tile = true })
eq("not published", r.data.published, false)
eq("the Studio is reported off", r.data.studioEnabled, false)
eq("studio login refused with no passcode", api("STUDIO_LOGIN", { passcode = "" }).errorCode, "VF_STUDIO_DISABLED")
Properties["Installer Passcode"] = "bench-pass-1"
OnPropertyChanged("Installer Passcode")
eq("with a passcode the Studio address is shown", prop("Installer Studio"), "http://192.0.2.10:47861/studio")
eq("wrong passcode", api("STUDIO_LOGIN", { passcode = "nope-nope" }).errorCode, "VF_BAD_PASSCODE")
r = api("STUDIO_LOGIN", { passcode = "bench-pass-1" })
check("the passcode signs in", r.ok)
local studio = r.data.session
check("session tokens are long and random-looking", #studio >= 32 and studio ~= tile)
check("two sessions never share a token", api("STUDIO_LOGIN", { passcode = "bench-pass-1" }).data.session ~= studio)

print("[4] configure in Simulation: sample venue, publish")
r = api("TEMPLATE_APPLY", { venueType = "sports_bar", sample = true }, { session = studio })
check("sample loaded into the draft", r.ok, r and r.errorCode)
local acks = {}
for _, i in ipairs(r.data.draft.issues) do
  acks[#acks + 1] = i.id
end
r = api("PUBLISH", { acknowledged = acks }, { session = studio })
check("published", r.ok, r and r.errorCode)
eq("Configuration Published event", firedCount(4), 1)
advance(1000)
check(
  "the property page shows the venue",
  prop("Venue") == "Riverside Sports Bar" and prop("Configuration"):find("24 displays", 1, true) ~= nil
)
r = api("HELLO", {}, { tile = true })
eq("the tile opens as the default profile", r.data.profile.id, "bartender")
eq("with the bar's displays", #r.data.config.displays, 8)
local before = #sent
r = api("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-01" } }, { tile = true })
eq("a route in Simulation is accepted", r.status, "accepted")
advance(2000)
eq(
  "...and confirmed by the simulator",
  api("GET_STATE", {}, { tile = true }).data.state.displays["tv-01"].source.status,
  "confirmed"
)
local roomCommands = 0
for i = before + 1, #sent do
  if sent[i].device ~= AGENT_ID and sent[i].device ~= RECORDER_ID then
    roomCommands = roomCommands + 1
  end
end
eq("Simulation sends NOTHING to Control4", roomCommands, 0)
check(
  "persistence holds the published venue",
  type(persisted.vf_published_v1) == "table" and persisted.vf_published_v1.versionId == "v1"
)

print("[5] the Navigator bridge (C4.sendCommand -> ExecuteCommand -> SendDataToUI)")
ExecuteCommand("VF_COMMAND", { ENVELOPE = JSON:encode({ requestId = "b1", command = "HELLO", payload = {} }) })
local last = uiData[#uiData]
check("a reply went back through SendDataToUI", last ~= nil and last.command == "VF_REPLY")
local reply = JSON:decode(last.params.ENVELOPE)
eq("it answers the request", reply.requestId, "b1")
eq("the bridge acts as the tile's default profile", reply.data.profile.id, "bartender")
ExecuteCommand("VF_COMMAND", { ENVELOPE = JSON:encode({ requestId = "b2", command = "DRAFT_GET", payload = {} }) })
eq("the bridge opens no configuration", JSON:decode(uiData[#uiData].params.ENVELOPE).errorCode, "VF_UNAUTHENTICATED")
local n = #uiData
ExecuteCommand("VF_COMMAND", { ENVELOPE = "not json" })
eq("a malformed envelope is dropped quietly", #uiData, n)
check("the bridge command is kept out of the debug log (it can carry a PIN)", EC.suppressDebug.VF_COMMAND == true)
check("the passcode property is kept out of the debug log", OPC.suppressDebug["Installer Passcode"] == true)

print("[6] Live mode: a sample venue is refused; the real venue sends real commands")
Properties["Control Mode"] = "Live"
OnPropertyChanged("Control Mode")
eq("Driver Status", prop("Driver Status"), "Online")
eq("the sample venue does not run live", prop("Configuration"), "Sample venue - not run in Live mode")
check("no room command was sent", #commands(1101) == 0)
do
  local draft = api("DRAFT_GET", {}, { session = studio }).data.draft
  draft.config.venue.sample = nil
  check(
    "the real venue is saved",
    api("DRAFT_SAVE", { config = draft.config, baseRevision = draft.revision }, { session = studio }).ok
  )
  local a = {}
  for _, i in ipairs(api("DRAFT_GET", {}, { session = studio }).data.draft.issues) do
    a[#a + 1] = i.id
  end
  check("...and published", api("PUBLISH", { acknowledged = a }, { session = studio }).ok)
end
advance(1000)
check(
  "listeners are registered on a mapped room's variables",
  listeners["1101:1002"] and listeners["1101:1010"] and listeners["1201:1011"] and listeners["1201:1018"]
)
eq(
  "Live starts with unknown state (nothing read back yet)",
  api("GET_STATE", {}, { tile = true }).data.state.displays["tv-01"].source.status,
  "unknown"
)

sent = {}
r = api("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-01" } }, { tile = true })
eq("accepted", r.status, "accepted")
local cmd = commands(1101)[1]
eq("SELECT_VIDEO_DEVICE goes to the display's room", cmd and cmd.command, "SELECT_VIDEO_DEVICE")
eq("with the source's device id", cmd and cmd.params.deviceid, 3001)
eq(
  "pending until Control4 answers",
  api("GET_STATE", {}, { tile = true }).data.state.displays["tv-01"].source.status,
  "pending"
)
-- Control4 reports the room changed.
rooms[1101] = {
  POWER_STATE = "1",
  CURRENT_VIDEO_DEVICE = "3001",
  CURRENT_AUDIO_DEVICE = "3001",
  CURRENT_VOLUME = "30",
  IS_MUTED = "0",
}
OnWatchedVariableChanged(1101, 1002, "3001")
local st = api("GET_STATE", {}, { tile = true }).data.state
eq("confirmed by the room variable", st.displays["tv-01"].source.status, "confirmed")
eq("power read from the room", st.displays["tv-01"].power.value, "on")

-- a room that never answers
r = api("ROUTE_VIDEO", { sourceId = "sports-2", displayIds = { "tv-02" } }, { tile = true })
advance(9000)
eq(
  "no feedback, nothing readable: unknown, never 'confirmed'",
  api("GET_STATE", {}, { tile = true }).data.state.displays["tv-02"].source.status,
  "unknown"
)
-- a room that answers with something else
rooms[1103] = { POWER_STATE = "1", CURRENT_VIDEO_DEVICE = "3005" }
r = api("ROUTE_VIDEO", { sourceId = "sports-2", displayIds = { "tv-03" } }, { tile = true })
advance(9000)
st = api("GET_STATE", {}, { tile = true }).data.state
eq("Control4 reports another source: failed", st.displays["tv-03"].source.status, "failed")
eq("...showing what Control4 actually reports", st.displays["tv-03"].source.value, "news")

local manager = api("PROFILE_LOGIN", { profileId = "manager", pin = "2580" }).data.session
sent = {}
api("AUDIO_VOLUME", { zoneId = "zone-bar", level = 60 }, { session = manager })
api("AUDIO_MUTE", { zoneId = "zone-bar", muted = true }, { session = manager })
api("AUDIO_SOURCE", { zoneId = "zone-bar", sourceId = "music" }, { session = manager })
api("AUDIO_POWER", { zoneId = "zone-dining", power = "off" }, { session = manager })
api("DISPLAY_POWER", { displayIds = { "tv-24" }, power = "on" }, { session = manager })
api("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-24" } }, { session = manager })
api("LIGHTING_PRESET", { lightingId = "house-lights", presetId = "game-day" }, { session = manager })
api("DISPLAY_POWER", { displayIds = { "tv-04" }, power = "off" }, { session = manager })
advance(3000)
eq("SET_VOLUME_LEVEL to the zone's room", commands(1201, "SET_VOLUME_LEVEL")[1].params.LEVEL, 60)
check("MUTE_ON to the zone's room", commands(1201, "MUTE_ON")[1] ~= nil)
eq("SELECT_AUDIO_DEVICE to the zone's room", commands(1201, "SELECT_AUDIO_DEVICE")[1].params.deviceid, 3008)
check("ROOM_OFF to the zone's room", commands(1202, "ROOM_OFF")[1] ~= nil)
check("ON to a device-powered display", commands(2124, "ON")[1] ~= nil)
eq("the custom route command, with the source substituted", commands(2900, "SET_INPUT")[1].params.INPUT, 3001)
eq("the lighting preset's command", commands(4001, "ACTIVATE_SCENE")[1].params.SCENE_ID, 11)
check("ROOM_OFF to a room-powered display", commands(1104, "ROOM_OFF")[1] ~= nil)
check("commands were spaced by the queue, all eventually sent", #sent >= 8, #sent)

print("[7] Composer programming and conditionals")
fired = {}
ExecuteCommand("SET_VENUE_STATUS", { STATUS = "Open" })
eq("venue opened", vars.VENUE_STATUS, "open")
eq("Venue Opened event", firedCount(5), 1)
eq("conditional: venue is open", TestCondition("VENUE_OPEN", {}), true)
ExecuteCommand("ACTIVATE_SCENE", { SCENE = "Game Day" })
eq("Scene Activated event", firedCount(1), 1)
eq("ACTIVE_SCENE variable", vars.ACTIVE_SCENE, "Game Day")
eq("conditional: scene active", TestCondition("SCENE_ACTIVE", { VALUE = "game day", LOGIC = "EQUAL" }), true)
eq("conditional: scene not active", TestCondition("SCENE_ACTIVE", { VALUE = "Closing", LOGIC = "NOT_EQUAL" }), true)
eq("Active Scene property", prop("Active Scene"), "Game Day")
check(
  "the scene's notification reached Composer",
  vars.NOTIFICATION_TEXT == "Game Day is running" and firedCount(2) == 1
)
advance(12000)
ExecuteCommand("ACTIVATE_SCENE", { SCENE = "Brunch" })
check(
  "an unknown scene is refused and said so",
  prop("Last Error"):find("ACTIVATE_SCENE refused", 1, true) ~= nil,
  prop("Last Error")
)
sent = {}
ExecuteCommand("ROUTE_SOURCE", { SOURCE = "Cable News", TARGET = "TV 05" })
eq("ROUTE_SOURCE from programming", commands(1105, "SELECT_VIDEO_DEVICE")[1].params.deviceid, 3005)
ExecuteCommand("TRIGGER_EVENT", { NAME = "nothing-waits-for-this" })
check("an event nothing waits for is refused quietly", prop("Last Error"):find("TRIGGER_EVENT refused", 1, true) ~= nil)
check("HAS_ALERTS answers", type(TestCondition("HAS_ALERTS", {})) == "boolean")

print("[8] the licence gate: automation stops, control does not, nothing is switched off")
fired, sent = {}, {}
ExecuteCommand("SBOS_ENTITLEMENT", { sku = "SBOS_OTHER", status = "NOT_ENTITLED", enforcement = "enforce" })
eq("another driver's entitlement is ignored", firedCount(7), 0)
ExecuteCommand("SBOS_ENTITLEMENT", { sku = "SBOS_VENUEFLOW", status = "NOT_ENTITLED", enforcement = "observe" })
eq("a denial without enforcement restricts nothing", firedCount(7), 0)
ExecuteCommand(
  "SBOS_ENTITLEMENT",
  { sku = "SBOS_VENUEFLOW", status = "CLOUD_VALIDATION_REQUIRED", enforcement = "enforce" }
)
eq("an outage (cloud validation required) restricts nothing, even with enforcement", firedCount(7), 0)
ExecuteCommand("SBOS_ENTITLEMENT", { sku = "SBOS_VENUEFLOW", status = "AUTHORIZED_GRACE", enforcement = "enforce" })
eq("the grace period restricts nothing", firedCount(7), 0)
ExecuteCommand("SBOS_ENTITLEMENT", { sku = "SBOS_VENUEFLOW", status = "NOT_ENTITLED", enforcement = "enforce" })
eq("a definitive denial with enforcement fires Licence Restricted", firedCount(7), 1)
check(
  "no device was switched off or commanded by the licence change",
  #commands(nil, "ROOM_OFF") == 0 and #commands(nil, "OFF") == 0
)
eq(
  "scenes are refused",
  api("SCENE_ACTIVATE", { sceneId = "happy-hour" }, { session = manager }).errorCode,
  "VF_LICENSE_RESTRICTED"
)
eq(
  "publishing is refused",
  api("PUBLISH", { acknowledged = {} }, { session = studio }).errorCode,
  "VF_LICENSE_RESTRICTED"
)
eq(
  "manual routing still works",
  api("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-06" } }, { session = manager }).status,
  "accepted"
)
eq(
  "volume still works",
  api("AUDIO_VOLUME", { zoneId = "zone-bar", level = 30 }, { session = manager }).status,
  "accepted"
)
eq("All Off still works", api("ALL_OFF", { confirm = true }, { session = manager }).ok, true)
eq(
  "the state says the licence is restricted",
  api("GET_STATE", {}, { session = manager }).data.state.license.restricted,
  true
)
check(
  "a backup can still be exported (the configuration is not held hostage)",
  api("BACKUP_EXPORT", {}, { session = studio }).ok
)
ExecuteCommand(
  "SBOS_ENTITLEMENT",
  { sku = "SBOS_VENUEFLOW", status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce" }
)
eq("Licence Restored fires", firedCount(8), 1)
advance(9000)
ExecuteCommand("SET_VENUE_STATUS", { STATUS = "Open" })
eq("scenes work again", api("SCENE_ACTIVATE", { sceneId = "happy-hour" }, { session = manager }).ok, true)
advance(9000)

print("[9] the passcode changes: Studio sessions end")
check("the studio session works", api("DRAFT_GET", {}, { session = studio }).ok)
Properties["Installer Passcode"] = "another-pass-2"
OnPropertyChanged("Installer Passcode")
eq("the old session is gone", api("DRAFT_GET", {}, { session = studio }).errorCode, "VF_UNAUTHENTICATED")
eq("the old passcode no longer works", api("STUDIO_LOGIN", { passcode = "bench-pass-1" }).errorCode, "VF_BAD_PASSCODE")
studio = api("STUDIO_LOGIN", { passcode = "another-pass-2" }).data.session
check("the new one does", studio ~= nil)
Properties["Installer Passcode"] = ""
OnPropertyChanged("Installer Passcode")
eq(
  "emptying the passcode turns the Studio off",
  api("DRAFT_GET", {}, { session = studio }).errorCode,
  "VF_STUDIO_DISABLED"
)
Properties["Installer Passcode"] = "another-pass-2"
OnPropertyChanged("Installer Passcode")

print("[10] actions")
ExecuteCommand("LUA_ACTION", { ACTION = "PRINT_STATUS" })
ExecuteCommand("LUA_ACTION", { ACTION = "PRINT_STUDIO_LINK" })
ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_STATUS" })
ExecuteCommand("LUA_ACTION", { ACTION = "END_STAFF_SESSIONS" })
eq("End Staff Sessions ends them", api("GET_STATE", {}, { session = manager }).errorCode, "VF_UNAUTHENTICATED")
ExecuteCommand("LUA_ACTION", { ACTION = "RESET_SIGNIN_LOCKS" })
ExecuteCommand("LUA_ACTION", { ACTION = "RELOAD" })
check("actions run without error", prop("Driver Status") == "Online")

print("[11] restart: configuration and status come back; sessions do not")
local version = persisted.vf_published_v1.versionId
OnDriverDestroyed()
eq("the relay is closed on destroy", servers[47861], nil)
check(
  "runtime was saved on destroy",
  type(persisted.vf_runtime_v1) == "table" and persisted.vf_runtime_v1.venueStatus == "open"
)
props, sent, fired, listeners, replies = {}, {}, {}, {}, {}
clock.timers = {}
package.loaded["venueflow.core"] = nil -- a fresh module table, as after a controller reboot
loadDriver()
OnDriverInit()
OnDriverLateInit("DIT_STARTUP")
eq("online again, still Live", prop("Driver Status"), "Online")
check(
  "the venue is back",
  prop("Venue") == "Riverside Sports Bar" and prop("Configuration"):find(version, 1, true) ~= nil,
  prop("Configuration")
)
eq("venue status is back", prop("Venue Status"), "open")
check("the same tile token is published (tiles keep working)", urlPublished:match("k=(%x+)$") == tile)
check("listeners are registered again", listeners["1101:1002"] == true)
eq(
  "room state is re-read from Control4",
  api("GET_STATE", {}, { tile = true }).data.state.displays["tv-01"].source.status,
  "confirmed"
)
check("a restart sends no room command by itself", #commands(1101) == 0)
eq("staff sessions did not survive", api("GET_STATE", {}, { session = manager }).errorCode, "VF_UNAUTHENTICATED")
check("staff can sign in again", api("PROFILE_LOGIN", { profileId = "manager", pin = "2580" }).ok)
check("registered with the Agent again", commands(AGENT_ID, "SBOS_REGISTER_DRIVER")[1] ~= nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
