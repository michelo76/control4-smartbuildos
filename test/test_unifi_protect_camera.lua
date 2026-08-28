-- Tests for drivers/unifi-protect-camera/driver.lua.
--
-- The child holds no credentials and makes no HTTP requests — its whole world
-- is two bindings: the Gateway (CONTROL binding 1) and the camera proxy
-- (5001). So the tests drive both sides of each conversation and assert on
-- what crossed the wire. Invariants:
--
--   * Binding to the Gateway asks PROTECT_GET_CAMERA; the reply fills in and
--     PERSISTS identity, so a Director restart shows the camera unaided.
--   * GET_STREAM_URLS with a cold cache returns <streams generating_key="K"/>
--     and asks the Gateway; the Gateway's reply produces STREAM_URLS_READY
--     with the SAME key. A fresh cache answers synchronously.
--   * The Stream Protocol property rewrites rtsps:7441 → rtsp:7447 with the
--     query dropped — mechanically, only for URLs of that exact shape — and
--     flipping it notifies DYNAMIC_URLS_CHANGED.
--   * Changed URLs from the Gateway notify DYNAMIC_URLS_CHANGED; identical
--     ones do not (Navigators must not re-fetch on every poll).
--   * Unbinding keeps identity; FORGET_CAMERA is the deliberate reset.
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

package.preload["cloud-client-byte"] = function()
  return {}
end

local store = {}
package.preload["lib.persist"] = function()
  return {
    get = function(_, key, default)
      local value = store[key]
      if value == nil then
        return default
      end
      return value
    end,
    set = function(_, key, value)
      store[key] = value
    end,
    delete = function(_, key)
      store[key] = nil
    end,
  }
end

C4 = C4 or {}

require("c4_shim")

--- Everything the driver sent, per binding: { binding, command, params, message }.
local sent = {}
function C4:SendToProxy(binding, command, params, message)
  table.insert(sent, { binding = binding, command = command, params = params, message = message })
end

local function sentTo(binding, command)
  local hits = {}
  for _, s in ipairs(sent) do
    if s.binding == binding and s.command == command then
      table.insert(hits, s)
    end
  end
  return hits
end

local props = {}
function C4:UpdateProperty(name, value)
  props[name] = value
  if Properties[name] ~= nil then
    Properties[name] = value
  end
end

function C4:GetDriverConfigInfo(key)
  return ({ model = "UniFi Protect Camera", version = "1.0.0", minimum_os_version = "3.3.2" })[key]
end

function C4:GetVersionInfo()
  return { version = "4.0.0" }
end

Properties = {
  ["Camera"] = "Not bound",
  ["Camera State"] = "UNKNOWN",
  ["MAC Address"] = "-",
  ["Streams"] = "-",
  ["Gateway Link"] = "Not bound - bind the Protect Camera connection to the Gateway",
  ["Stream Protocol"] = "RTSPS (secure, port 7441)",
  ["Streams Offered"] = "All (client picks)",
  ["History"] = "Smart detections only",
  -- Zero for the legacy sections; the dedicated cooldown section sets its own.
  ["Motion Event Cooldown (seconds)"] = "0",
  ["Detection Event Cooldown (seconds)"] = "0",
  ["Capabilities"] = "-",
  ["Last Control"] = "-",
  ["Snapshots"] = "-",
  ["Driver Status"] = "Starting",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
}

package.path = "./drivers/unifi-protect-camera/?.lua;" .. package.path
dofile("drivers/unifi-protect-camera/driver.lua")

local GATEWAY, PROXY = 1, 5001

-- ─── [1] Startup and bind ────────────────────────────────────────────────────

print("\n[1] Startup asks the Gateway who it is; the reply persists")

OnDriverInit()
OnDriverLateInit()

