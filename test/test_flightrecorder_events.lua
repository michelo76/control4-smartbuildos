-- Flight Recorder DRIVER, the event-capture half and what the merge with the
-- former Event Tracer driver added, under the shim with a scripted Agent:
-- zero-config subscription, registration + licence, the "3 am hall light"
-- scenario (events around a marker, in order, through the pipeline), a
-- chattering contact (storm), licence enforcement, a project change, Studio
-- commands, Agent restart, persistence, removal. Then the parts only one
-- driver can do: ONE history with device events, variable changes and trace
-- steps in the order they happened, Print Last Trace, a snapshot that
-- carries that history, and one pause and one licence rule for both halves.
--
-- The variable/trace/snapshot half on its own: test_flightrecorder_driver.lua.
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
-- The driver's clock follows the fake one (sub-second).
FLIGHT_RECORDER_NOW = function()
  return base + clock.now / 1000
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

-- ── a small built-in catalogue instead of the generated one ─────────────────
package.preload["tracer.catalog_data"] = function()
  return {
    ["keypad.c4z"] = { [1] = "Top Button Pushed", [2] = "Bottom Button Pushed", [3] = "Top Button Released" },
    ["contact.c4z"] = { [1] = "Opened", [2] = "Closed" },
    ["smartbuildos.c4z"] = { [1] = "Connected", [2] = "Disconnected" },
  }
end

