-- Flight Recorder DRIVER under the shim with a scripted Agent: lifecycle,
-- registration, configuration delivery, the Good Night scenario (trace +
-- lighting request + observed feedback + garage contact check + decision +
-- completion), overlapping executions, commands with token/expiry rules,
-- snapshots, Agent restart, removal cleanup. The frames the driver sends are
-- exported as a fixture the web suite ingests.
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
      -- Deterministic: equal deadlines fire in id order (pairs order varies
      -- between runs and made the resend counts flaky).
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
-- os.time follows the fake clock so debounce/expiry rules are deterministic.
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
local sent = {} -- { device, command, params }
local fired = {}
local listeners = {}
local regCalls, unregCalls = 0, 0
local variables = {
  [12] = { ["1001"] = { name = "LIGHT_LEVEL", value = "75" }, ["1002"] = { name = "LIGHT_STATE", value = "True" } },
  [20] = { ["2001"] = { name = "ContactState", value = "Closed" } },
  [30] = { ["3001"] = { name = "USER_CODE", value = "1234" } },
}
local props = {}
C4.GetDevices = function()
  local d = {
    [12] = { deviceName = "Kitchen Pendants", driverFileName = "light_v2.c4i", roomId = 3, roomName = "Kitchen" },
    [20] = { deviceName = "Garage Door", driverFileName = "contact.c4i", roomId = 7, roomName = "Garage" },
    [30] = { deviceName = "Front Lock", driverFileName = "lock.c4i", roomId = 1, roomName = "Entry" },
  }
  if agentPresent then
    d[AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" }
  end
  return d
end
C4.GetDeviceVariables = function(_, id)
  return variables[tonumber(id)]
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
  return "20261022.000000"
end
C4.SendToDevice = function(_, device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
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
C4.SetVariable = function() end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.UpdateProperty = function(_, name, value)
  props[name] = value
end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end

-- Every property the XML declares, at its default: the shared UpdateProperty
-- refuses a property that is not in the table (as Director would).
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
Properties["Buffer Warning Threshold"] = 50

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
local TOKEN = "tok-abc"
local function agentRegisters(ok, extra)
  local reg = lastSent("SBOS_MODULE_REGISTER")
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
    agent_version = "20261022.1",
  }
  for k, v in pairs(extra or {}) do
    reply[k] = v
  end
  EC.SBOS_MODULE_REGISTERED(reply)
  return reg
end
local function ackAllFrames()
  -- An ack lets the client flush more staged events (new frames), so loop
  -- until nothing is left unacknowledged.
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

print("[1] starts without an Agent: waiting, retrying, recording locally")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", props["Driver Status"] == "Online")
check("waiting for agent", prop("Agent Connection") == "waiting_for_agent", prop("Agent Connection"))
check("no register frame sent (no Agent)", #sentOf("SBOS_MODULE_REGISTER") == 0)
check("retry timer armed", clock.timers["SbosModuleRegister"] ~= nil)
check("conditional AGENT_READY false", TC.AGENT_READY() == false)

print("[2] the Agent appears: registration round trip")
agentPresent = true
advance(31000)
local reg = lastSent("SBOS_MODULE_REGISTER")
check("register frame to the Agent", reg ~= nil and reg.device == AGENT_ID, reg and reg.device)
check(
  "frame carries the contract",
  reg.params.module_id == "flight_recorder"
    and reg.params.protocol_max == "1"
    and reg.params.entitlements == "SBOS_FLIGHT_RECORDER"
    and reg.params.singleton == "true"
    and reg.params.commands:find("apply_config") ~= nil
)
agentRegisters(true)
check("registered + ready", props["Agent Connection"] == "ready" and TC.AGENT_READY() == true)
check("Agent Connected fired", hasFired(8))
check("status frame carries the token", lastSent("SBOS_MODULE_STATUS").params.token == TOKEN)
check(
  "licence registered with the Agent too",
  #sentOf("SBOS_REGISTER_DRIVER") >= 1 and lastSent("SBOS_REGISTER_DRIVER").params.sku == "SBOS_FLIGHT_RECORDER"
)

print("[3] configuration arrives through the Agent's config forwarding")
local settings = {
  version = 3,
  sources = {
    {
      kind = "device_variable",
      device_id = 12,
      variable = "LIGHT_LEVEL",
      label = "Kitchen pendants",
      category = "lighting",
    },
    {
      kind = "device_variable",
      device_id = 20,
      variable = "ContactState",
      label = "Garage door",
      category = "contact",
    },
    { kind = "device_variable", device_id = 99, variable = "X", label = "Gone device" },
    { kind = "sbos_event", event = "director_reloaded" },
  },
}
EC.SBOS_DRIVER_CONFIG({
  sku = "SBOS_FLIGHT_RECORDER",
  settings = JSON:encode(settings),
  settings_version = "3",
  requester = tostring(AGENT_ID),
})
local ack = lastSent("SBOS_DRIVER_CONFIG_ACK")
check("config acked as applied", ack ~= nil and ack.params.applied == "true" and ack.params.settings_version == "3")
check(
  "two listeners registered, stale one reported",
  regCalls == 2 and props["Selected Sources"]:find("1 stale") ~= nil,
  props["Selected Sources"]
)
advance(2500)
check(
  "initial observations sent, not changes",
  #eventsOfType("observation.initial") == 2 and #eventsOfType("observation.change") == 0
)
check(
  "config_applied event for v3 (after the startup default v0)",
  eventsOfType("recorder.config_applied")[#eventsOfType("recorder.config_applied")].payload.version == 3
)
check("Configuration property", props["Configuration"]:find("v3 applied %(studio%)") ~= nil, props["Configuration"])
ackAllFrames()
check("last upload stamped after the Agent's ack", props["Last Upload"] ~= "never")

print("[4] a refused revision keeps v3")
EC.SBOS_DRIVER_CONFIG({
  sku = "SBOS_FLIGHT_RECORDER",
  settings = JSON:encode({
    version = 4,
    sources = { { kind = "device_variable", device_id = 30, variable = "USER_CODE" } },
  }),
  settings_version = "4",
})
check("acked as refused", lastSent("SBOS_DRIVER_CONFIG_ACK").params.applied == "false")
check(
  "v3 still applied, v4 refused visible",
  props["Configuration"]:find("v3 applied") ~= nil and props["Configuration"]:find("desired v4 refused") ~= nil,
  props["Configuration"]
)
advance(2500)
check("refusal recorded as an event", #eventsOfType("recorder.config_refused") == 1)
check("no listener for the credential variable", listeners["30:3001"] == nil)

print("[5] Good Night: trace, lighting request, observed feedback, garage check, decision, completion")
ackAllFrames()
sent = {}
EC.START_TRACE({ CHANNEL = "good_night", NAME = "Good Night" })
EC.RECORD_TRACE_STEP({ CHANNEL = "good_night", MESSAGE = "Kitchen pendants: OFF requested", DEVICE = "12" })
EC.RECORD_EXPECTED_RESULT({ CHANNEL = "good_night", EXPECTED = "Kitchen pendants at 0%", DEVICE = "12" })
OnWatchedVariableChanged(12, 1001, "0")
EC.RECORD_TRACE_STEP({ CHANNEL = "good_night", MESSAGE = "Garage contact check", DEVICE = "20" })
EC.RECORD_TRACE_DECISION({ CHANNEL = "good_night", CONDITION = "Garage door closed?", OUTCOME = "yes" })
EC.RECORD_EVENT({ NAME = "Good Night done", DETAIL = "all rooms", CHANNEL = "good_night" })
EC.COMPLETE_TRACE({ CHANNEL = "good_night", NOTE = "ok" })
advance(2500)
local evs = eventsSent()
local order = {}
for _, e in ipairs(evs) do
  order[#order + 1] = e.event_type
end
check(
  "event order",
  table.concat(order, ",")
    == "trace.start,trace.step,trace.expected,observation.change,trace.step,trace.decision,observation.programmed,trace.end",
  table.concat(order, ",")
)
local traceId = evs[1].correlation_id
check(
  "steps correlate to the trace",
  evs[2].correlation_id == traceId and evs[6].correlation_id == traceId and evs[8].correlation_id == traceId
)
check(
  "the observed change is NOT correlated (evidence stays separate)",
  evs[4].correlation_id == nil
    and evs[4].evidence_source == "observed"
    and evs[4].payload.previous == 75
    and evs[4].payload.value == 0
)
check("expected result is a request", evs[3].evidence_source == "requested")
check(
  "programmed event inside the trace is correlated",
  evs[7].correlation_id == traceId and evs[7].evidence_source == "requested"
)
check(
  "sequence strictly increasing",
  (function()
    for i = 2, #evs do
      if evs[i].sequence <= evs[i - 1].sequence then
        return false
      end
    end
    return true
  end)()
)
check("Trace Completed fired", hasFired(6))
check("trace end payload", evs[8].payload.status == "completed" and evs[8].payload.steps == 4)

print("[6] overlapping executions on one channel")
ackAllFrames()
sent = {}
EC.START_TRACE({ CHANNEL = "good_night", NAME = "Good Night" })
EC.START_TRACE({ CHANNEL = "good_night", NAME = "Good Night" })
EC.START_TRACE({ CHANNEL = "garage", NAME = "Garage check" })
advance(2500)
check(
  "first interrupted, two active",
  #eventsOfType("trace.end") == 1
    and eventsOfType("trace.end")[1].payload.status == "interrupted"
    and props["Active Traces"] == "2",
  (function()
    local t = {}
    for _, e in ipairs(eventsSent()) do
      t[#t + 1] = e.event_type .. (e.payload.status and ("=" .. e.payload.status) or "")
    end
    return table.concat(t, ",") .. " active=" .. tostring(props["Active Traces"])
  end)()
)
EC.COMPLETE_TRACE({ CHANNEL = "garage" })
EC.COMPLETE_TRACE({ CHANNEL = "garage" })
advance(2500)
check("duplicate completion recorded", #eventsOfType("trace.duplicate_completion") == 1)
advance(11 * 60 * 1000)
check(
  "good_night abandoned after the timeout",
  (function()
    for _, e in ipairs(eventsOfType("trace.end")) do
      if e.payload.status == "abandoned" then
        return true
      end
    end
    return false
  end)()
)

print("[7] restricted commands: token, expiry, duplicates, outcomes")
ackAllFrames()
sent = {}
EC.SBOS_MODULE_COMMAND({ token = "wrong", request_id = "r1", command = "pause", args = "{}" })
check("wrong token ignored", #sentOf("SBOS_MODULE_COMMAND_RESULT") == 0)
EC.SBOS_MODULE_COMMAND({
  token = TOKEN,
  request_id = "r2",
  command = "pause",
  args = JSON:encode({ reason = "tech" }),
  expires_at = tostring(os.time() - 1),
})
check("expired → Expired", lastSent("SBOS_MODULE_COMMAND_RESULT").params.state == "Expired")
EC.SBOS_MODULE_COMMAND({
  token = TOKEN,
  request_id = "r3",
  command = "pause",
  args = JSON:encode({ reason = "tech" }),
  expires_at = tostring(os.time() + 60),
})
local results = sentOf("SBOS_MODULE_COMMAND_RESULT")
check(
  "Accepted → Executing → Completed",
  results[2].params.state == "Accepted"
    and results[3].params.state == "Executing"
    and results[4].params.state == "Completed"
)
check(
  "paused: listeners released",
  props["Recording Status"] == "paused" and next(listeners) == nil and TC.RECORDING_ACTIVE() == false
)
check(
  "changes while paused are not recorded",
  (function()
    advance(2500)
    local before = #eventsSent()
    OnWatchedVariableChanged(12, 1001, "50")
    advance(2500)
    return #eventsSent() == before
  end)()
)
EC.SBOS_MODULE_COMMAND({ token = TOKEN, request_id = "r4", command = "resume", args = "{}" })
advance(2500)
check(
  "resume re-reads as initial",
  props["Recording Status"] == "recording" and #eventsOfType("observation.initial") == 2
)
EC.SBOS_MODULE_COMMAND({ token = TOKEN, request_id = "r5", command = "bogus", args = "{}" })
check(
  "unknown command fails by name",
  lastSent("SBOS_MODULE_COMMAND_RESULT").params.state == "Failed"
    and lastSent("SBOS_MODULE_COMMAND_RESULT").params.detail:find("bogus") ~= nil
)
EC.SBOS_MODULE_COMMAND({
  token = TOKEN,
  request_id = "r6",
  command = "apply_config",
  args = JSON:encode({
    version = 5,
    config = { version = 5, sources = { { kind = "device_variable", device_id = 12, variable = "LIGHT_STATE" } } },
  }),
})
check(
  "apply_config via command",
  lastSent("SBOS_MODULE_COMMAND_RESULT").params.state == "Completed"
    and props["Configuration"]:find("v5 applied") ~= nil
)
check(
  "reconciled: pendants level listener gone, state listener on, garage gone",
  listeners["12:1002"] and not listeners["12:1001"] and not listeners["20:2001"]
)

print("[8] snapshot job: async, redacted, acknowledged")
ackAllFrames()
sent = {}
fired = {}
EC.SBOS_MODULE_COMMAND({
  token = TOKEN,
  request_id = "r7",
  command = "capture_snapshot",
  args = JSON:encode({ note = "after good night" }),
})
check("Executing reported", lastSent("SBOS_MODULE_COMMAND_RESULT").params.state == "Executing")
advance(300)
local snap = lastSent("SBOS_MODULE_SNAPSHOT")
check("snapshot frame sent", snap ~= nil and snap.params.job_id:find("^snap%-") ~= nil)
local doc = JSON:decode(snap.params.document)
check(
  "document shape",
  doc.kind == "flight_recorder_snapshot"
    and doc.not_a_backup == true
    and #doc.configuration.sources == 1
    and doc.module.status == "recording"
)
check("recent events included and bounded", #doc.recent_events > 0 and #doc.recent_events <= 100)
check("token never in the document", snap.params.document:find(TOKEN, 1, true) == nil)
EC.SBOS_MODULE_SNAPSHOT_ACK({ job_id = snap.params.job_id, ok = "true" })
check(
  "Snapshot Completed fired + command Completed",
  hasFired(4) and lastSent("SBOS_MODULE_COMMAND_RESULT").params.state == "Completed"
)
check("Last Snapshot painted", props["Last Snapshot"]:find("completed") ~= nil)

print("[9] Agent restart: hello → re-register; lost ack → resend then drop")
ackAllFrames()
sent = {}
props["Agent Connection"] = nil
EC.SBOS_MODULE_AGENT_HELLO({})
check(
  "re-registered",
  #sentOf("SBOS_MODULE_REGISTER") == 1 and prop("Agent Connection") == "waiting_for_agent",
  prop("Agent Connection")
)
agentRegisters(true, { token = "tok-2" })
check("new token in use", lastSent("SBOS_MODULE_STATUS").params.token == "tok-2")
advance(2500)
ackAllFrames()
sent = {}
OnWatchedVariableChanged(12, 1002, "False")
advance(2500)
check("frame sent", #sentOf("SBOS_MODULE_EVENTS") == 1)
advance(50000)
check(
  "resent once unacked",
  #sentOf("SBOS_MODULE_EVENTS") == 2
    and sentOf("SBOS_MODULE_EVENTS")[2].params.batch_id == sentOf("SBOS_MODULE_EVENTS")[1].params.batch_id,
  #sentOf("SBOS_MODULE_EVENTS")
)
local droppedBefore = tonumber(props["Dropped Events"]) or 0
advance(120000)
check(
  "dropped and counted after the tries",
  #sentOf("SBOS_MODULE_EVENTS") == 3 and (tonumber(props["Dropped Events"]) or 0) > droppedBefore,
  #sentOf("SBOS_MODULE_EVENTS") .. " dropped=" .. tostring(props["Dropped Events"])
)

print("[10] Composer template adds only what exists; Studio ownership is reported")
sent = {}
Properties["Template"] = "Lighting"
EC.APPLY_TEMPLATE()
check("composer revision applied", props["Configuration"]:find("%(composer%)") ~= nil, props["Configuration"])
check(
  "two lighting sources now (level + state) and no credential",
  listeners["12:1001"] and listeners["12:1002"] and not listeners["30:3001"]
)
Properties["Template"] = "Motion and occupancy"
EC.APPLY_TEMPLATE()
check("empty template refused with a reason", props["Last Recording Error"]:find("template added no sources") ~= nil)

print("[11] removal stops listeners and timers, unregisters")
sent = {}
unregCalls = 0
EC.START_TRACE({ CHANNEL = "x", NAME = "X" })
OnDriverDestroyed()
check("listeners released", next(listeners) == nil and unregCalls >= 2)
check("unregister frame", lastSent("SBOS_MODULE_UNREGISTER") ~= nil)
check(
  "open trace interrupted and flushed before stop",
  (function()
    for _, e in ipairs(eventsSent()) do
      if e.event_type == "trace.end" and e.payload.status == "interrupted" then
        return true
      end
    end
    return false
  end)()
)
check(
  "no timers left",
  next(clock.timers) == nil,
  (function()
    local names = {}
    for k in pairs(clock.timers) do
      names[#names + 1] = k
    end
    return table.concat(names, ",")
  end)()
)

-- Fixture for the web suite: the Good Night frames as the Agent would upload
-- them (installation/boot stamped by the Agent on the way out).
do
  local all = {}
  for _, e in ipairs(evs) do
    e.installation_id = "sys-1"
    e.boot_id = "boot-1"
    all[#all + 1] = e
  end
  local f = io.open("test/fixtures/flight-recorder/good-night-events.json", "w")
  if f then
    f:write(JSON:encode_pretty(all))
    f:close()
  end
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