check("identity requested at init", #sentTo(GATEWAY, "PROTECT_GET_CAMERA") >= 1)
-- UpdateProperty skips the C4 write when the value equals what the property
-- already holds, so an untouched capture (nil) and an explicit write are both
-- the unbound state.
check("Camera property says Not bound", props["Camera"] == nil or props["Camera"] == "Not bound", props["Camera"])

-- Gateway answers.
ReceivedFromProxy(GATEWAY, "PROTECT_CAMERA", {
  id = "cam-front",
  name = "Front Door",
  mac = "60223263A4D0",
  state = "CONNECTED",
  console_host = "192.168.4.1",
})

check("Camera property carries the name", props["Camera"] == "Front Door", props["Camera"])
check("MAC published", props["MAC Address"] == "60223263A4D0", props["MAC Address"])
check("state published", props["Camera State"] == "CONNECTED", props["Camera State"])
check("identity persisted", type(store["camera_identity"]) == "table" and store["camera_identity"].id == "cam-front")
check("online conditional true", TC.CAMERA_ONLINE() == true)

print("\n[2] Rebinding in Composer re-asks; unbinding keeps identity")

sent = {}
OnBindingChanged(GATEWAY, "UNIFI_PROTECT_CAMERA", true, 100, 10)
check("bind asks PROTECT_GET_CAMERA", #sentTo(GATEWAY, "PROTECT_GET_CAMERA") == 1)

OnBindingChanged(GATEWAY, "UNIFI_PROTECT_CAMERA", false, 100, 10)
check("unbind keeps the camera name", props["Camera"] == "Front Door", props["Camera"])
check("unbind drops state to UNKNOWN", props["Camera State"] == "UNKNOWN", props["Camera State"])
check("online conditional false after unbind", TC.CAMERA_ONLINE() == false)

-- Rebind and restore state for the rest of the suite.
ReceivedFromProxy(GATEWAY, "PROTECT_STATE", { id = "cam-front", name = "Front Door", state = "CONNECTED" })
check("state push restores CONNECTED", props["Camera State"] == "CONNECTED", props["Camera State"])

-- ─── [3] Dynamic streams, cold cache ─────────────────────────────────────────

print("\n[3] GET_STREAM_URLS cold: generating_key now, STREAM_URLS_READY later")

sent = {}
local answer = ReceivedFromProxy(PROXY, "GET_STREAM_URLS", { CODEC = "h264" })
local key = tostring(answer):match('generating_key="(%d+)"')
check("synchronous answer is a generating key", key ~= nil, answer)
check("the Gateway was asked", #sentTo(GATEWAY, "PROTECT_GET_STREAMS") == 1)
check(
  "with the same key",
  (sentTo(GATEWAY, "PROTECT_GET_STREAMS")[1].params or {}).KEY == key,
  (sentTo(GATEWAY, "PROTECT_GET_STREAMS")[1].params or {}).KEY
)

-- Gateway answers with native Protect URLs.
ReceivedFromProxy(GATEWAY, "PROTECT_STREAMS", {
  KEY = key,
  high = "rtsps://192.168.4.1:7441/HIGHTOKEN?enableSrtp",
  medium = "rtsps://192.168.4.1:7441/MEDTOKEN?enableSrtp",
})

local ready = sentTo(PROXY, "STREAM_URLS_READY")
check("STREAM_URLS_READY notified", #ready == 1, #ready)
check("as a NOTIFY", ready[1].message == "NOTIFY", ready[1].message)
check("echoing the key", (ready[1].params or {}).KEY == key, (ready[1].params or {}).KEY)
local xml = tostring((ready[1].params or {}).URLS)
check("URLS carries the high stream, native rtsps", xml:find("rtsps://192.168.4.1:7441/HIGHTOKEN", 1, true) ~= nil, xml)
check("high listed before medium", (xml:find("HIGHTOKEN") or 0) < (xml:find("MEDTOKEN") or 0))
check("camera_address is the console", xml:find('camera_address="192.168.4.1"', 1, true) ~= nil, xml)
check("Streams property lists qualities", props["Streams"] == "high, medium", props["Streams"])

print("\n[4] A fresh cache answers synchronously, no Gateway round trip")

sent = {}
local cached = ReceivedFromProxy(PROXY, "GET_STREAM_URLS", {})
check("synchronous streams XML", tostring(cached):find("HIGHTOKEN", 1, true) ~= nil, cached)
check("Gateway not asked again", #sentTo(GATEWAY, "PROTECT_GET_STREAMS") == 0)

-- ─── [5] Protocol downgrade property ─────────────────────────────────────────

print("\n[5] Stream Protocol RTSP rewrites 7441 rtsps to 7447 rtsp, query dropped")

sent = {}
Properties["Stream Protocol"] = "RTSP (unencrypted, port 7447)"
OnPropertyChanged("Stream Protocol")
check("flip notifies DYNAMIC_URLS_CHANGED", #sentTo(PROXY, "DYNAMIC_URLS_CHANGED") == 1)

local downgraded = tostring(ReceivedFromProxy(PROXY, "GET_STREAM_URLS", {}))
check("URL downgraded mechanically", downgraded:find("rtsp://192.168.4.1:7447/HIGHTOKEN", 1, true) ~= nil, downgraded)
check("query dropped", downgraded:find("enableSrtp", 1, true) == nil, downgraded)
check("no rtsps URLs remain", downgraded:find("rtsps://", 1, true) == nil, downgraded)

local propsXml = tostring(ReceivedFromProxy(PROXY, "GET_PROPERTIES", {}))
check(
  "GET_PROPERTIES rtsp_port follows the property",
  propsXml:find("<rtsp_port>7447</rtsp_port>", 1, true) ~= nil,
  propsXml
)

Properties["Stream Protocol"] = "RTSPS (secure, port 7441)"
OnPropertyChanged("Stream Protocol")
propsXml = tostring(ReceivedFromProxy(PROXY, "GET_PROPERTIES", {}))
check("back on RTSPS the port is 7441", propsXml:find("<rtsp_port>7441</rtsp_port>", 1, true) ~= nil, propsXml)
check("GET_PROPERTIES address is the console host", propsXml:find("<address>192.168.4.1</address>", 1, true) ~= nil)

-- ─── [6] URL changes notify; identical refreshes do not ──────────────────────

print("\n[6] Changed URLs notify Navigators; identical ones stay quiet")

sent = {}
ReceivedFromProxy(GATEWAY, "PROTECT_STREAMS", {
  KEY = "999",
  high = "rtsps://192.168.4.1:7441/HIGHTOKEN?enableSrtp",
  medium = "rtsps://192.168.4.1:7441/MEDTOKEN?enableSrtp",
})
check("identical refresh does NOT notify", #sentTo(PROXY, "DYNAMIC_URLS_CHANGED") == 0)

sent = {}
ReceivedFromProxy(GATEWAY, "PROTECT_STREAMS", {
  KEY = "998",
  high = "rtsps://192.168.4.1:7441/NEWTOKEN?enableSrtp",
  medium = "rtsps://192.168.4.1:7441/MEDTOKEN?enableSrtp",
})
check("changed URL notifies DYNAMIC_URLS_CHANGED", #sentTo(PROXY, "DYNAMIC_URLS_CHANGED") == 1)

print("\n[7] A Gateway error clears the pending key and says so")

sent = {}
local answer2 = ReceivedFromProxy(PROXY, "GET_STREAM_URLS", { useCache = "false" })
-- Cache is still fresh, so force the async path by aging it.
if tostring(answer2):find("generating_key") == nil then
  gStreams.fetched_at = 0
  answer2 = ReceivedFromProxy(PROXY, "GET_STREAM_URLS", {})
end
local key2 = tostring(answer2):match('generating_key="(%d+)"')
check("cold request pending", key2 ~= nil, answer2)
ReceivedFromProxy(GATEWAY, "PROTECT_STREAMS_ERROR", { KEY = key2, reason = "gateway not configured" })
check("no STREAM_URLS_READY on error", #sentTo(PROXY, "STREAM_URLS_READY") == 0)
check(
  "Streams property carries the reason",
  tostring(props["Streams"]):find("gateway not configured", 1, true) ~= nil,
  props["Streams"]
)

-- ─── [8] Forget ──────────────────────────────────────────────────────────────

print("\n[8] Forget Camera clears identity and re-asks")

sent = {}
EC.FORGET_CAMERA()
check("identity gone from persist", store["camera_identity"] == nil)
check("Camera back to Not bound", props["Camera"] == "Not bound", props["Camera"])
check("re-asks the Gateway", #sentTo(GATEWAY, "PROTECT_GET_CAMERA") == 1)

-- Re-establish identity for the remaining sections ([8] forgot it).
ReceivedFromProxy(GATEWAY, "PROTECT_CAMERA", {
  id = "cam-front",
  name = "Front Door",
  mac = "60223263A4D0",
  state = "CONNECTED",
  console_host = "192.168.4.1",
})

-- ─── [9] Navigator's actual door: UIRequest ──────────────────────────────────

print("\n[9] GET_STREAM_URLS and GET_PROPERTIES answer through UIR")

check("UIR.GET_STREAM_URLS registered", type(UIR.GET_STREAM_URLS) == "function")
check("UIR.GET_PROPERTIES registered", type(UIR.GET_PROPERTIES) == "function")

-- Refresh the cache so the UIR call can answer synchronously.
sent = {}
local uirCold = UIRequest("GET_STREAM_URLS", { KEY = "77" })
if tostring(uirCold):find("generating_key") ~= nil then
  local pendingKey = tostring(uirCold):match('generating_key="(%d+)"')
  ReceivedFromProxy(GATEWAY, "PROTECT_STREAMS", {
    KEY = pendingKey,
    high = "rtsps://192.168.4.1:7441/HIGHTOKEN?enableSrtp",
  })
  uirCold = UIRequest("GET_STREAM_URLS", { KEY = "77" })
end
check("UIRequest returns streams XML", tostring(uirCold):find("HIGHTOKEN", 1, true) ~= nil, uirCold)
check("echoing the client KEY as an attribute", tostring(uirCold):find('key="77"', 1, true) ~= nil, uirCold)

local uirProps = tostring(UIRequest("GET_PROPERTIES", {}))
check("UIR GET_PROPERTIES answers", uirProps:find("<camera_properties>", 1, true) ~= nil, uirProps)

-- ─── [10] Protect events become Composer events ──────────────────────────────

print("\n[10] PROTECT_EVENT fires Composer events and sets variables")

local fired, vars = {}, {}
function C4:FireEvent(name)
  table.insert(fired, name)
end
function C4:SetVariable(name, value)
  vars[name] = value
end

local function lastFired()
  return fired[#fired]
end

fired = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "motion", phase = "start", at = "1000" })
check("motion start fires Motion Detected", lastFired() == "Motion Detected", lastFired())
check("MOTION_DETECTED true", vars.MOTION_DETECTED == "true", vars.MOTION_DETECTED)
check("LAST_MOTION stamped", vars.LAST_MOTION ~= nil)

ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "motion", phase = "end" })
check("motion end fires Motion Ended", lastFired() == "Motion Ended", lastFired())
check("MOTION_DETECTED false", vars.MOTION_DETECTED == "false", vars.MOTION_DETECTED)

fired = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "smart", phase = "start", types = "person,vehicle" })
check("two smart events fired", #fired == 2, #fired)
check("Person Detected fired", fired[1] == "Person Detected", fired[1])
check("Vehicle Detected fired", fired[2] == "Vehicle Detected", fired[2])
check("LAST_DETECTION carries the type", vars.LAST_DETECTION == "vehicle", vars.LAST_DETECTION)

fired = {}
ReceivedFromProxy(
  GATEWAY,
  "PROTECT_EVENT",
  { kind = "smart", phase = "start", types = "licensePlate", value = "ABC1234" }
)
check("License Plate Detected fired", lastFired() == "License Plate Detected", lastFired())
check("LAST_LICENSE_PLATE carries the plate", vars.LAST_LICENSE_PLATE == "ABC1234", vars.LAST_LICENSE_PLATE)

fired = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "ring" })
check("Doorbell Ring fired", lastFired() == "Doorbell Ring", lastFired())

fired = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "audio", phase = "start", types = "alrmSmoke" })
check("Audio Alarm Detected fired", lastFired() == "Audio Alarm Detected", lastFired())
check("LAST_AUDIO_TYPE carries the class", vars.LAST_AUDIO_TYPE == "alrmSmoke", vars.LAST_AUDIO_TYPE)

fired = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "smart", phase = "end", types = "person" })
check("a smart END fires nothing", #fired == 0, #fired)

print("\n[11] Camera Online/Offline fire on real transitions only")

fired = {}
ReceivedFromProxy(GATEWAY, "PROTECT_STATE", { id = "cam-front", name = "Front Door", state = "DISCONNECTED" })
check("going dark fires Camera Offline", lastFired() == "Camera Offline", lastFired())
fired = {}
ReceivedFromProxy(GATEWAY, "PROTECT_STATE", { id = "cam-front", name = "Front Door", state = "CONNECTED" })
check("coming back fires Camera Online", lastFired() == "Camera Online", lastFired())

-- From UNKNOWN (a restart learning the state) no event fires.
EC.FORGET_CAMERA()
fired = {}
ReceivedFromProxy(GATEWAY, "PROTECT_STATE", { id = "cam-front", name = "Front Door", state = "CONNECTED" })
check("UNKNOWN -> CONNECTED fires nothing", #fired == 0, #fired)

-- ─── [12] Auto-naming ────────────────────────────────────────────────────────

print("\n[12] The instance names itself after the camera, without clobbering")

local renames = {}
local deviceNames = { [12345] = "UniFi Protect Camera 2", [500] = "UniFi Protect Camera 2" }
function C4:RenameDevice(id, name)
  renames[#renames + 1] = { id = id, name = name }
  deviceNames[id] = name
end
function C4:GetProxyDevices()
  return 500
end
function C4:GetDeviceData(id, key)
  if key == "name" then
    return deviceNames[id] or "Test Device"
  end
  return nil
end

ReceivedFromProxy(GATEWAY, "PROTECT_CAMERA", {
  id = "cam-front",
  name = "Front Door",
  mac = "60223263A4D0",
  state = "CONNECTED",
  console_host = "192.168.4.1",
})
check("both devices renamed", #renames == 2, #renames)
check("protocol device renamed", deviceNames[12345] == "Front Door", deviceNames[12345])
check("proxy device renamed", deviceNames[500] == "Front Door", deviceNames[500])
check("auto-name claim persisted", store["auto_name_last"] == "Front Door", store["auto_name_last"])

-- The camera gets renamed in Protect: the driver follows its own claim.
renames = {}
ReceivedFromProxy(GATEWAY, "PROTECT_STATE", { id = "cam-front", name = "Front Entry", state = "CONNECTED" })
check("a Protect rename follows through", deviceNames[500] == "Front Entry", deviceNames[500])

-- The dealer renames the device by hand: the driver keeps its hands off.
deviceNames[500] = "Backyard Custom Name"
deviceNames[12345] = "Backyard Custom Name"
renames = {}
ReceivedFromProxy(GATEWAY, "PROTECT_STATE", { id = "cam-front", name = "Front Porch", state = "CONNECTED" })
check("a dealer rename is never clobbered", #renames == 0, #renames)
check("name stays the dealer's", deviceNames[500] == "Backyard Custom Name", deviceNames[500])

-- Rename From Camera is the dealer overriding their own rename: guard off.
EC.RENAME_NOW()
check("Rename From Camera overrides the guard", deviceNames[500] == "Front Porch", deviceNames[500])

-- ─── [13] Identity self-heals off a state push ───────────────────────────────

print("\n[13] A state push while identity is unknown re-asks the Gateway")

EC.FORGET_CAMERA()
sent = {}
ReceivedFromProxy(GATEWAY, "PROTECT_STATE", { id = "cam-front", name = "Front Porch", state = "CONNECTED" })
check(
  "PROTECT_STATE with no identity triggers PROTECT_GET_CAMERA",
  #sentTo(GATEWAY, "PROTECT_GET_CAMERA") == 1,
  #sentTo(GATEWAY, "PROTECT_GET_CAMERA")
)
check(
  "Gateway Link shows the ask",
  tostring(props["Gateway Link"]):find("waiting for a reply", 1, true) ~= nil,
  props["Gateway Link"]
)

ReceivedFromProxy(GATEWAY, "PROTECT_CAMERA", {
  id = "cam-front",
  name = "Front Porch",
  mac = "60223263A4D0",
  state = "CONNECTED",
  console_host = "192.168.4.1",
})
check(
  "Gateway Link resolves on the reply",
  tostring(props["Gateway Link"]):find("identified as 'Front Porch'", 1, true) ~= nil,
  props["Gateway Link"]
)

-- ─── [14] The device path ────────────────────────────────────────────────────

print("\n[14] Requests also travel over SendToDevice, to the RIGHT device")

--- The project as Director reports it: the Gateway at 900, a SIBLING camera
--- instance at 901 whose driver file contains "unifi-protect" as a prefix —
--- the trap a substring match would fall into.
function C4:GetDevices()
  return {
    [900] = { deviceName = "UniFi Protect Gateway", driverFileName = "unifi-protect.c4z" },
    [901] = { deviceName = "Other Camera", driverFileName = "unifi-protect-camera.c4z" },
    [77] = { deviceName = "Some Dimmer", driverFileName = "dimmer.c4z" },
  }
end

local deviceSent = {}
function C4:SendToDevice(deviceId, command, params)
  table.insert(deviceSent, { device = deviceId, command = command, params = params })
end

gGatewayDeviceId = nil -- force a re-scan with the stub in place
sent = {}
EC.REFRESH_CAMERA_INFO()

check("binding path still asked", #sentTo(GATEWAY, "PROTECT_GET_CAMERA") == 1)
local toGateway, toSibling = 0, 0
for _, s in ipairs(deviceSent) do
  if s.device == 900 then
    toGateway = toGateway + 1
  end
  if s.device == 901 then
    toSibling = toSibling + 1
  end
end
check("device path asked the Gateway (900)", toGateway == 1, toGateway)
check("the sibling camera driver (901) was NOT mistaken for it", toSibling == 0, toSibling)
check(
  "carrying this driver's id as requester",
  (deviceSent[1] or {}).params ~= nil and deviceSent[1].params.requester == "12345",
  ((deviceSent[1] or {}).params or {}).requester
)

print("\n[15] Replies through the ExecuteCommand door land in the same handlers")

ExecuteCommand("PROTECT_CAMERA", {
  id = "cam-front",
  name = "Device Path Cam",
  mac = "60223263A4D0",
  state = "CONNECTED",
  console_host = "192.168.4.1",
})
check("identity accepted via EC", props["Camera"] == "Device Path Cam", props["Camera"])

fired = {}
ExecuteCommand("PROTECT_EVENT", { kind = "ring" })
check("events accepted via EC", fired[#fired] == "Doorbell Ring", fired[#fired])

-- ─── [16] Streams Offered is the resolution selector ─────────────────────────

print("\n[16] Streams Offered narrows the offer; a missing quality falls back")

-- Refresh the cache with high+medium (no low).
ReceivedFromProxy(GATEWAY, "PROTECT_STREAMS", {
  KEY = "555",
  high = "rtsps://192.168.4.1:7441/HIGHTOKEN?enableSrtp",
  medium = "rtsps://192.168.4.1:7441/MEDTOKEN?enableSrtp",
})

Properties["Streams Offered"] = "Medium only"
sent = {}
OnPropertyChanged("Streams Offered")
check("changing the offer notifies DYNAMIC_URLS_CHANGED", #sentTo(PROXY, "DYNAMIC_URLS_CHANGED") == 1)

local narrowed = tostring(ReceivedFromProxy(PROXY, "GET_STREAM_URLS", {}))
check("only the chosen quality is offered", narrowed:find("MEDTOKEN", 1, true) ~= nil, narrowed)
check("the others are withheld", narrowed:find("HIGHTOKEN", 1, true) == nil, narrowed)

Properties["Streams Offered"] = "Low only"
local fallback = tostring(ReceivedFromProxy(PROXY, "GET_STREAM_URLS", {}))
check(
  "a chosen quality the console never provided falls back to offering all",
  fallback:find("HIGHTOKEN", 1, true) ~= nil and fallback:find("MEDTOKEN", 1, true) ~= nil,
  fallback
)

Properties["Streams Offered"] = "All (client picks)"
local everything = tostring(ReceivedFromProxy(PROXY, "GET_STREAM_URLS", {}))
check(
  "All offers everything the console provided",
  everything:find("HIGHTOKEN", 1, true) ~= nil and everything:find("MEDTOKEN", 1, true) ~= nil,
  everything
)

-- ─── [17] History Agent recording ────────────────────────────────────────────

print("\n[17] Detections land in the History Agent per the History property")

local historyRecords = {}
function C4:RecordHistory(severity, eventType, category, subcategory, metadata)
  table.insert(
    historyRecords,
    { severity = severity, eventType = eventType, category = category, subcategory = subcategory, metadata = metadata }
  )
  return "uuid-" .. #historyRecords
end

historyRecords = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "smart", phase = "start", types = "person" })
check("a person detection is recorded", #historyRecords == 1, #historyRecords)
check("as Person Detected", (historyRecords[1] or {}).eventType == "Person Detected")
check("in the Cameras category", (historyRecords[1] or {}).category == "Cameras")
check("plain form first (no metadata)", (historyRecords[1] or {}).metadata == nil)

historyRecords = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "motion", phase = "start" })
check("plain motion is NOT recorded in Smart detections only", #historyRecords == 0, #historyRecords)

historyRecords = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "audio", phase = "start", types = "alrmSmoke" })
check("an audio alarm is recorded", #historyRecords == 1, #historyRecords)
check("at Warning severity", (historyRecords[1] or {}).severity == "Warning", (historyRecords[1] or {}).severity)

Properties["History"] = "All events"
historyRecords = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "motion", phase = "start" })
check("All events records motion too", #historyRecords == 1, #historyRecords)

Properties["History"] = "Off"
historyRecords = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "smart", phase = "start", types = "person" })
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "ring" })
check("Off records nothing", #historyRecords == 0, #historyRecords)
Properties["History"] = "Smart detections only"

-- A History Agent that stores nothing (nil UUID) must not break events.
function C4:RecordHistory()
  return nil
end
fired = {}
local okNoAgent = pcall(function()
  ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "ring" })
end)
check("a dead History Agent costs nothing", okNoAgent and fired[#fired] == "Doorbell Ring", fired[#fired])

-- ─── [18] Snapshots from the gateway relay ───────────────────────────────────

print("\n[18] A snapshot_url from the Gateway feeds thumbnails and notifications")

ReceivedFromProxy(GATEWAY, "PROTECT_CAMERA", {
  id = "cam-front",
  name = "Front Door",
  mac = "60223263A4D0",
  state = "CONNECTED",
  console_host = "192.168.4.1",
  snapshot_url = "http://192.168.4.2:47800/snapshot/cam-front",
})

check("Snapshots property says available", props["Snapshots"] == "Available via gateway relay", props["Snapshots"])

local snaps = tostring(UIRequest("GET_SNAPSHOT_URLS", {}))
check(
  "GET_SNAPSHOT_URLS answers with the relay URL",
  snaps:find("http://192.168.4.2:47800/snapshot/cam-front", 1, true) ~= nil,
  snaps
)

local attachment = GetNotificationAttachmentURL()
check(
  "notification attachment is the high-quality variant",
  attachment == "http://192.168.4.2:47800/snapshot/cam-front?hq=1",
  attachment
)

-- A state push can update the URL (relay address corrected on the Gateway).
ReceivedFromProxy(GATEWAY, "PROTECT_STATE", {
  id = "cam-front",
  name = "Front Door",
  state = "CONNECTED",
  snapshot_url = "http://10.9.9.9:47800/snapshot/cam-front",
})
check("a state push updates the URL", tostring(UIRequest("GET_SNAPSHOT_URLS", {})):find("10.9.9.9", 1, true) ~= nil)

-- No relay: honest empties, not broken URLs.
ReceivedFromProxy(GATEWAY, "PROTECT_CAMERA", {
  id = "cam-front",
  name = "Front Door",
  mac = "60223263A4D0",
  state = "CONNECTED",
  console_host = "192.168.4.1",
})
check("without a relay, snapshots XML is empty", tostring(UIRequest("GET_SNAPSHOT_URLS", {})) == "<snapshots/>")
check("and the attachment URL is empty", GetNotificationAttachmentURL() == "")
check("Snapshots property back to dash", props["Snapshots"] == "-", props["Snapshots"])

-- ─── [19] Camera controls through the Gateway ────────────────────────────────

print("\n[19] Control commands ride PROTECT_CONTROL; capability gates locally")

-- Identity WITH capability flags: a doorbell that has an LCD and mic.
ReceivedFromProxy(GATEWAY, "PROTECT_CAMERA", {
  id = "cam-front",
  name = "Front Door",
  mac = "60223263A4D0",
  state = "CONNECTED",
  console_host = "192.168.4.1",
  caps = "mic,speaker,led,lcd",
  detects = "person,vehicle",
})
check(
  "Capabilities property shows the flags",
  tostring(props["Capabilities"]):find("lcd", 1, true) ~= nil,
  props["Capabilities"]
)

sent = {}
EC.SET_DOORBELL_MESSAGE({ Message = "Back in 5", Duration = "60" })
local ctrl = sentTo(GATEWAY, "PROTECT_CONTROL")
check("doorbell message sends lcd_message", #ctrl == 1 and (ctrl[1].params or {}).op == "lcd_message")
check("with the text", (ctrl[1].params or {}).text == "Back in 5")

sent = {}
ReceivedFromProxy(GATEWAY, "PROTECT_CONTROL_RESULT", { op = "lcd_message", ok = "true" })
check(
  "result lands in Last Control",
  tostring(props["Last Control"]):find("lcd_message: ok", 1, true) ~= nil,
  props["Last Control"]
)

-- A camera WITHOUT an LCD refuses locally.
ReceivedFromProxy(GATEWAY, "PROTECT_CAMERA", {
  id = "cam-front",
  name = "Front Door",
  mac = "60223263A4D0",
  state = "CONNECTED",
  console_host = "192.168.4.1",
  caps = "mic,led",
})
sent = {}
EC.DO_NOT_DISTURB()
check("no-LCD camera refuses without sending", #sentTo(GATEWAY, "PROTECT_CONTROL") == 0)
check("and says why", tostring(props["Last Control"]):find("unsupported", 1, true) ~= nil, props["Last Control"])

sent = {}
EC.RUN_PTZ_PRESET({ Slot = "2" })
check("PTZ preset sends ptz_goto", (sentTo(GATEWAY, "PROTECT_CONTROL")[1].params or {}).op == "ptz_goto")

print("\n[20] Cooldowns space event FIRING, never the variables")

Properties["Motion Event Cooldown (seconds)"] = "3"
fired = {}
vars.MOTION_DETECTED = nil
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "motion", phase = "start" })
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "motion", phase = "end" })
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "motion", phase = "start" })
local motionFires = 0
for _, name in ipairs(fired) do
  if name == "Motion Detected" then
    motionFires = motionFires + 1
  end