-- ── fake Director ───────────────────────────────────────────────────────────
local AGENT_ID = 50
local SELF_ID = 12345
local agentPresent = false
local sent = {}
local fired = {}
local subscriptions = {}
local listeners = {}
local variables = {
  [12] = { ["1001"] = { name = "LIGHT_LEVEL", value = "75" } },
  [20] = { ["2001"] = { name = "ContactState", value = "Closed" } },
}
local regCalls, unregCalls = 0, 0
local props = {}
local vars = {}
local projectXml = nil
local devices = {
  [12] = { deviceName = "Hall Keypad", driverFileName = "keypad.c4z", roomId = 3, roomName = "Hall" },
  [20] = { deviceName = "Front Door", driverFileName = "contact.c4z", roomId = 1, roomName = "Entry" },
  [30] = { deviceName = "Mystery Sensor", driverFileName = "mystery.c4z", roomId = 7, roomName = "Garage" },
  [SELF_ID] = { deviceName = "Flight Recorder", driverFileName = "smartbuildos-flight-recorder.c4z" },
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
C4.GetProjectItems = function()
  return projectXml
end
C4.GetDeviceDisplayName = function(_, id)
  local d = C4.GetDevices()[tonumber(id)]
  return d and d.deviceName or nil
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "Flight Recorder"
  end
  return "20261109.000000"
end
C4.SendToDevice = function(_, device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
end
C4.FireEventByID = function(_, id)
  fired[#fired + 1] = id
end
C4.FireEvent = function() end
C4.RegisterDeviceEvent = function(_, d, e)
  regCalls = regCalls + 1
  subscriptions[d .. ":" .. e] = true
end
C4.UnregisterDeviceEvent = function(_, d, e)
  unregCalls = unregCalls + 1
  subscriptions[d .. ":" .. e] = nil
end
C4.GetDeviceVariables = function(_, id)
  return variables[tonumber(id)]
end
C4.RegisterVariableListener = function(_, d, v)
  listeners[d .. ":" .. v] = true
end
C4.UnregisterVariableListener = function(_, d, v)
  listeners[d .. ":" .. v] = nil
end
C4.SetVariable = function(_, name, value)
  vars[name] = value
end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.UpdateProperty = function(_, name, value)
  -- Director keeps Properties in step with what a driver paints; the shared
  -- UpdateProperty wrapper relies on that to skip unchanged values.
  props[name] = value
  Properties[name] = value
end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-flight-recorder/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    Properties[name] = default
  end
end

dofile("drivers/smartbuildos-flight-recorder/driver.lua")

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
local function lastSent(command)
  local list = sentOf(command)
  return list[#list]
end
local function eventsSent()
  local out = {}
  for _, s in ipairs(sent) do
    if s.command == "SBOS_MODULE_EVENTS" then
      for _, e in ipairs(JSON:decode(s.params.events)) do
        out[#out + 1] = e
      end
    end
  end
  return out
end
local function eventsOfType(tp)
  local out = {}
  for _, e in ipairs(eventsSent()) do
    if e.event_type == tp then
      out[#out + 1] = e
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
  for _ in pairs(subscriptions) do
    n = n + 1
  end
  return n
end
local TOKEN = "tok-fr"
local function agentRegisters(ok, extra)
  local reply = {
    module_id = "flight_recorder",
    instance_id = tostring(SELF_ID),
    ok = ok and "true" or "false",
    token = TOKEN,
    protocol = "1",
    paired = "true",
    connected = "true",
    installation_id = "sys-1",
    boot_id = "boot-1",
    agent_version = "20261109.1",
  }
  for k, v in pairs(extra or {}) do
    reply[k] = v
  end
  EC.SBOS_MODULE_REGISTERED(reply)
end
local function ackAllFrames()
  local again = true
  while again do
    again = false
    for _, s in ipairs(sent) do
      if s.command == "SBOS_MODULE_EVENTS" and not s.acked then
        s.acked = true
        again = true
        EC.SBOS_MODULE_EVENTS_ACK({
          batch_id = s.params.batch_id,
          accepted = tostring(#JSON:decode(s.params.events)),
          queue = JSON:encode({ depth = 1, dropped = 0 }),
        })
      end
    end
  end
end

print("[1] starts without an Agent: zero-config capture, waiting for the Agent")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", props["Driver Status"] == "Online")
check("subscribed to every catalogued event: 3 + 2 (self and unknown skipped)", countSubs() == 5, countSubs())
check("self never subscribed", subscriptions[SELF_ID .. ":1"] == nil)
check(
  "coverage line",
  prop("Event Coverage"):find("5 subscriptions on 2 of 4 devices") ~= nil
    and prop("Event Coverage"):find("1 unknown") ~= nil,
  prop("Event Coverage")
)
check(
  "catalogue line shows the tiers",
  prop("Event Catalogue"):find("built%-in: 3 driver%(s%) → 5 subs") ~= nil,
  prop("Event Catalogue")
)
check(
  "status: capturing locally while no Agent",
  prop("Recording Status"):find("^recording_local") ~= nil,
  prop("Recording Status")
)
check("conditional RECORDING_ACTIVE true even without an Agent", TC.RECORDING_ACTIVE() == true)
check("conditional AGENT_READY false", TC.AGENT_READY() == false)
check("no register frame sent (no Agent)", #sentOf("SBOS_MODULE_REGISTER") == 0)
check("licence shows no Agent", prop("License Status") == "No SmartBuildOS Agent Found", prop("License Status"))

print("[2] events are captured locally before any Agent")
OnDeviceEvent(12, 1)
advance(2500)
check(
  "ring has it and Last Event paints",
  prop("Last Event"):find("Hall Keypad: Top Button Pushed", 1, true) ~= nil,
  prop("Last Event")
)
check("LAST_EVENT variable", vars["LAST_EVENT"] == "Hall Keypad: Top Button Pushed")
check("Events Captured 1", prop("Events Captured") == "1")
check(
  "an event nobody subscribed is ignored",
  (function()
    OnDeviceEvent(30, 1)
    return prop("Events Captured") == "1"
  end)()
)

print("[3] the Agent appears: registration round trip + licence")
agentPresent = true
advance(31000)
local reg = lastSent("SBOS_MODULE_REGISTER")
check("register frame to the Agent", reg ~= nil and reg.device == AGENT_ID)
check(
  "frame carries the contract",
  reg.params.module_id == "flight_recorder"
    and reg.params.entitlements == "SBOS_FLIGHT_RECORDER"
    and reg.params.singleton == "true"
    and reg.params.event_types == "observation.,trace.,recorder.,snapshot.,capture.,tracer."
    and reg.params.commands:find("apply_config") ~= nil
    and reg.params.commands:find("apply_policy") ~= nil,
  reg.params.event_types
)
agentRegisters(true)
check("registered + ready", props["Agent Connection"] == "ready" and TC.AGENT_READY() == true)
check("Agent Connected fired", hasFired(8))
check("status now plain recording", prop("Recording Status") == "recording", prop("Recording Status"))
check(
  "licence registered with the Agent under the recorder's one SKU",
  lastSent("SBOS_REGISTER_DRIVER") ~= nil and lastSent("SBOS_REGISTER_DRIVER").params.sku == "SBOS_FLIGHT_RECORDER"
)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_FLIGHT_RECORDER",
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "subscription",
  registered = "true",
  subscription_tier = "Professional",
  company_name = "Skynet AV",
})
check("licence status painted", prop("License Status"):find("Licensed") ~= nil, prop("License Status"))
advance(5500)
check(
  "the Agent's own device is re-planned in a few seconds: 7 subscriptions",
  countSubs() == 7 and subscriptions["50:1"],
  countSubs()
)
check(
  "tier and company painted",
  prop("Subscription Tier") == "Professional" and prop("SmartBuildOS Company") == "Skynet AV"
)
advance(2500)
check(
  "the pre-Agent event and the applied summary were uploaded",
  #eventsOfType("capture.event") == 1 and #eventsOfType("tracer.applied") >= 1
)
ackAllFrames()
check("Last Upload stamped", prop("Last Upload") ~= "never")

print("[4] 3 am: a marker, then the events around it, in order")
sent = {}
EC.RECORD_EVENT({ NAME = "Good Night", DETAIL = "from Hall keypad", DEVICE = "12" })
OnDeviceEvent(12, 2)
OnDeviceEvent(20, 2)
advance(500)
OnDeviceEvent(12, 3)
advance(2500)
local evs = eventsSent()
local order = {}
for _, e in ipairs(evs) do
  order[#order + 1] = e.event_type .. ":" .. tostring(e.label)
end
check(
  "event order through the pipeline",
  table.concat(order, " | ")
    == "observation.programmed:Good Night | capture.event:Hall Keypad: Bottom Button Pushed | capture.event:Front Door: Closed | capture.event:Hall Keypad: Top Button Released",
  table.concat(order, " | ")
)
check(
  "the marker is a request recorded by programming: unreviewed text",
  evs[1].evidence_source == "requested" and evs[1].quality == "unreviewed_text" and evs[1].device_id == 12
)
check(
  "events are observed, confirmed, with room",
  evs[3].evidence_source == "observed" and evs[3].quality == "confirmed" and evs[3].room_id == 1
)
check(
  "payload names the driver and event id",
  evs[3].payload.driver == "contact.c4z" and evs[3].payload.event_id == 2 and evs[3].payload.tier == "builtin"
)
check(
  "sequence strictly increasing",
  evs[1].sequence < evs[2].sequence and evs[2].sequence < evs[3].sequence and evs[3].sequence < evs[4].sequence
)
check(
  "module identity on every envelope",
  evs[4].module_id == "flight_recorder" and evs[4].source_driver_instance_id == tostring(SELF_ID)
)
ackAllFrames()

print("[5] a chattering contact: one storm, then counting")
sent = {}
fired = {}
for _ = 1, 50 do
  OnDeviceEvent(20, 1)
end
advance(2500)
check("one tracer.storm uploaded", #eventsOfType("tracer.storm") == 1)
check("30 capture.events then suppression", #eventsOfType("capture.event") == 30, #eventsOfType("capture.event"))
check("Event Storm Detected fired once", hasFired(10) and (function()
  local n = 0
  for _, f in ipairs(fired) do
    if f == 10 then
      n = n + 1
    end
  end
  return n == 1
end)())
check(
  "Active Storms painted and conditional true",
  prop("Active Storms"):find("Front Door: Opened %(50%)") ~= nil and TC.STORM_ACTIVE() == true,
  prop("Active Storms")
)
ackAllFrames()
sent = {}
advance(95000) -- past the minute AND a 30 s tick
check(
  "tick ended the storm with totals",
  #eventsOfType("tracer.storm_ended") == 1 and eventsOfType("tracer.storm_ended")[1].payload.suppressed == 20
)
check("Event Storm Ended fired", hasFired(11) and TC.STORM_ACTIVE() == false)
ackAllFrames()

print("[6] Composer settings change the policy without a Studio round trip")
sent = {}
regCalls, unregCalls = 0, 0
Properties["Exclude Device IDs"] = "20"
OnPropertyChanged("Exclude Device IDs")
check(
  "the excluded device's two subscriptions were released, nothing else touched",
  unregCalls == 2 and regCalls == 0 and subscriptions["20:1"] == nil and subscriptions["12:1"] and countSubs() == 5,
  countSubs()
)
check(
  "coverage says excluded (the device and self)",
  prop("Event Coverage"):find("2 excluded") ~= nil,
  prop("Event Coverage")
)
Properties["Exclude Device IDs"] = ""
OnPropertyChanged("Exclude Device IDs")
check("back to 7 (the Agent's own two events are captured too)", countSubs() == 7, countSubs())
Properties["Storm Threshold"] = "abc"
OnPropertyChanged("Storm Threshold")
check(
  "a bad setting is ignored and named, capture continues",
  prop("Last Recording Error"):find("setting ignored: storm_threshold") ~= nil and countSubs() == 7,
  prop("Last Recording Error")
)
Properties["Storm Threshold"] = "30"
OnPropertyChanged("Storm Threshold")
check("error clears", prop("Last Recording Error") == "none", prop("Last Recording Error"))

print("[7] probe + learn on the unknown driver")
sent = {}
Properties["Probe Unknown Drivers"] = "On"
Properties["Probe Range"] = "8"
OnPropertyChanged("Probe Unknown Drivers")
check(
  "8 probe subscriptions on the mystery device",
  countSubs() == 15 and subscriptions["30:8"] and not subscriptions["30:9"],
  countSubs()
)
fired = {}
OnDeviceEvent(30, 5)
advance(6000)
check(
  "learned, persisted, event fired",
  persisted["fr_learned_v1"] ~= nil and persisted["fr_learned_v1"]["mystery.c4z"][1] == 5 and hasFired(12)
)
check(
  "capture carries unknown quality and the placeholder name",
  eventsOfType("capture.event")[1].quality == "unknown"
    and eventsOfType("capture.event")[1].label == "Mystery Sensor: Event 5"
)
Properties["Probe Unknown Drivers"] = "Off"
OnPropertyChanged("Probe Unknown Drivers")
check("probe off keeps the learned id only", countSubs() == 8 and subscriptions["30:5"], countSubs())
check(
  "catalogue line counts the learned tier",
  prop("Event Catalogue"):find("learned: 1 event%(s%) → 1 subs") ~= nil,
  prop("Event Catalogue")
)
ackAllFrames()

print("[8] project catalogue tier (the bench probe) names it")
projectXml =
  "<item><id>1</id><itemdata><scale>F</scale></itemdata><subitems><item><id>30</id><name>Mystery Sensor</name><type>6</type><itemdata><driver>mystery.c4z</driver><events><event><id>5</id><name>Tamper</name></event><event><id>6</id><name>Low Battery</name></event></events></itemdata></item></subitems></item>"
EC.REAPPLY()
check(
  "project tier adds the second event and names the first",
  countSubs() == 9
    and subscriptions["30:6"]
    and prop("Event Catalogue"):find("project: 1 device%(s%) → 2 subs") ~= nil,
  prop("Event Catalogue")
)
sent = {}
OnDeviceEvent(30, 5)
advance(2500)
check(
  "learned id now carries its project name",
  eventsOfType("capture.event")[1].label == "Mystery Sensor: Tamper"
    and eventsOfType("capture.event")[1].quality == "confirmed"
)
projectXml = nil
Properties["Read Events From Project"] = "Off"
OnPropertyChanged("Read Events From Project")
check("project tier off falls back to learned", countSubs() == 8, countSubs())
ackAllFrames()

print("[9] a project change re-plans after a quiet period")
devices[40] = { deviceName = "Garage Door", driverFileName = "contact.c4z", roomId = 7, roomName = "Garage" }
EC.SBOS_MODULE_AGENT_EVENT({ name = "project_changed", detail = "{}" })
check("not yet (debounced)", subscriptions["40:1"] == nil)
advance(5500)
check("new device covered", subscriptions["40:1"] and subscriptions["40:2"] and countSubs() == 10, countSubs())
devices[40] = nil
EC.SBOS_MODULE_AGENT_EVENT({ name = "project_changed", detail = "{}" })
advance(5500)
check("removed device released", subscriptions["40:1"] == nil and countSubs() == 8, countSubs())

print("[10] Studio commands through the Agent")
sent = {}
EC.SBOS_MODULE_COMMAND({ token = "wrong", request_id = "r0", command = "pause", args = "{}" })
check("a command without our token is ignored", #sentOf("SBOS_MODULE_COMMAND_RESULT") == 0)
EC.SBOS_MODULE_COMMAND({
  token = TOKEN,
  request_id = "r1",
  command = "pause",
  args = JSON:encode({ reason = "maintenance" }),
})
local results = sentOf("SBOS_MODULE_COMMAND_RESULT")
check(
  "pause: Accepted → Executing → Completed",
  #results == 3 and results[3].params.state == "Completed" and results[3].params.request_id == "r1",
  results[3] and results[3].params.state
)
check(
  "paused: everything released, persisted",
  countSubs() == 0 and persisted["fr_paused"] == true and prop("Recording Status") == "paused"
)
check("Recording Degraded fired on the transition", hasFired(1))
EC.SBOS_MODULE_COMMAND({ token = TOKEN, request_id = "r2", command = "resume", args = "{}" })
check(
  "resume rebuilds",
  countSubs() == 8 and persisted["fr_paused"] == false and prop("Recording Status") == "recording"
)
EC.SBOS_MODULE_COMMAND({
  token = TOKEN,
  request_id = "r3",
  command = "apply_policy",
  args = JSON:encode({ policy = { exclude_driver_files = "contact.c4z", storm_threshold = 10 } }),
})
check(
  "apply_policy from Studio applied",
  lastSent("SBOS_MODULE_COMMAND_RESULT").params.state == "Completed"
    and subscriptions["20:1"] == nil
    and countSubs() == 6,
  countSubs()
)
EC.SBOS_MODULE_COMMAND({ token = TOKEN, request_id = "r4", command = "unknown_thing", args = "{}" })
check(
  "unknown command fails by name",
  lastSent("SBOS_MODULE_COMMAND_RESULT").params.state == "Failed"
    and lastSent("SBOS_MODULE_COMMAND_RESULT").params.detail:find("unknown_thing") ~= nil
)
check(
  "the Studio policy is written into the Composer properties (one truth)",
  prop("Exclude Driver Files") == "contact.c4z" and prop("Storm Threshold") == "10",
  tostring(prop("Exclude Driver Files")) .. " / " .. tostring(prop("Storm Threshold"))
)
check(
  "keys Studio did not send keep their values",
  prop("Event Capture") == "On" and prop("Max Subscriptions") == "1000" and prop("Probe Unknown Drivers") == "Off",
  tostring(prop("Max Subscriptions"))
)
advance(2500)
ackAllFrames()
local appliedEvents = eventsOfType("tracer.applied")
local appliedReport = appliedEvents[#appliedEvents] and appliedEvents[#appliedEvents].payload.policy or nil
check(
  "tracer.applied reports the running policy for Studio",
  appliedReport ~= nil
    and appliedReport.storm_threshold == 10
    and appliedReport.exclude_driver_files[1] == "contact.c4z"
    and appliedReport.exclude_driver_files_total == 1
    and appliedReport.exclude_device_ids_total == 0,
  JSON:encode(appliedEvents[#appliedEvents] and appliedEvents[#appliedEvents].payload or {})
)
EC.SBOS_MODULE_COMMAND({
  token = TOKEN,
  request_id = "r3b",
  command = "apply_policy",
  args = JSON:encode({ policy = { storm_threshold = 99999 } }),
})
check(
  "an invalid Studio field fails the whole command and changes nothing",
  lastSent("SBOS_MODULE_COMMAND_RESULT").params.state == "Failed"
    and lastSent("SBOS_MODULE_COMMAND_RESULT").params.detail:find("storm_threshold", 1, true) ~= nil
    and prop("Storm Threshold") == "10"
    and countSubs() == 6,
  lastSent("SBOS_MODULE_COMMAND_RESULT").params.detail
)
-- A reload rebuilds from the properties: the Studio policy is still there.
check(
  "a re-apply from the Composer properties keeps the Studio policy",
  (function()
    OnPropertyChanged("Storm Threshold")
    return countSubs() == 6
  end)(),
  countSubs()
)
-- Composer edits win afterwards: clearing the exclusion restores full coverage.
Properties["Exclude Driver Files"] = ""
Properties["Storm Threshold"] = "30"
OnPropertyChanged("Exclude Driver Files")
check("a later Composer edit wins over the Studio policy", countSubs() == 8, countSubs())

print("[11] licence enforcement halts capture; uncertainty never does")
fired = {}
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_FLIGHT_RECORDER",
  status = "CLOUD_VALIDATION_REQUIRED",
  registered = "true",
  enforcement = "enforce",
})
check(
  "an uncertain status with enforcement on changes nothing",
  countSubs() == 8 and prop("Recording Status") == "recording"
)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_FLIGHT_RECORDER",
  status = "NOT_ENTITLED",
  registered = "true",
  enforcement = "enforce",
})
check(
  "definitive denial + enforce: subscriptions released, status unlicensed",
  countSubs() == 0 and prop("Recording Status") == "unlicensed",
  prop("Recording Status")
)
check("Recording Degraded fired", hasFired(1))
check("licence label says read-only", prop("License Status"):find("read%-only") ~= nil, prop("License Status"))
check(
  "OnDeviceEvent while halted captures nothing",
  (function()
    local before = prop("Events Captured")
    OnDeviceEvent(12, 1)
    advance(2500)
    return prop("Events Captured") == before
  end)()
)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_FLIGHT_RECORDER",
  status = "NOT_ENTITLED",
  registered = "true",
  enforcement = "observe",
})
check("the same denial in observe mode resumes capture", countSubs() == 8 and prop("Recording Status") == "recording")
EC.SBOS_ENTITLEMENT({ sku = "SBOS_FLIGHT_RECORDER", status = "AUTHORIZED_SUBSCRIPTION", registered = "true" })

print("[12] the Agent restarts: re-registration without Composer")
sent = {}
EC.SBOS_MODULE_AGENT_HELLO({})
check("register frame resent on hello", #sentOf("SBOS_MODULE_REGISTER") == 1)
agentRegisters(true, { token = "tok-2" })
check("ready again", props["Agent Connection"] == "ready")

print("[13] persistence across a reload: history and sequence survive")
OnDeviceEvent(12, 1)
advance(31000) -- the tick checkpoints the dirty ring
check("ring checkpointed", persisted["fr_history_v1"] ~= nil and #persisted["fr_history_v1"].entries > 0)
local seqBefore = persisted["fr_history_v1"].seq
OnDriverDestroyed()
check("destroy released everything and unregistered", countSubs() == 0 and lastSent("SBOS_MODULE_UNREGISTER") ~= nil)
sent = {}
subscriptions = {}
OnDriverInit()
OnDriverLateInit("DIT_UPDATING")
agentRegisters(true, { token = "tok-3" })
check(
  "restored history continues the sequence",
  prop("Last Event"):find("Hall Keypad: Top Button Pushed", 1, true) ~= nil
)
OnDeviceEvent(12, 2)
advance(2500)
check(
  "next entry's seq follows the restored one",
  (function()
    for _, e in ipairs(eventsOfType("capture.event")) do
      -- A reload writes its own notes (the configuration applied) first.
      if e.payload.seq > seqBefore and e.payload.seq <= seqBefore + 3 then
        return true
      end
    end
    return false
  end)()
)
check("learned tier survived", subscriptions["30:5"] ~= nil)

print("[14] Print actions do not throw")
local okP = pcall(function()
  EC.PRINT_STATUS()
  EC.PRINT_RECENT()
  EC.PRINT_COVERAGE()
  EC.PRINT_SOURCES()
  EC.PRINT_LAST_TRACE()
  Properties["Inspect Device ID"] = "12"
  EC.PRINT_DEVICE()
  Properties["Inspect Device ID"] = ""
  EC.PRINT_DEVICE()
end)
check("print actions run", okP)
EC.CLEAR_HISTORY()
check("history cleared", prop("Last Event"):find("cleared") ~= nil)
EC.FORGET_LEARNED()
check(
  "learned forgotten → mystery device unknown again",
  subscriptions["30:5"] == nil and persisted["fr_learned_v1"]["mystery.c4z"] == nil
)

-- What a Print action writes to the Lua tab, one string per line.
local function printed(action)
  local realPrint = print
  local lines = {}
  print = function(...)
    local parts = {}
    for _, part in ipairs({ ... }) do
      parts[#parts + 1] = tostring(part)
    end
    lines[#lines + 1] = table.concat(parts, " ")
  end
  local ok, err = pcall(action)
  print = realPrint
  assert(ok, err)
  return lines
end
local function lineWith(lines, text, from)
  for i = from or 1, #lines do
    if lines[i]:find(text, 1, true) ~= nil then
      return i
    end
  end
  return nil
end

print("[15] one history: a routine, the device events and a variable change, in the order they happened")
ackAllFrames()
sent = {}
EC.SBOS_MODULE_COMMAND({
  token = "tok-3",
  request_id = "h1",
  command = "apply_config",
  args = JSON:encode({
    version = 2,
    config = {
      version = 2,
      sources = { { kind = "device_variable", device_id = 12, variable = "LIGHT_LEVEL", label = "Hall light level" } },
    },
  }),
})
check(
  "a variable source is listening beside event capture",
  lastSent("SBOS_MODULE_COMMAND_RESULT").params.state == "Completed" and listeners["12:1001"] and countSubs() > 0,
  lastSent("SBOS_MODULE_COMMAND_RESULT").params.detail
)
advance(3000)
check(
  "the first read is in the history and says it is not a change",
  lineWith(printed(EC.PRINT_RECENT), "Hall / Hall Keypad: LIGHT_LEVEL = 75 (first read, not a change)") ~= nil,
  table.concat(printed(EC.PRINT_RECENT), "\n")
)
EC.CLEAR_HISTORY()
OnDeviceEvent(12, 1)
advance(200)
EC.START_TRACE({ NAME = "Good Night", CHANNEL = "night" })
EC.RECORD_TRACE_STEP({ MESSAGE = "Hall light off", CHANNEL = "night", DEVICE = "12" })
advance(200)
OnWatchedVariableChanged(12, 1001, "0")
advance(3000)
OnDeviceEvent(20, 2)
EC.RECORD_TRACE_DECISION({ CONDITION = "Front door closed", OUTCOME = "yes", CHANNEL = "night" })
EC.RECORD_EVENT({ NAME = "Doors checked", CHANNEL = "night" })
EC.COMPLETE_TRACE({ NOTE = "all off", CHANNEL = "night" })
advance(2500)
local history = printed(EC.PRINT_RECENT)
local expected = {
  "Hall / Hall Keypad: Top Button Pushed",
  "TRACE night  start  Good Night",
  "TRACE night  step 1  Hall light off  [Hall Keypad]",
  "Hall / Hall Keypad: LIGHT_LEVEL 75 → 0",
  "Entry / Front Door: Closed",
  "TRACE night  decision 2  Front door closed → yes",
  "MARK  Doors checked",
  "TRACE night  end  completed; all off; 2 step(s)",
}
local at, inOrder = 0, true
for _, text in ipairs(expected) do
  local found = lineWith(history, text, at + 1)
  if found == nil then
    inOrder = false
    break
  end
  at = found
end
check("eight entries of four kinds, in the order they happened", inOrder, table.concat(history, "\n"))
check("the header counts what is held", history[1]:find("last 8 of 8 held", 1, true) ~= nil, history[1])
check(
  "Last Trace paints the routine's outcome",
  prop("Last Trace"):find("Good Night: completed (2 step(s)", 1, true) ~= nil,
  prop("Last Trace")
)
check("Trace Completed fired", hasFired(6))
check(
  "nothing in the history was uploaded twice: one event per entry",
  #eventsOfType("capture.event") == 2
    and #eventsOfType("observation.change") == 1
    and #eventsOfType("trace.start") == 1
    and #eventsOfType("capture.mark") == 0,
  #eventsOfType("capture.event")
)

print("[16] Print Last Trace: the routine and what the house did in between")
local traceLines = printed(EC.PRINT_LAST_TRACE)
check(
  "the header names the trace, its channel and its outcome",
  traceLines[1]:find("Good Night on night", 1, true) ~= nil
    and traceLines[1]:find("completed; all off; 2 step(s)", 1, true) ~= nil,
  traceLines[1]
)
check(
  "the event before the routine started is left out",
  lineWith(traceLines, "Top Button Pushed") == nil,
  table.concat(traceLines, "\n")
)
check(
  "the routine's own lines are marked, the house's are not",
  traceLines[lineWith(traceLines, "TRACE night  start") or 1]:find("]:   > ", 1, true) ~= nil
    and traceLines[lineWith(traceLines, "LIGHT_LEVEL 75 → 0") or 1]:find("]:     ", 1, true) ~= nil,
  table.concat(traceLines, "\n")
)
check(
  "a marker recorded on the trace's channel is one of the routine's lines",
  traceLines[lineWith(traceLines, "MARK  Doors checked") or 1]:find("]:   > ", 1, true) ~= nil,
  table.concat(traceLines, "\n")
)
check(
  "and counted",
  traceLines[#traceLines]:find("5 line(s) from the trace (>), 2 from the house in between", 1, true) ~= nil,
  traceLines[#traceLines]
)
EC.START_TRACE({ NAME = "Morning", CHANNEL = "day" })
EC.RECORD_TRACE_STEP({ MESSAGE = "Shades up", CHANNEL = "day" })
local stillLast = printed(EC.PRINT_LAST_TRACE)
check(
  "a trace still running does not replace the last one that ended",
  stillLast[1]:find("Good Night", 1, true) ~= nil,
  stillLast[1]
)
EC.FAIL_TRACE({ REASON = "shade offline", CHANNEL = "day" })
local failedLines = printed(EC.PRINT_LAST_TRACE)
check(
  "a failed trace is the last trace, with its reason",
  failedLines[1]:find("Morning on day", 1, true) ~= nil
    and lineWith(failedLines, "TRACE day  end  failed; shade offline") ~= nil
    and hasFired(7),
  table.concat(failedLines, "\n")
)

print("[17] the history for one device: its events and its variable, together")
Properties["Inspect Device ID"] = "12"
local deviceLines = printed(EC.PRINT_DEVICE)
check(
  "device 12: its button event, the trace step that named it, its level change",
  lineWith(deviceLines, "Top Button Pushed") ~= nil
    and lineWith(deviceLines, "step 1  Hall light off") ~= nil
    and lineWith(deviceLines, "LIGHT_LEVEL 75 → 0") ~= nil
    and lineWith(deviceLines, "Front Door") == nil,
  table.concat(deviceLines, "\n")
)
check(
  "and what is watched on it now",
  lineWith(deviceLines, "event coverage: Hall Keypad") ~= nil
    and lineWith(deviceLines, "variable LIGHT_LEVEL = 0") ~= nil,
  table.concat(deviceLines, "\n")
)
Properties["Inspect Device ID"] = ""

print("[18] a snapshot carries the history and the state of event capture")
ackAllFrames()
sent = {}
EC.CAPTURE_SNAPSHOT({ NOTE = "after good night" })
advance(300)
local snapFrame = lastSent("SBOS_MODULE_SNAPSHOT")
check("snapshot frame sent", snapFrame ~= nil)
local snapDoc = JSON:decode(snapFrame.params.document)
local snapLines = {}
for _, h in ipairs(snapDoc.history or {}) do
  snapLines[#snapLines + 1] = h.line
end
check(
  "the history is in the document, oldest first, one readable line each",
  #snapLines >= 8
    and lineWith(snapLines, "Hall / Hall Keypad: Top Button Pushed") == 1
    and lineWith(snapLines, "LIGHT_LEVEL 75 → 0") ~= nil
    and lineWith(snapLines, "NOTE  Snapshot requested") == #snapLines,
  table.concat(snapLines, "\n")
)
check(
  "each entry has its sequence, its time and its kind",
  snapDoc.history[1].seq == 1
    and snapDoc.history[1].kind == "event"
    and snapDoc.history[1].at:match("^%d%d%d%d%-") ~= nil
)
check(
  "event capture reports its coverage and policy",
  snapDoc.event_capture.subscriptions == countSubs()
    and snapDoc.event_capture.status == "capturing"
    and snapDoc.event_capture.coverage:find("subscriptions on", 1, true) ~= nil
    and snapDoc.event_capture.policy.storm_threshold == 30,
  JSON:encode(snapDoc.event_capture)
)
check(
  "device events are in the history, not repeated in the recent list",
  (function()
    for _, e in ipairs(snapDoc.recent_events) do
      if e.event_type == "capture.event" or e.event_type == "tracer.applied" then
        return false
      end
    end
    return #snapDoc.recent_events > 0
  end)()
)
check("nothing was cut", snapDoc.truncation.history == 0 and #snapDoc.storms == 0)
EC.SBOS_MODULE_SNAPSHOT_ACK({ job_id = snapFrame.params.job_id, ok = "true" })

print("[19] one pause and one resume for both halves")
fired = {}
EC.PAUSE_RECORDING({ REASON = "service visit" })
check(
  "paused: no event subscription and no variable listener is left",
  countSubs() == 0
    and listeners["12:1001"] == nil
    and prop("Recording Status") == "paused"
    and persisted["fr_paused"] == true,
  prop("Recording Status")
)
check("the conditional says so", TC.RECORDING_ACTIVE() == false)
OnDeviceEvent(12, 1)
OnWatchedVariableChanged(12, 1001, "40")
advance(3000)
local pausedLines = printed(EC.PRINT_RECENT)
check(
  "nothing is recorded while paused: the last entry is the pause itself",
  pausedLines[#pausedLines]:find("NOTE  Recording paused", 1, true) ~= nil,
  table.concat(pausedLines, "\n")
)
EC.RESUME_RECORDING()
check(
  "resumed: both are back",
  countSubs() == 7
    and listeners["12:1001"] == true
    and prop("Recording Status") == "recording"
    and persisted["fr_paused"] == false,
  countSubs()
)

print("[20] one licence rule for both halves")
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_FLIGHT_RECORDER",
  status = "NOT_ENTITLED",
  registered = "true",
  enforcement = "enforce",
})
check(
  "a definitive denial with enforcement releases subscriptions and listeners",
  countSubs() == 0 and listeners["12:1001"] == nil and prop("Recording Status") == "unlicensed",
  prop("Recording Status")
)
EC.SBOS_MODULE_COMMAND({
  token = "tok-3",
  request_id = "h2",
  command = "apply_config",
  args = JSON:encode({
    version = 3,
    config = {
      version = 3,
      sources = {
        { kind = "device_variable", device_id = 12, variable = "LIGHT_LEVEL" },
        { kind = "device_variable", device_id = 20, variable = "ContactState" },
      },
    },
  }),
})
check(
  "a configuration that arrives while halted is kept, and nothing listens",
  props["Configuration"]:find("v3", 1, true) ~= nil and listeners["12:1001"] == nil and listeners["20:2001"] == nil
)
EC.SBOS_MODULE_COMMAND({ token = "tok-3", request_id = "h3", command = "reapply", args = "{}" })
check(
  "re-apply while halted re-applies nothing",
  countSubs() == 0 and lastSent("SBOS_MODULE_COMMAND_RESULT").params.detail:find("unlicensed", 1, true) ~= nil
)
check("the history already held is still readable", #printed(EC.PRINT_RECENT) > 1)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_FLIGHT_RECORDER", status = "AUTHORIZED_SUBSCRIPTION", registered = "true" })
check(
  "licensed again: event capture and the kept configuration both start",
  countSubs() == 7
    and listeners["12:1001"] == true
    and listeners["20:2001"] == true
    and prop("Recording Status") == "recording",
  prop("Recording Status")
)

print("[21] Event Capture Off leaves the variable half recording")
Properties["Event Capture"] = "Off"
OnPropertyChanged("Event Capture")
check(
  "no subscriptions, listeners untouched, still recording",
  countSubs() == 0 and listeners["12:1001"] == true and prop("Recording Status") == "recording",
  prop("Recording Status")
)
check("coverage says why", prop("Event Coverage") == "event capture off", prop("Event Coverage"))
Properties["Event Capture"] = "On"
OnPropertyChanged("Event Capture")
check("on again", countSubs() == 7)

print("[22] a pause survives a reload, for both halves, and the history comes back with it")
EC.PAUSE_RECORDING({ REASON = "left paused overnight" })
advance(31000)
local heldBefore = #printed(EC.PRINT_RECENT)
OnDriverDestroyed()
sent = {}
subscriptions = {}
listeners = {}
OnDriverInit()
OnDriverLateInit("DIT_STARTUP")
agentRegisters(true, { token = "tok-4" })
advance(6000)
check(
  "still paused after the reload: nothing subscribed, nothing listening",
  countSubs() == 0 and next(listeners) == nil and prop("Recording Status") == "paused",
  prop("Recording Status")
)
local heldAfter = printed(EC.PRINT_RECENT)
check(
  "the history was restored: variable changes and trace steps included",
  #heldAfter >= heldBefore
    and lineWith(heldAfter, "LIGHT_LEVEL 75 → 0") ~= nil
    and lineWith(heldAfter, "TRACE night  end") ~= nil,
  #heldAfter .. " vs " .. heldBefore
)
EC.RESUME_RECORDING()
check(
  "resume after the reload starts both",
  countSubs() == 7
    and listeners["12:1001"] == true
    and listeners["20:2001"] == true
    and prop("Recording Status") == "recording",
  prop("Recording Status") .. " / " .. countSubs()
)

local afterReload = printed(EC.PRINT_LAST_TRACE)
check(
  "Print Last Trace still answers after the reload: it reads the history",
  afterReload[1]:find("Morning on day", 1, true) ~= nil
    and lineWith(afterReload, "TRACE day  end  failed; shade offline") ~= nil,
  table.concat(afterReload, "\n")
)

print("[23] a resume applies the settings as they are now, not the ones each half last held")
EC.PAUSE_RECORDING({ REASON = "settings change while paused" })
Properties["Exclude Device IDs"] = "20"
OnPropertyChanged("Exclude Device IDs")
advance(31000)
OnDriverDestroyed()
sent = {}
subscriptions = {}
listeners = {}
OnDriverInit()
OnDriverLateInit("DIT_STARTUP")
agentRegisters(true, { token = "tok-5" })
advance(6000)
EC.RESUME_RECORDING()
check(
  "an exclusion set before the restart is honoured by the resume",
  subscriptions["20:1"] == nil and subscriptions["12:1"] == true and countSubs() == 5,
  countSubs()
)
EC.PAUSE_RECORDING({ REASON = "again" })
Properties["Event Capture"] = "Off"
OnPropertyChanged("Event Capture")
OnDriverDestroyed()
subscriptions = {}
listeners = {}
OnDriverInit()
OnDriverLateInit("DIT_STARTUP")
agentRegisters(true, { token = "tok-6" })
advance(6000)
EC.RESUME_RECORDING()
check(
  "Event Capture Off stays off through a paused restart and a resume",
  countSubs() == 0 and listeners["12:1001"] == true and prop("Event Coverage") == "event capture off",
  countSubs() .. " / " .. tostring(prop("Event Coverage"))
)
Properties["Event Capture"] = "On"
Properties["Exclude Device IDs"] = ""
OnPropertyChanged("Event Capture")
check("capture back on", countSubs() == 7, countSubs())

print("[24] a configuration switched off stays off through pause and resume")
EC.SBOS_MODULE_COMMAND({
  token = "tok-6",
  request_id = "h9",
  command = "apply_config",
  args = JSON:encode({
    version = 9,
    config = {
      version = 9,
      enabled = false,
      sources = { { kind = "device_variable", device_id = 12, variable = "LIGHT_LEVEL" } },
    },
  }),
})
check("switched off: no listener, event capture untouched", next(listeners) == nil and countSubs() == 7)
EC.PAUSE_RECORDING({ REASON = "x" })
EC.RESUME_RECORDING()
check(
  "after pause and resume there is still no listener, and events are captured again",
  next(listeners) == nil and countSubs() == 7 and prop("Recording Status") == "recording",
  prop("Recording Status")
)
check(
  "the history says the resume happened and that the sources are off",
  lineWith(printed(EC.PRINT_RECENT), "NOTE  Recording resumed (variable sources are switched off)") ~= nil
)

print("[25] a pause and a resume while unlicensed are both in the history")
EC.SBOS_ENTITLEMENT({ sku = "SBOS_FLIGHT_RECORDER", status = "NOT_ENTITLED", registered = "true", enforcement = "enforce" })
EC.PAUSE_RECORDING({ REASON = "y" })
EC.RESUME_RECORDING()
local unlicensedLines = printed(EC.PRINT_RECENT)
check(
  "resumed is noted, with the reason nothing listens",
  lineWith(unlicensedLines, "NOTE  Recording resumed (unlicensed: nothing is listening)") ~= nil and countSubs() == 0,
  table.concat(unlicensedLines, "\n")
)
check(
  "resuming twice notes nothing more",
  (function()
    local before = #printed(EC.PRINT_RECENT)
    EC.RESUME_RECORDING()
    return #printed(EC.PRINT_RECENT) == before
  end)()
)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_FLIGHT_RECORDER", status = "AUTHORIZED_SUBSCRIPTION", registered = "true" })
check("licensed again: capture is back", countSubs() == 7)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
