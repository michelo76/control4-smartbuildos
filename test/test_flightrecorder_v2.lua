-- Flight Recorder DRIVER serving its local history over module contract v2
-- (Part A of AI Core), under the shim with a scripted Agent: the v2
-- manifest in the registration (and nothing cloud-side advertised), the
-- four request handlers answering from the ring through the real
-- moduleclient/modulerpc, each event carrying the id of the envelope it was
-- uploaded as, honest retention, a forged token ignored, an unknown
-- capability refused, the upload budget's events marked as never uploaded,
-- Clear Local History invalidating old cursors, the ids surviving the
-- history checkpoint — and the SAME driver unchanged against a v1-only
-- Agent (no agent_update_required, v1 services intact).
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
local function ackAll()
  local again = true
  while again do
    again = false
    for _, s in ipairs(sent) do
      if s.command == "SBOS_MODULE_EVENTS" and not s.acked then
        s.acked = true
        again = true
        EC.SBOS_MODULE_EVENTS_ACK({ batch_id = s.params.batch_id, accepted = tostring(#JSON:decode(s.params.events)) })
      end
    end
  end
end
local TOKEN = "tok-v2"
local function agentRegisters(protocol, agentMax)
  EC.SBOS_MODULE_REGISTERED({
    module_id = "flight_recorder",
    instance_id = tostring(SELF_ID),
    ok = "true",
    token = TOKEN,
    protocol = tostring(protocol),
    agent_protocol_min = agentMax and "1" or nil,
    agent_protocol_max = agentMax and tostring(agentMax) or nil,
    paired = "true",
    connected = "true",
    installation_id = "sys-1",
    boot_id = "boot-1",
    agent_version = "20261118.1",
  })
end
local reqSeq = 0
--- The Agent routing a request from AI Core; returns the decoded RESPONSE.
local function ask(capability, args, token)
  reqSeq = reqSeq + 1
  local id = "req-" .. reqSeq
  local before = #sentOf("SBOS_MODULE_RESPONSE")
  EC.SBOS_MODULE_REQUEST({
    module_id = "flight_recorder",
    instance_id = tostring(SELF_ID),
    token = token or TOKEN,
    request_id = id,
    idempotency_key = "k-" .. reqSeq,
    from_module_id = "ai_core",
    from_instance_id = "777",
    capability = capability,
    args = JSON:encode(args or {}),
    deadline = tostring(os.time() + 10),
  })
  local list = sentOf("SBOS_MODULE_RESPONSE")
  if #list == before then
    return nil
  end
  local r = list[#list].params
  return {
    request_id = r.request_id,
    status = r.status,
    error_code = r.error_code,
    cursor = r.cursor,
    token = r.token,
    result = JSON:decode(r.result),
  }
end

print("[1] the v2 manifest rides the registration")
agentPresent = true
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
local reg = lastSent("SBOS_MODULE_REGISTER")
check("registered to the Agent", reg ~= nil and reg.device == AGENT_ID)
check("offers protocol 1..2", reg.params.protocol_min == "1" and reg.params.protocol_max == "2")
local manifest = JSON:decode(reg.params.manifest or "{}")
check("manifest driver sbos.flight_recorder", manifest.driver == "sbos.flight_recorder", manifest.driver)
local caps = {}
for _, c in ipairs(manifest.capabilities or {}) do
  caps[c.id] = c
end
check(
  "the four local request capabilities",
  caps["events.query"]
    and caps["events.timeline"]
    and caps["events.device_history"]
    and caps["events.room_activity"]
    and caps["events.query"].kind == "request"
)
check(
  "events.subscribe topic over capture./observation./trace.",
  caps["events.subscribe"] and caps["events.subscribe"].kind == "topic" and #caps["events.subscribe"].topics == 3
)
check(
  "nothing cloud-side advertised",
  caps["events.correlate"] == nil and caps["incidents.analyze"] == nil and caps["events.compare"] == nil
)
check("manifest under the 2 KB contract limit", #reg.params.manifest <= 2048, #reg.params.manifest)
check("event capture subscribed through RegisterDeviceEvent", next(subscriptions) ~= nil)
check("no variable listener without a configured source", next(listeners) == nil)
check("status variable painted", vars["RECORDING_STATUS"] ~= nil)
agentRegisters(2, 2)
check("ready at protocol 2", prop("Agent Connection") == "ready")

print("[2] a device event: ring entry carries the uploaded envelope's id")
OnDeviceEvent(12, 1)
advance(8000)
ackAll()
local captured = nil
for _, e in ipairs(eventsSent()) do
  if e.event_type == "capture.event" and e.device_id == 12 then
    captured = e
  end
end
check("capture.event uploaded", captured ~= nil)
local r = ask("events.device_history", { device_id = 12 })
check("answered ok", r ~= nil and r.status == "ok", r and r.error_code)
check("RESPONSE carries our token (moduleclient auth)", r.token == TOKEN)
local first = r.result.events[1]
check(
  "the event cites the SAME envelope id the platform stores",
  first ~= nil and captured ~= nil and first.event_id == captured.event_id,
  first and first.event_id
)
check("its Composer event number is device_event_id", first.device_event_id == 1 and first.event_name ~= nil)
check("room id from the capture", first.room_id == 3)

print("[3] a programming marker and a variable change are in the same history")
EC.RECORD_EVENT({ NAME = "Good Night pressed", DETAIL = "keypad", DEVICE = "12" })
advance(8000)
ackAll()
local mark = nil
for _, e in ipairs(eventsSent()) do
  if e.event_type == "observation.programmed" then
    mark = e
  end
end
r = ask("events.query", { kinds = { "mark" } })
check("mark answered with its envelope id", r.result.events[1].event_id == mark.event_id)
r = ask("events.timeline", { from = os.time() - 60, to = os.time() + 1 })
local kindsSeen, ascending = {}, true
for i, e in ipairs(r.result.events) do
  kindsSeen[e.kind] = true
  if i > 1 and e.seq <= r.result.events[i - 1].seq then
    ascending = false
  end
end
check("timeline: oldest first, device event and marker both in it", ascending and kindsSeen.event and kindsSeen.mark)
check(
  "retention stated",
  r.result.retention.capacity == 500 and r.result.retention.held >= 2 and r.result.retention.oldest_available ~= nil
)
check("nothing evicted → not truncated", r.result.truncated == false)

print("[4] refusals")
check("a forged token gets no answer at all", ask("events.query", {}, "forged") == nil)
r = ask("events.correlate", {})
check("unknown capability → capability_not_found", r.status == "error" and r.error_code == "capability_not_found")
r = ask("events.query", { limit = 10000 })
check("bad args → invalid_args", r.status == "error" and r.error_code == "invalid_args")
r = ask("events.room_activity", { room_id = 99 })
check("a room with nothing → ok, empty", r.status == "ok" and r.result.count == 0)

print("[5] over the upload budget: held locally, never an invented id")
Properties["Event Upload Budget"] = "10"
OPC.Event_Upload_Budget("10")
for _ = 1, 15 do
  OnDeviceEvent(20, 1)
end
advance(8000)
ackAll()
r = ask("events.device_history", { device_id = 20, limit = 200 })
local withId, withoutId, reasons = 0, 0, {}
for _, e in ipairs(r.result.events) do
  if e.event_id then
    withId = withId + 1
  else
    withoutId = withoutId + 1
    reasons[e.no_event_id] = true
  end
end
check("some uploaded (with ids), some over budget (without)", withId > 0 and withoutId > 0, withId .. "/" .. withoutId)
check("the missing ones say why", reasons.over_upload_budget == true)

print("[6] paging + Clear Local History")
local p1 = ask("events.query", { limit = 2 })
check("cursor returned", p1.cursor ~= nil and p1.cursor ~= "", p1.cursor)
local p2 = ask("events.query", { limit = 2, cursor = p1.cursor })
check("page 2 continues", p2.status == "ok" and p2.result.events[1].seq < p1.result.events[2].seq)
advance(31000) -- the history checkpoint (every 30 s when dirty)
local checkpoint = persisted["fr_history_v1"]
EC.CLEAR_HISTORY()
r = ask("events.query", { limit = 2, cursor = p1.cursor })
check("a cursor from before the clear is refused", r.status == "error" and r.error_code == "invalid_args")
r = ask("events.query", {})
check(
  "empty ring → ok, no events, no oldest",
  r.status == "ok" and r.result.count == 0 and r.result.retention.oldest_available == nil
)
check("generation stated", r.result.retention.history_generation == 1)

print("[7] envelope ids survive the history checkpoint")
local keptIds = 0
for _, e in ipairs((checkpoint or {}).entries or {}) do
  if e.envelope_id then
    keptIds = keptIds + 1
  end
end
check("the persisted history kept the ids", keptIds > 0, keptIds)
local Ring = require("tracer.ring")
local restored = Ring.restore(checkpoint)
local _, again = require("flightrecorder.localquery").answer(
  "events.query",
  { limit = 200 },
  { ring = restored, now = os.time() }
)
local restoredIds = 0
for _, e in ipairs(again.events) do
  if e.event_id then
    restoredIds = restoredIds + 1
  end
end
check("a restored ring answers with them", restoredIds == keptIds, restoredIds)

print("[8] the same driver against a v1-only Agent")
local v2Frames = #sentOf("SBOS_MODULE_SUBSCRIBE")
  + #sentOf("SBOS_MODULE_DISCOVER")
  + #sentOf("SBOS_MODULE_CLOUD_REQUEST")
EC.SBOS_MODULE_AGENT_HELLO({})
agentRegisters(1, nil) -- a v1 Agent: no agent_protocol_max
local client = require("sbos.moduleclient")
check("registered at protocol 1", client.protocol() == 1)
check("no agent_update_required (FR does not require v2)", client.agentUpdateRequired() == false)
check("Agent Connection still ready", prop("Agent Connection") == "ready", prop("Agent Connection"))
local before = #eventsSent()
EC.RECORD_EVENT({ NAME = "still recording" })
advance(8000)
ackAll()
local still = false
for i = before + 1, #eventsSent() do
  still = still or eventsSent()[i].label == "still recording"
end
check("v1 event upload unchanged", still)
-- Since D6 the driver reports to AI Core (sbos.aireport, attach mode): its
-- only v2 frames of its own are the helper's DISCOVER {module_id = ai_core}
-- (the directory here never answers, so nothing is ever reported). No
-- subscription and no cloud request, and nothing new on a v1-only Agent.
local onlyAiLookups = #sentOf("SBOS_MODULE_DISCOVER") > 0
for _, f in ipairs(sentOf("SBOS_MODULE_DISCOVER")) do
  onlyAiLookups = onlyAiLookups and f.params.filter == '{"module_id":"ai_core"}'
end
check(
  "FR's own v2 frames: only the AI Core lookup, none on a v1 Agent",
  #sentOf("SBOS_MODULE_SUBSCRIBE") + #sentOf("SBOS_MODULE_CLOUD_REQUEST") == 0
    and #sentOf("SBOS_MODULE_SUBSCRIBE") + #sentOf("SBOS_MODULE_DISCOVER") + #sentOf("SBOS_MODULE_CLOUD_REQUEST") == v2Frames
    and onlyAiLookups
    and #sentOf("SBOS_MODULE_REQUEST") == 0
)

OnDriverDestroyed()

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