end
check("two rapid motions fire ONCE", motionFires == 1, motionFires)
check("but the variable tracked both", vars.MOTION_DETECTED == "true", vars.MOTION_DETECTED)
Properties["Motion Event Cooldown (seconds)"] = "0"

print("\n[21] Known and unknown people, by touch")

fired = {}
ReceivedFromProxy(
  GATEWAY,
  "PROTECT_EVENT",
  { kind = "identity", method = "fingerprint", known = "true", value = "John Doe" }
)
check("known person fires", fired[#fired] == "Known Person Detected")
check("LAST_PERSON carries the name", vars.LAST_PERSON == "John Doe", vars.LAST_PERSON)

fired = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "identity", method = "nfc", known = "false" })
check("unknown credential fires", fired[#fired] == "Unknown Person Detected")

print("\n[22] Send Snapshot Notification is one command, three effects")

local snapRecords = {}
function C4:RecordHistory(severity, eventType)
  table.insert(snapRecords, { severity = severity, eventType = eventType })
  return "uuid-snap"
end
fired = {}
EC.SEND_SNAPSHOT_NOTIFICATION({ Message = "Package at the door", Severity = "Warning" })
check("event fired", fired[#fired] == "Snapshot Notification")
check("history recorded at the given severity", #snapRecords == 1 and snapRecords[1].severity == "Warning")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
