-- Tests for the sensor, light and viewport child drivers.
--
-- All three share the camera child's world: no credentials, no HTTP — just
-- the Gateway protocol over two transports. One file drives all three
-- because their per-driver surface is small; each gets its own section and
-- its own isolated load (fresh globals per driver via dofile in sequence —
-- the drivers overwrite the same global entry points, so each section runs
-- immediately after its own load).
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

local deviceSent = {}
function C4:SendToDevice(deviceId, command, params)
  table.insert(deviceSent, { device = deviceId, command = command, params = params })
end

local props = {}
function C4:UpdateProperty(name, value)
  props[name] = value
  if Properties[name] ~= nil then
    Properties[name] = value
  end
end

local fired = {}
function C4:FireEvent(name)
  table.insert(fired, name)
end
local vars = {}
function C4:SetVariable(name, value)
  vars[name] = value
end

function C4:GetVersionInfo()
  return { version = "4.0.0" }
end
function C4:GetDevices()
  return { [900] = { deviceName = "Gateway", driverFileName = "unifi-protect.c4z" } }
end

local GATEWAY = 1

-- ─── Sensor ──────────────────────────────────────────────────────────────────

print("\n[1] Sensor: identity, contact bindings, thresholds")

function C4:GetDriverConfigInfo(key)
  return ({ model = "UniFi Protect Sensor", version = "1.0.0", minimum_os_version = "3.3.2" })[key]
end
Properties = {
  ["Sensor"] = "Not bound",
  ["Sensor State"] = "UNKNOWN",
  ["Gateway Link"] = "-",
  ["Mount Type"] = "-",
  ["Contact"] = "-",
  ["Temperature"] = "-",
  ["Humidity"] = "-",
  ["Light Level"] = "-",
  ["Battery"] = "-",
  ["Temperature High Threshold"] = "30",
  ["Temperature Low Threshold"] = "",
  ["Humidity High Threshold"] = "",
  ["Humidity Low Threshold"] = "",
  ["Driver Status"] = "Starting",
  ["Driver Version"] = "unknown",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
}
dofile("drivers/unifi-protect-sensor/driver.lua")
OnDriverInit()
OnDriverLateInit()

check("identity asked over the binding", #sentTo(GATEWAY, "PROTECT_GET_DEVICE") >= 1)
local askedDevice = false
for _, s in ipairs(deviceSent) do
  if s.device == 900 and s.command == "PROTECT_GET_DEVICE" then
    askedDevice = true
  end
end
check("and over the device path", askedDevice)

ReceivedFromProxy(GATEWAY, "PROTECT_DEVICE", {
  id = "sen-1",
  name = "Garage Door",
  state = "CONNECTED",
  mount = "garage",
  battery = "88",
  temperature = "22.5",
  opened = "false",
})
check("named after the sensor", props["Sensor"] == "Garage Door", props["Sensor"])
check("battery published", vars.BATTERY == "88", vars.BATTERY)
check("contact CLOSED pushed to the contact binding", #sentTo(200, "CLOSED") == 1)

sent = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "opened" })
check(
  "open event → OPENED on the binding + Composer event",
  #sentTo(200, "OPENED") == 1 and fired[#fired] == "Contact Opened"
)
check("CONTACT_STATE variable", vars.CONTACT_STATE == "open", vars.CONTACT_STATE)

