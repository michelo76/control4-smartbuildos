-- Flight Recorder as an AI Core reference driver (sbos.aireport, ATTACH
-- mode: the driver's own module client carries the reports).
--
-- The real driver.lua under the shim, the REAL Agent registry and bus, and a
-- fake AI Core that runs every report through AI Core's REAL validator
-- (test/aicore_reporter_harness.lua). Covered:
--   [1] AI Core absent: registered once (its own client), manifest lists
--       ai.query, zero report frames, "Not installed"; recording unchanged
--   [2] AI Core appears: describe accepted, state facts (no device activity)
--   [3] events (storm started / ended, a routine that did not complete) and
--       diagnostics (degraded / restored)
--   [4] the two queries through the real bus; the events.* capabilities
--       still answer; no action is served
--   [5] AI Core goes away and comes back
--   [6] OnDriverDestroyed leaves the unregistering to the driver's client
-- Run from the driver root: make test

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

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")
local H = require("aicore_reporter_harness")

local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    if type(id) == "string" then
      clock.timers[id] = nil
    end
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
-- The recorder's own clock follows the test clock (storm windows, ticks).
local BASE = os.time()
FLIGHT_RECORDER_NOW = function()
  return BASE + clock.now / 1000
end
package.preload["cloud-client-byte"] = function()
  return true
end
package.preload["tracer.catalog_data"] = function()
  return {
    ["keypad.c4z"] = { [1] = "Top Button Pushed", [2] = "Bottom Button Pushed" },
    ["contact.c4z"] = { [1] = "Opened", [2] = "Closed" },
  }
end
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
  return P
end

local SELF = 12345
local devices = {
  [12] = { deviceName = "Hall Keypad", driverFileName = "keypad.c4z", roomId = 3, roomName = "Hall" },
  [20] = { deviceName = "Front Door", driverFileName = "contact.c4z", roomId = 1, roomName = "Entry" },
  [SELF] = { deviceName = "Flight Recorder", driverFileName = "smartbuildos-flight-recorder.c4z" },
  [H.AGENT] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
}
C4.GetDevices = function()
  return devices
end
C4.GetProjectItems = function()
  return nil
end
C4.GetDeviceDisplayName = function(_, id)
  local d = devices[tonumber(id)]
  return d and d.deviceName or nil
end
C4.GetDeviceID = function()
  return SELF
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "SmartBuildOS Flight Recorder"
  end
  return "20261118.000001"
end
C4.FireEventByID = function() end
C4.FireEvent = function() end
C4.RegisterDeviceEvent = function() end
C4.UnregisterDeviceEvent = function() end
C4.GetDeviceVariables = function()
  return nil
end
C4.RegisterVariableListener = function() end
C4.UnregisterVariableListener = function() end
C4.SetVariable = function() end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end
local everPainted = {}
C4.UpdateProperty = function(_, name, value)
  Properties[name] = value
  if name == "AI Core" then
    everPainted[#everPainted + 1] = tostring(value)
  end
end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-flight-recorder/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    if name then
      Properties[name] = default
    end
  end
end
check("driver.xml declares the AI Core property (exact default)", Properties["AI Core"] == "Searching…")

H.install({ selfId = SELF, file = "smartbuildos-flight-recorder.c4z" })
dofile("drivers/smartbuildos-flight-recorder/driver.lua")
local aireport = require("sbos.aireport")

print("[1] AI Core absent")
OnDriverInit()
local okLate, lateErr = pcall(OnDriverLateInit)
check("OnDriverLateInit runs", okLate, lateErr)
check("helper in attach mode", aireport.mode() == "attach")
check(
  "ONE registration (the driver's own client)",
  H.count("SBOS_MODULE_REGISTER") == 1,
  H.count("SBOS_MODULE_REGISTER")
)
local row = H.registry:find("flight_recorder", tostring(SELF))
local caps = {}
for _, c in ipairs(row and row.manifest and row.manifest.capabilities or {}) do
  caps[c.id] = true
end
check(
  "manifest: its events.* capabilities plus ai.query, no ai.action",
  caps["events.query"] and caps["events.timeline"] and caps["ai.query"] and not caps["ai.action"]
)
check("verified by the Agent", row ~= nil and row.verified == true)
check("no report frame while AI Core is absent", H.reportFrames() == 0, H.reportFrames())
check("property: Not installed", Properties["AI Core"] == "Not installed", Properties["AI Core"])
for _ = 1, 3 do
  OnDeviceEvent(20, 1)
end
advance(3000)
check(
  "recording unchanged (device events captured)",
  tonumber(Properties["Events Captured"]) == 3,
  Properties["Events Captured"]
)
check("still no report frame", H.reportFrames() == 0)

print("[2] AI Core appears")
H.aiRegister()
H.pushDirectory()
local d = H.reports("describe")[#H.reports("describe")]
check("describe arrived, AI Core accepted everything", d ~= nil and H.allValid(), select(2, H.allValid()))
d = d.args
check(
  "describe: file, sku, summary",
  d.driver.file == "smartbuildos-flight-recorder.c4z"
    and d.driver.sku == "SBOS_FLIGHT_RECORDER"
    and d.summary:find("what happened", 1, true) ~= nil
)
check(
  "queries: capture_coverage, history_coverage; no action",
  #d.queries == 2
    and d.queries[1].id == "capture_coverage"
    and d.queries[2].id == "history_coverage"
    and #d.actions == 0
)
check(
  "property: Found — reporting",
  Properties["AI Core"] == "Found — reporting (v20261118.2)",
  Properties["AI Core"]
)
local facts = H.reports("state")[#H.reports("state")].args.facts
check(
  "state: recording facts",
  type(facts.recording_status) == "string"
    and facts.event_capture == true
    and facts.devices_total >= 2
    and type(facts.subscriptions) == "number",
  JSON:encode(facts)
)
local everything = JSON:encode(H.reports())
check(
  "no device activity in any report (no device names)",
  everything:find("Front Door", 1, true) == nil and everything:find("Hall Keypad", 1, true) == nil
)

print("[3] events and diagnostics")
local e0 = #H.reports("event")
for _ = 1, 50 do
  OnDeviceEvent(20, 1)
end
advance(2500)
local types = {}
for i = e0 + 1, #H.reports("event") do
  types[#types + 1] = H.reports("event")[i].args.type
end
check("a storm is ONE event, not fifty", table.concat(types, ",") == "recorder.storm_started", table.concat(types, ","))
advance(95000)
local last = H.reports("event")[#H.reports("event")]
check("the storm's end is an event", last.args.type == "recorder.storm_ended")
EC.START_TRACE({ CHANNEL = "good_night", NAME = "Good Night" })
EC.COMPLETE_TRACE({ CHANNEL = "good_night", NOTE = "ok" })
local n = #H.reports("event")
EC.START_TRACE({ CHANNEL = "garage", NAME = "Garage check" })
EC.FAIL_TRACE({ CHANNEL = "garage", REASON = "door still open" })
local evs = H.reports("event")
check("a completed routine is not reported", n == #evs - 1, #evs - n)
check(
  "a routine that did not complete is an event",
  evs[#evs].args.type == "routine.not_completed"
    and evs[#evs].args.data.routine == "Garage check"
    and evs[#evs].args.data.status == "failed",
  JSON:encode(evs[#evs].args)
)
local dg0 = #H.reports("diagnostic")
EC.PAUSE_RECORDING_ACTION()
advance(61000)
EC.RESUME_RECORDING_ACTION()
advance(61000)
local codes = {}
for i = dg0 + 1, #H.reports("diagnostic") do
  codes[#codes + 1] = H.reports("diagnostic")[i].args.code
end
check(
  "paused = degraded, resumed = restored (diagnostics)",
  table.concat(codes, ",") == "recorder.degraded,recorder.restored",
  table.concat(codes, ",")
)
check("every report valid for AI Core", H.allValid())

print("[4] queries")
local r = H.aiAsk("flight_recorder", "ai.query", { query_id = "history_coverage", params = {} })
local data = r and r.result and r.result.data or {}
check(
  "history_coverage: how far back, how full",
  r
    and r.status == "ok"
    and data.entries_held >= 30
    and data.by_kind.event >= 30
    and data.capacity == tonumber(Properties["Local History Size"])
    and type(data.oldest_at) == "number"
    and data.span_seconds >= 0,
  r and JSON:encode(r)
)
r = H.aiAsk("flight_recorder", "ai.query", { query_id = "capture_coverage", params = {} })
check("capture_coverage answered", r and r.status == "ok" and r.result.data.devices_total >= 2, r and JSON:encode(r))
r = H.aiAsk("flight_recorder", "ai.query", { query_id = "history_coverage", params = { since = 1 } })
check("an unknown param refused", r and r.error_code == "invalid_args")
r = H.aiAsk("flight_recorder", "events.query", { limit = 2 })
check("its own events.query still answers", r and r.status == "ok", r and JSON:encode(r))
r = H.aiAsk(
  "flight_recorder",
  "ai.action",
  { action_id = "pause", params = {}, ai_action_id = "a1", declaration_hash = aireport.declarationHash() }
)
check("no action is served (not advertised; the bus refuses)", r == nil or r.status == "error")

print("[5] AI Core goes away and comes back")
H.aiRemove()
H.pushDirectory()
check("property: Not installed", Properties["AI Core"] == "Not installed", Properties["AI Core"])
local frames = H.reportFrames()
for _ = 1, 50 do
  OnDeviceEvent(20, 1)
end
advance(2500)
check("no report frame while it is gone (a storm happened)", H.reportFrames() == frames)
H.aiRegister()
H.pushDirectory()
check("back: Found — reporting", Properties["AI Core"] == "Found — reporting (v20261118.2)", Properties["AI Core"])
local outside = {}
for _, v in ipairs(everPainted) do
  if not aireport.isValue(v) then
    outside[#outside + 1] = v
  end
end
check("only closed values were painted", #outside == 0, table.concat(outside, " | "))

print("[6] OnDriverDestroyed")
OnDriverDestroyed()
check(
  "unregistered once, by the driver's own client",
  H.count("SBOS_MODULE_UNREGISTER") == 1 and H.registry:find("flight_recorder", tostring(SELF)) == nil
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