sent = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "motion", phase = "start" })
check("motion → CLOSED on the motion binding", #sentTo(201, "CLOSED") == 1)
check("Motion Detected fired", fired[#fired] == "Motion Detected")

fired = {}
ReceivedFromProxy(
  GATEWAY,
  "PROTECT_STATE",
  { id = "sen-1", name = "Garage Door", state = "CONNECTED", temperature = "28" }
)
check("below threshold: nothing fires", #fired == 0, #fired)
ReceivedFromProxy(
  GATEWAY,
  "PROTECT_STATE",
  { id = "sen-1", name = "Garage Door", state = "CONNECTED", temperature = "31" }
)
check("crossing above fires once", fired[#fired] == "Temperature Above Threshold")
fired = {}
ReceivedFromProxy(
  GATEWAY,
  "PROTECT_STATE",
  { id = "sen-1", name = "Garage Door", state = "CONNECTED", temperature = "32" }
)
check("staying above does not re-fire", #fired == 0, #fired)

fired = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "leak", phase = "start" })
check("water leak fires", fired[#fired] == "Water Leak Detected")

-- ─── Light ───────────────────────────────────────────────────────────────────

print("\n[2] Light: control ops out, state and motion in")

function C4:GetDriverConfigInfo(key)
  return ({ model = "UniFi Protect Light", version = "1.0.0", minimum_os_version = "3.3.2" })[key]
end
Properties = {
  ["Floodlight"] = "Not bound",
  ["Light State"] = "UNKNOWN",
  ["Gateway Link"] = "-",
  ["Light"] = "-",
  ["Light Mode"] = "-",
  ["Last Control"] = "-",
  ["Driver Status"] = "Starting",
  ["Driver Version"] = "unknown",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
}
store = {}
dofile("drivers/unifi-protect-light/driver.lua")
OnDriverInit()
OnDriverLateInit()

ReceivedFromProxy(
  GATEWAY,
  "PROTECT_DEVICE",
  { id = "lt-1", name = "Backyard Flood", state = "CONNECTED", on = "false" }
)
check("light identified", props["Floodlight"] == "Backyard Flood", props["Floodlight"])

sent = {}
deviceSent = {}
EC.LIGHT_ON()
local ctrl = sentTo(GATEWAY, "PROTECT_CONTROL")
check("Light On sends light_force over the binding", #ctrl == 1 and (ctrl[1].params or {}).op == "light_force")
check("with on=true", (ctrl[1].params or {}).on == "true")
local viaDevice = false
for _, s in ipairs(deviceSent) do
  if s.device == 900 and s.command == "PROTECT_CONTROL" then
    viaDevice = true
  end
end
check("and over the device path", viaDevice)

fired = {}
ReceivedFromProxy(GATEWAY, "PROTECT_STATE", { id = "lt-1", name = "Backyard Flood", state = "CONNECTED", on = "true" })
check("state push flips LIGHT_ON and fires Light On", vars.LIGHT_ON == "true" and fired[#fired] == "Light On")

fired = {}
ReceivedFromProxy(GATEWAY, "PROTECT_EVENT", { kind = "motion", phase = "start" })
check("floodlight motion fires", fired[#fired] == "Motion Detected")

-- ─── Viewport ────────────────────────────────────────────────────────────────

print("\n[3] Viewport: views, stepping, and the temporary show with restore")

function C4:GetDriverConfigInfo(key)
  return ({ model = "UniFi Protect Viewport", version = "1.0.0", minimum_os_version = "3.3.2" })[key]
end
Properties = {
  ["Viewport"] = "Not bound",
  ["Viewport State"] = "UNKNOWN",
  ["Gateway Link"] = "-",
  ["Current View"] = "-",
  ["Available Views"] = "-",
  ["Last Control"] = "-",
  ["Driver Status"] = "Starting",
  ["Driver Version"] = "unknown",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
}
store = {}
dofile("drivers/unifi-protect-viewport/driver.lua")
OnDriverInit()
OnDriverLateInit()

-- Capture timers AFTER load so the driver's SetTimer calls land here.
local timers = {}
function SetTimer(name, ms, callback)
  timers[name] = { ms = ms, callback = callback }
end
function CancelTimer(name)
  timers[name] = nil
end

ReceivedFromProxy(GATEWAY, "PROTECT_DEVICE", {
  id = "vp-1",
  name = "Rack Viewport",
  state = "CONNECTED",
  liveview = "lv-1",
  liveviews = "lv-1=All Cameras;lv-2=Front Door;lv-3=Perimeter",
})
check("current view named", props["Current View"] == "All Cameras", props["Current View"])
check("available views listed", tostring(props["Available Views"]):find("Perimeter", 1, true) ~= nil)

sent = {}
EC.SET_LIVE_VIEW({ View = "Perimeter" })
local vctrl = sentTo(GATEWAY, "PROTECT_CONTROL")
check("Set Live View sends viewer_liveview", #vctrl == 1 and (vctrl[1].params or {}).op == "viewer_liveview")
check("carrying the requested view", (vctrl[1].params or {}).liveview == "Perimeter")

sent = {}
EC.NEXT_LIVE_VIEW()
check(
  "Next steps from the CURRENT view (lv-1 → lv-2)",
  (sentTo(GATEWAY, "PROTECT_CONTROL")[1].params or {}).liveview == "lv-2",
  (sentTo(GATEWAY, "PROTECT_CONTROL")[1].params or {}).liveview
)

sent = {}
EC.SHOW_VIEW_TEMPORARILY({ View = "Front Door", Seconds = "20" })
check("temporary show sets the view", (sentTo(GATEWAY, "PROTECT_CONTROL")[1].params or {}).liveview == "Front Door")
check(
  "restore timer armed for 20s",
  timers["ProtectViewportRestore"] ~= nil and timers["ProtectViewportRestore"].ms == 20 * ONE_SECOND
)

-- A second temporary show during the window keeps the ORIGINAL restore.
sent = {}
EC.SHOW_VIEW_TEMPORARILY({ View = "Perimeter", Seconds = "20" })
sent = {}
timers["ProtectViewportRestore"].callback()
check(
  "restore returns to the ORIGINAL view (lv-1), not the interim one",
  (sentTo(GATEWAY, "PROTECT_CONTROL")[1].params or {}).liveview == "lv-1",
  (sentTo(GATEWAY, "PROTECT_CONTROL")[1].params or {}).liveview
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
