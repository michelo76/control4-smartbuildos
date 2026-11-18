-- SmartBuildOS AI Core under the Director emulator (EMULATOR ONLY — not a
-- bench result; no physical controller has run any of this). The REAL
-- Agent, the REAL Flight Recorder and the REAL AI Core exchange frames
-- through the emulator's asynchronous SendToDevice → ExecuteCommand path.
-- The cloud is scripted: the emulator's fake cloud (pairing, heartbeat,
-- signed licences; read only) plus /api/integrations/control4/modules/rpc
-- answered here. Run: test/emulator/run-ai-core.sh (exit 1 on any failure).

local EMU = assert(os.getenv("DIRECTOR_EMULATOR"), "DIRECTOR_EMULATOR not set (use the run script)")
local OUT = assert(os.getenv("SBOS_AI_OUT"), "SBOS_AI_OUT not set (use the run script)")
package.path = EMU .. "/examples/connector/?.lua;" .. package.path
local Cloud = require("fake_cloud")

local passed, failed = 0, 0
local function check(label, ok, detail)
  if ok then
    passed = passed + 1
    print("  CHECK ok    " .. label)
  else
    failed = failed + 1
    print("  CHECK FAIL  " .. label .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

-- ── one Director with a scripted cloud ──────────────────────────────────────
local function newDirector(cacheSuffix)
  local d = Director.new({ cacheDir = os.getenv("DIRECTOR_CACHE") .. (cacheSuffix or "") })
  local cloud = Cloud.new(d):install()
  cloud.catalog.SBOS_AI_CORE =
    { status = "AUTHORIZED_SUBSCRIPTION", license_type = "SUBSCRIPTION_INCLUDED", features = { "BASE", "AI_LEARNING" } }
  cloud.catalog.SBOS_FLIGHT_RECORDER =
    { status = "AUTHORIZED_SUBSCRIPTION", license_type = "SUBSCRIPTION_INCLUDED", features = { "BASE" } }
  local S = {
    d = d,
    cloud = cloud,
    rpc = { calls = {}, down = false, answer = nil },
    pending = { commands = {}, driver_config = nil, enforcement = nil },
  }
  d.http = function(req, dev)
    local path = tostring(req.url):match("^https?://[^/]+(/[^?]*)")
    if path == "/api/integrations/control4/modules/rpc" then
      local body = type(req.body) == "string" and json.decode(req.body) or req.body
      S.rpc.calls[#S.rpc.calls + 1] = body
      if S.rpc.down then
        return nil
      end
      local reply = S.rpc.answer and S.rpc.answer(body)
        or { ok = true, result = { accepted = true, job_id = "job-" .. #S.rpc.calls } }
      return { code = 200, headers = { ["Content-Type"] = "application/json" }, body = json.encode(reply) }
    end
    local resp = cloud:handle(req, dev)
    if resp and resp.code == 200 and path == "/api/integrations/control4/events" then
      -- What the platform answers (PROTOCOL.md): the ids it durably accepted.
      local body = type(req.body) == "string" and json.decode(req.body) or req.body or {}
      local ids = {}
      for _, e in ipairs(body.events or {}) do
        ids[#ids + 1] = e.event_id
      end
      resp.body = json.encode({ ok = true, accepted = ids, rejected = {} })
    elseif resp and resp.code == 200 and path == "/api/integrations/control4/heartbeat" then
      local body = json.decode(resp.body)
      if #S.pending.commands > 0 then
        body.commands = S.pending.commands
        S.pending.commands = {}
      end
      if S.pending.driver_config then
        body.driver_config = S.pending.driver_config
        S.pending.driver_config = nil
      end
      resp.body = json.encode(body)
    elseif
      resp
      and resp.code == 200
      and path == "/api/driver-cloud/entitlements/refresh"
      and (S.pending.enforcement or S.pending.refreshEdit)
    then
      local body = json.decode(resp.body)
      body.enforcement = S.pending.enforcement
      if S.pending.refreshEdit then
        S.pending.refreshEdit(body)
      end
      resp.body = json.encode(body)
    end
    return resp
  end
  return S
end

local function var(dev, name)
  local v = dev.vars and dev.vars.byName and dev.vars.byName[name]
  return v and v.value or nil
end

--- A value the driver persisted (lib.persist stores tables serialized).
local function persisted(dev, key)
  local raw = dev.persist[key]
  if type(raw) == "string" and dev.env.Deserialize then
    local ok, value = pcall(dev.env.Deserialize, raw)
    if ok then
      return value
    end
  end
  return raw
end

local function firedCount(d, dev, id)
  local n = 0
  for _, e in ipairs(d.eventLog or {}) do
    if e.device == dev.id and e.id == id then
      n = n + 1
    end
  end
  return n
end

--- Every envelope the cloud received on /events, in arrival order.
local function cloudEnvelopes(S, eventType)
  local out = {}
  for _, r in ipairs(S.cloud.requests) do
    if r.path == "/api/integrations/control4/events" and type(r.body) == "table" then
      for _, e in ipairs(r.body.events or {}) do
        if eventType == nil or e.event_type == eventType then
          out[#out + 1] = e
        end
      end
    end
  end
  return out
end

--- AI Core's counters, read from its own Print Diagnostics output.
local function diagnostics(d, dev)
  local before = #dev.output
  d:action(dev, "PRINT_DIAGNOSTICS")
  local c = {}
  for i = before + 1, #dev.output do
    local k, v = tostring(dev.output[i]):match("  ([%w_]+) = (.+)$")
    if k then
      c[k] = tonumber(v) or v
    end
  end
  return c
end

local cmdSeq = 0
local function moduleCommand(S, agent, command, args)
  cmdSeq = cmdSeq + 1
  local requestId = "emu-op-" .. cmdSeq
  S.pending.commands[#S.pending.commands + 1] = {
    id = "cmd-" .. cmdSeq,
    command = "MODULE_COMMAND",
    payload = { module_id = "ai_core", command = command, request_id = requestId, args = args or {} },
  }
  S.d:executeCommand(agent, "SEND_HEARTBEAT", {})
  S.d:advance(3000)
  local rec = agent.env.gModuleCommands and agent.env.gModuleCommands[requestId]
  return rec and rec.state, rec and rec.detail, requestId
end

local function heartbeatConfig(S, agent, settings, version)
  S.pending.driver_config = { { driver_sku = "SBOS_AI_CORE", settings = settings, settings_version = version } }
  S.d:executeCommand(agent, "SEND_HEARTBEAT", {})
  S.d:advance(3000)
end

-- ════════════════════════════════════════════════════════════════════════════
local S = newDirector()
local d = S.d
local room = d:addRoom("Equipment")
local kitchen = d:addRoom("Kitchen")
local agent = assert(d:addDevice(OUT .. "/smartbuildos", { roomId = room, name = "SmartBuildOS" }))
d:setProperty(agent, "Automatic Updates", "Off")
d:advance(1000)
d:setProperty(agent, "Pairing Code", "ABCD-2345")
d:advance(5000)
-- No reload here: the Agent is paired at run time and must register for
-- Director system events on that transition (it used to do so only in a
-- LateInit that found it already paired; this scenario then needed a reload).
print("[0] an Agent paired while running hears Director system events")
local heard0 = (agent.env.gSystemEventCounts or {}).OnItemAdded or 0
d:fireSystemEvent(7, '<event name="OnItemAdded" id="7"/>')
d:advance(1000)
check(
  "the run-time-paired Agent received OnItemAdded without a reload",
  ((agent.env.gSystemEventCounts or {}).OnItemAdded or 0) == heard0 + 1,
  (agent.env.gSystemEventCounts or {}).OnItemAdded
)

-- Every frame AI Core sends, and where (the equipment-control proof).
local aicId = nil
local fromAic = {}
local partition = false
local duplicatePublish = false
local realSend = d.sendToDevice
d.sendToDevice = function(self, from, id, command, params)
  if aicId ~= nil and from ~= nil and from.id == aicId then
    fromAic[#fromAic + 1] = { to = id, command = command }
  end
  if partition and ((from ~= nil and from.id == agent.id) or id == agent.id) then
    return true -- lost: the Agent is unreachable both ways
  end
  local ok = realSend(self, from, id, command, params)
  if duplicatePublish and command == "SBOS_MODULE_PUBLISH" and id == aicId then
    duplicatePublish = false
    realSend(self, from, id, command, params) -- the same frame delivered twice
  end
  return ok
end

print("[1] startup and registration: Agent + Flight Recorder + AI Core")
local fr = assert(d:addDevice(OUT .. "/smartbuildos-flight-recorder", { roomId = room, name = "Flight Recorder" }))
local aic = assert(d:addDevice(OUT .. "/smartbuildos-ai-core", { roomId = room, name = "AI Core" }))
aicId = aic.id
-- A second AI Core instance, added and removed: it gives the Kitchen a
-- device id (run_diagnostic below asks for a room with no history), and it
-- is the case the Agent's licence inventory used to get wrong — it kept ONE
-- device id per SKU, so removing this instance dropped SBOS_AI_CORE for the
-- first one, which stays installed. It now keeps the set of instances.
local lamp = assert(d:addDevice(OUT .. "/smartbuildos-ai-core", { roomId = kitchen, name = "Stand-in device" }))
d:advance(1000)
local lampId = lamp.id
d:removeDevice(lamp)
d:advance(10000)
check("Agent paired against the scripted cloud", agent.env.gModules ~= nil and agent.env.gBus ~= nil)
check("both modules registered with the Agent", agent.env.gModules:count() == 2, agent.env.gModules:count())
check("AI Core AI_STATUS ready", var(aic, "AI_STATUS") == "ready", var(aic, "AI_STATUS"))
check(
  "AGENT_CONNECTED true",
  var(aic, "AGENT_CONNECTED") == "1" or var(aic, "AGENT_CONNECTED") == "true",
  var(aic, "AGENT_CONNECTED")
)
check(
  "Connection Status Connected",
  aic.Properties["SmartBuildOS Connection Status"] == "Connected",
  aic.Properties["SmartBuildOS Connection Status"]
)
check("Agent Pairing Status Paired", aic.Properties["Agent Pairing Status"] == "Paired")
-- Activation: nothing pressed. AI Core registered its SKU with the Agent,
-- the Agent inventoried it and asked the cloud by itself (10 s debounce).
local asked = false
for _, r in ipairs(S.cloud.requests) do
  if r.path == "/api/driver-cloud/entitlements/refresh" and type(r.body) == "table" then
    for _, item in ipairs(r.body.installed or {}) do
      asked = asked or (item.sku == "SBOS_AI_CORE" and tonumber(item.device_id) == aic.id)
    end
  end
end
check(
  "activation: the Agent asked the cloud for SBOS_AI_CORE on its own",
  asked,
  (function()
    local seen = {}
    for _, r in ipairs(S.cloud.requests) do
      if r.path == "/api/driver-cloud/entitlements/refresh" then
        seen[#seen + 1] = json.encode(r.body)
      end
    end
    return table.concat(seen, " || ")
  end)()
)
check(
  "activation: licensed before anyone pressed anything",
  aic.Properties["License Status"] == "Licensed / Subscribed",
  aic.Properties["License Status"]
)
local refreshesBefore = #S.cloud.requests
d:executeCommand(agent, "REFRESH_ENTITLEMENTS", {})
d:advance(5000)
local keptFor, sawLamp = nil, false
for i = refreshesBefore + 1, #S.cloud.requests do
  local r = S.cloud.requests[i]
  if r.path == "/api/driver-cloud/entitlements/refresh" and type(r.body) == "table" then
    for _, item in ipairs(r.body.installed or {}) do
      if item.sku == "SBOS_AI_CORE" then
        keptFor = tonumber(item.device_id)
        sawLamp = sawLamp or tonumber(item.device_id) == lampId
      end
    end
  end
end
check(
  "a second instance removed: SBOS_AI_CORE stays inventoried, under the instance that remains",
  keptFor == aic.id and not sawLamp,
  tostring(keptFor) .. " (AI Core " .. tostring(aic.id) .. ", removed " .. tostring(lampId) .. ")"
)
check(
  "licence answered through the real Agent (signed assertion)",
  aic.Properties["License Status"] == "Licensed / Subscribed",
  aic.Properties["License Status"]
)

print("[2] discovery with the Flight Recorder → subscription")
check(
  "Flight Recorder Link: local history served, topics subscribed",
  tostring(aic.Properties["Flight Recorder Link"]):find("topics subscribed") ~= nil,
  aic.Properties["Flight Recorder Link"]
)
check(
  "the Agent holds AI Core's one subscription",
  agent.env.gBus:health().subscriptions == 1,
  agent.env.gBus:health().subscriptions
)

print("[3] subscription and delivery (Flight Recorder → Agent → AI Core)")
local c0 = diagnostics(d, aic)
d:executeCommand(fr, "RECORD_EVENT", { NAME = "Good Night pressed", DETAIL = "hall keypad" })
d:advance(5000)
local c1 = diagnostics(d, aic)
check(
  "AI Core consumed the recorder's event",
  (c1.collector_consumed or 0) == (c0.collector_consumed or 0) + 1,
  tostring(c1.collector_consumed)
)
duplicatePublish = true
d:executeCommand(fr, "RECORD_EVENT", { NAME = "Second marker" })
d:advance(5000)
local c2 = diagnostics(d, aic)
check(
  "a PUBLISH frame delivered twice is consumed once (dedup by event id)",
  c2.collector_consumed == c1.collector_consumed + 1 and (c2.collector_duplicate or 0) >= 1,
  tostring(c2.collector_duplicate)
)
d:advance(35000)
local frMarks = cloudEnvelopes(S, "observation.programmed")
check("the recorder's events reach the cloud once, through the recorder", #frMarks == 2, #frMarks)
local aiCopies = 0
for _, e in ipairs(cloudEnvelopes(S)) do
  if e.module_id == "ai_core" and tostring(e.event_type):find("^observation") then
    aiCopies = aiCopies + 1
  end
end
check("AI Core did not upload a second copy (no double capture)", aiCopies == 0)

print("[4] each Composer command → envelope + cloud request")
local commands = {
  { "AI_ASK", { QUESTION = "Why did the hall light turn on at 3 am?" }, "ask" },
  { "AI_ANALYZE_ROOM", { ROOM = "Equipment" }, "analyze_room" },
  { "AI_ANALYZE_SYSTEM", {}, "analyze_system" },
  { "AI_SET_CONTEXT", { KEY = "Vacation", VALUE = "until 2027-01-20" }, "set_context" },
  { "AI_LEARN_PREFERENCE", { STATEMENT = "Hall light at 20% at night" }, "learn_preference" },
  { "AI_SUGGEST_SCENE", { ROOM = "Equipment", OCCASION = "rack maintenance" }, "suggest_scene" },
  { "AI_GENERATE_REPORT", { TYPE = "System Health", PERIOD = "Last 7 Days" }, "generate_report" },
  { "AI_SEND_NOTIFICATION", { TITLE = "Test", MESSAGE = "Emulator", AUDIENCE = "Integrator" }, "send_notification" },
}
-- What rpc/ops.ts answers per op: a job for most; set_context and
-- send_notification are done at once ({accepted: true, job_id: null}; a
-- JSON null arrives as an absent key); learn_preference is unsupported.
S.rpc.answer = function(body)
  if body.op == "set_context" then
    return { ok = true, result = { accepted = true, applied = true, key = body.body.key } }
  elseif body.op == "send_notification" then
    return { ok = true, result = { accepted = true, sent = { audience = body.body.audience } } }
  elseif body.op == "learn_preference" then
    return { ok = false, error_code = "unsupported", result = { op = "learn_preference" } }
  end
  return nil
end
local done0 = diagnostics(d, aic).cloud_completed or 0
for _, c in ipairs(commands) do
  local n = #S.rpc.calls
  d:executeCommand(aic, c[1], c[2])
  d:advance(3000)
  local call = S.rpc.calls[#S.rpc.calls]
  check(
    c[1] .. " → POST modules/rpc op " .. c[3] .. " as ai_core, with an idempotency key",
    #S.rpc.calls == n + 1
      and call.op == c[3]
      and call.module_id == "ai_core"
      and call.idempotency_key == call.body.request_id,
    call and call.op
  )
  d:advance(7000) -- under the local 10/min command budget
end
d:executeCommand(aic, "AI_RECORD_EVENT", { NAME = "Rack fan replaced", CATEGORY = "Maintenance" })
d:advance(40000)
local cmds = cloudEnvelopes(S, "ai_core.command")
check("an ai_core.command envelope per cloud command reached the cloud", #cmds >= #commands, #cmds)
check("AI_RECORD_EVENT → ai_core.record through the durable event path", #cloudEnvelopes(S, "ai_core.record") == 1)
check("AI_STATUS working (jobs accepted, results pending)", var(aic, "AI_STATUS") == "working", var(aic, "AI_STATUS"))
local ctxCall
for _, call in ipairs(S.rpc.calls) do
  if call.op == "set_context" then
    ctxCall = call
  end
end
check(
  "set_context body names the key `key`, as rpc/ops.ts validates it",
  ctxCall ~= nil and ctxCall.body.key == "vacation" and ctxCall.body.context_key == nil,
  ctxCall and json.encode(ctxCall.body)
)
local dc = diagnostics(d, aic)
check(
  "set_context and send_notification answered without a job: completed, not waited for",
  dc.cloud_completed == done0 + 2 and tostring(dc.jobs_dropped) == "0",
  tostring(dc.cloud_completed)
)
S.rpc.answer = function()
  return { ok = false, error_code = "not_permitted" }
end
d:advance(61000)
d:executeCommand(aic, "AI_ASK", { QUESTION = "Open the garage" })
d:advance(3000)
check(
  "a platform refusal is shown as it is (Last Error)",
  tostring(aic.Properties["Last Error"]):find("not_permitted") ~= nil,
  aic.Properties["Last Error"]
)
check(
  "…and in AI Status",
  tostring(aic.Properties["AI Status"]):find("refused %(not_permitted%)") ~= nil,
  aic.Properties["AI Status"]
)
S.rpc.answer = nil

print("[5] deliver_result and raise_event through the Agent's MODULE_COMMAND")
local resp0 = firedCount(d, aic, 1)
local job = S.rpc.calls[1]
local state, detail = moduleCommand(S, agent, "deliver_result", {
  response_id = "resp-1",
  request_id = job.body.request_id,
  job_id = "job-1",
  text = "The hall light came on at 03:02 after the motion sensor; no programming trace says why.",
})
check("deliver_result Completed (Agent ledger)", state == "Completed", tostring(state) .. " " .. tostring(detail))
check(
  "AI_LAST_RESPONSE / _ID set",
  var(aic, "AI_LAST_RESPONSE_ID") == "resp-1" and tostring(var(aic, "AI_LAST_RESPONSE")):find("03:02") ~= nil
)
check("AI Response Ready fired", firedCount(d, aic, 1) == resp0 + 1)
local p0 = firedCount(d, aic, 2)
state =
  moduleCommand(S, agent, "raise_event", { event = "pattern_detected", detail = "hall light 03:00 on 4 of 7 nights" })
check("raise_event pattern_detected → Pattern Detected", state == "Completed" and firedCount(d, aic, 2) == p0 + 1)
check("AI_LAST_EVENT_DETAIL", tostring(var(aic, "AI_LAST_EVENT_DETAIL")):find("4 of 7") ~= nil)
local a0 = firedCount(d, aic, 6)
local ACTION = "0d6f9a2e-5b1c-4c8e-9f00-123456789abc"
state = moduleCommand(S, agent, "raise_event", {
  event = "approval_required",
  detail = "AI Core action awaiting approval: lights.set_level",
  correlation_id = ACTION,
})
check(
  "raise_event WITH correlation_id (as the actions service sends it) → Completed, Approval Required",
  state == "Completed" and firedCount(d, aic, 6) == a0 + 1,
  state
)
check(
  "AI_LAST_CORRELATION_ID = the action id",
  var(aic, "AI_LAST_CORRELATION_ID") == ACTION,
  var(aic, "AI_LAST_CORRELATION_ID")
)
d:advance(40000)
local raised = cloudEnvelopes(S, "ai_core.event")
check(
  "the ai_core.event envelope reached the cloud carrying it as its correlation_id",
  #raised >= 1 and raised[#raised].correlation_id == ACTION and raised[#raised].payload.event == "approval_required",
  #raised
)
local before = #d.eventLog
state = moduleCommand(S, agent, "raise_event", { event = "unlock_front_door" })
check(
  "raise_event outside the closed list → Failed, nothing fired",
  state == "Failed" and #d.eventLog == before,
  state
)
state = moduleCommand(S, agent, "raise_event", { event = "agent_disconnected" })
check("Agent Disconnected cannot be raised by the platform", state == "Failed")

print("[6] configuration apply / refuse (SBOS_DRIVER_CONFIG through the Agent)")
heartbeatConfig(S, agent, {
  schema = 1,
  learning = { active = true },
  exclusions = { rooms = {}, categories = { "security" } },
  permission_mode = "recommend",
  provider = { name = "Anthropic", model = "claude-opus" },
  credential_status = "Configured in System Studio · Anthropic ••••abcd",
  property_id = "property-1",
}, 4)
check(
  "applied: AI Provider, Permission Mode, credential STATUS",
  aic.Properties["AI Provider"] == "Anthropic"
    and tostring(aic.Properties["Permission Mode"]):find("^recommend")
    and tostring(aic.Properties["AI API Credential"]):find("••••abcd")
)
heartbeatConfig(S, agent, { schema = 1, provider = { name = "OpenAI", api_key = "sk-proj-0123456789abcdef" } }, 5)
check(
  "a document with a key in it is refused whole; v4 kept",
  aic.Properties["AI Provider"] == "Anthropic" and tostring(aic.Properties["Last Error"]):find("v5 refused") ~= nil,
  aic.Properties["Last Error"]
)
local reg = agent.env.gModules:instances("ai_core")[1]
check(
  "the Agent's registry shows applied v4 and the v5 refusal (for Studio)",
  reg ~= nil and reg.applied_config_version == "4" and tostring(reg.config_error):find("v5") ~= nil,
  reg and (tostring(reg.applied_config_version) .. " / " .. tostring(reg.config_error))
)

print("[7] exclusions and pause suppress collection")
heartbeatConfig(S, agent, { schema = 1, learning = { active = false }, provider = { name = "Anthropic" } }, 6)
check(
  "LEARNING_ACTIVE false",
  var(aic, "LEARNING_ACTIVE") == "0" or var(aic, "LEARNING_ACTIVE") == "false",
  var(aic, "LEARNING_ACTIVE")
)
d:advance(3000)
check(
  "paused: the subscription is released",
  agent.env.gBus:health().subscriptions == 0,
  agent.env.gBus:health().subscriptions
)
local sys0 = #cloudEnvelopes(S, "ai_core.observation.system")
d:fireSystemEvent(49, '<event name="OnDeviceOffline" id="49"/>')
d:executeCommand(aic, "AI_RECORD_EVENT", { NAME = "while paused" })
d:advance(40000)
check("paused: no system event recorded", #cloudEnvelopes(S, "ai_core.observation.system") == sys0)
check(
  "paused: AI_RECORD_EVENT not recorded, said so",
  #cloudEnvelopes(S, "ai_core.record") == 1 and tostring(aic.Properties["Last Error"]):find("paused") ~= nil,
  aic.Properties["Last Error"]
)
heartbeatConfig(S, agent, { schema = 1, learning = { active = true }, exclusions = { categories = { "system" } } }, 7)
d:fireSystemEvent(49, '<event name="OnDeviceOffline" id="49"/>')
d:advance(40000)
check("excluded category: still not recorded", #cloudEnvelopes(S, "ai_core.observation.system") == sys0)
heartbeatConfig(S, agent, { schema = 1, learning = { active = true } }, 8)
d:fireSystemEvent(49, '<event name="OnDeviceOffline" id="49"/>')
d:advance(40000)
check("active, nothing excluded: recorded", #cloudEnvelopes(S, "ai_core.observation.system") == sys0 + 1)
check("subscribed again on resume", agent.env.gBus:health().subscriptions == 1)

print("[8] local diagnostics with the Flight Recorder (incl. its real ring)")
d:executeCommand(fr, "RECORD_EVENT", { NAME = "Rack temperature high", DEVICE = tostring(agent.id) })
d:advance(5000)
d:executeCommand(aic, "AI_START_DIAGNOSTIC", { DEVICE = tostring(agent.id) })
d:advance(40000)
local diags = cloudEnvelopes(S, "ai_core.diagnostic")
local dg = diags[#diags]
local frMark = nil
for _, e in ipairs(cloudEnvelopes(S, "observation.programmed")) do
  if e.label == "Rack temperature high" then
    frMark = e
  end
end
check("an ai_core.diagnostic envelope reached the cloud", dg ~= nil)
check(
  "it carries the recorder's local event with the id the cloud stores",
  dg
    and dg.payload.flight_recorder.available == true
    and frMark ~= nil
    and dg.payload.flight_recorder.events[1].event_id == frMark.event_id,
  dg and json.encode(dg.payload.flight_recorder):sub(1, 200)
)
local sd = S.rpc.calls[#S.rpc.calls]
check(
  "start_diagnostic cites the diagnostic envelope",
  sd.op == "start_diagnostic" and sd.body.diagnostic_event_id == dg.event_id
)
moduleCommand(S, agent, "run_diagnostic", { room_id = kitchen })
d:advance(5000)
local rec2 = agent.env.gModuleCommands[("emu-op-" .. cmdSeq)]
check(
  "run_diagnostic on a room with no history: Completed, 0 local events (empty ring answer)",
  rec2 and rec2.state == "Completed" and tostring(rec2.detail):find("0 local event") ~= nil,
  rec2 and (rec2.state .. " " .. tostring(rec2.detail))
)

print("[9] discovery without the Flight Recorder")
d:removeDevice(fr)
d:advance(20000)
check(
  "Flight Recorder Link: not installed",
  tostring(aic.Properties["Flight Recorder Link"]):find("Not installed") ~= nil,
  aic.Properties["Flight Recorder Link"]
)
d:advance(61000)
d:executeCommand(aic, "AI_START_DIAGNOSTIC", { ROOM = "Equipment" })
d:advance(40000)
diags = cloudEnvelopes(S, "ai_core.diagnostic")
dg = diags[#diags]
check(
  "absent recorder: the diagnostic says so instead of failing",
  dg.payload.flight_recorder.available == false and dg.payload.flight_recorder.reason == "flight_recorder_not_installed",
  dg.payload.flight_recorder.reason
)
local ag0 = #cloudEnvelopes(S, "ai_core.observation.agent")
d:fireSystemEvent(48, '<event name="OnDeviceOnline" id="48"/>')
-- An Agent-classified event: the Agent turns a project edit into
-- `project_changed` for every module (debounced 30 s).
d:fireSystemEvent(7, '<event name="OnItemAdded" id="7"/>')
d:advance(80000)
check(
  "absent recorder: AI Core records the documented system event itself",
  #cloudEnvelopes(S, "ai_core.observation.system") >= sys0 + 2
)
check(
  "absent recorder: AI Core records the Agent's classified event itself",
  #cloudEnvelopes(S, "ai_core.observation.agent") > ag0,
  #cloudEnvelopes(S, "ai_core.observation.agent") - ag0
)
fr = assert(d:addDevice(OUT .. "/smartbuildos-flight-recorder", { roomId = room, name = "Flight Recorder" }))
d:advance(20000)
check(
  "recorder re-added → found and subscribed again",
  tostring(aic.Properties["Flight Recorder Link"]):find("topics subscribed") ~= nil
    and agent.env.gBus:health().subscriptions == 1,
  aic.Properties["Flight Recorder Link"]
)

print("[10] Agent restart (driver update): hello → re-register → re-subscribe")
local disc0 = firedCount(d, aic, 9)
d:updateDriver(agent)
d:advance(15000)
check("Agent Disconnected fired when the registration was lost", firedCount(d, aic, 9) == disc0 + 1)
check(
  "re-registered: AGENT_CONNECTED true again",
  var(aic, "AGENT_CONNECTED") == "1" or var(aic, "AGENT_CONNECTED") == "true"
)
check(
  "re-subscribed on the reloaded Agent",
  agent.env.gBus:health().subscriptions == 1,
  agent.env.gBus:health().subscriptions
)

print("[11] the Agent unreachable: buffer → ordered flush, counted drops")
partition = true
d:advance(5 * 60 * 1000 + 20000)
check("AI_STATUS agent_lost", var(aic, "AI_STATUS") == "agent_lost", var(aic, "AI_STATUS"))
check("Agent Disconnected fired", firedCount(d, aic, 9) == disc0 + 2)
for _ = 1, 55 do
  d:fireSystemEvent(49, '<event name="OnDeviceOffline" id="49"/>')
end
local held = persisted(aic, "aicore_buffer_v1")
check("critical events persisted in the buffer, bounded at 50", held and #held.items == 50, held and #held.items)
check("the overflow is counted", held and held.dropped >= 6, held and held.dropped)
local cloudBefore = #cloudEnvelopes(S)
partition = false
d:advance(60000)
d:advance(40000)
local flushed = {}
local all = cloudEnvelopes(S)
for i = cloudBefore + 1, #all do
  if
    all[i].module_id == "ai_core"
    and (all[i].event_type == "ai_core.observation.system" or all[i].event_type == "ai_core.status")
  then
    flushed[#flushed + 1] = all[i]
  end
end
check("the buffered events reached the cloud after recovery", #flushed >= 50, #flushed)
local ordered = true
for i = 2, #flushed do
  ordered = ordered and flushed[i].sequence > flushed[i - 1].sequence
end
check("in order", ordered)
check("buffer empty again", #persisted(aic, "aicore_buffer_v1").items == 0)
check("AGENT_CONNECTED true", var(aic, "AGENT_CONNECTED") == "1" or var(aic, "AGENT_CONNECTED") == "true")

print("[12] controller restart")
local lastSeq = 0
for _, e in ipairs(cloudEnvelopes(S)) do
  if e.module_id == "ai_core" then
    lastSeq = math.max(lastSeq, e.sequence)
  end
end
d:restart()
d:advance(30000)
check(
  "AI Core back: ready, configuration v8 kept",
  (var(aic, "AI_STATUS") == "ready" or var(aic, "AI_STATUS") == "working") and aic.Properties["AI Provider"] ~= nil,
  var(aic, "AI_STATUS")
)
check("AI_LAST_RESPONSE_ID survived", var(aic, "AI_LAST_RESPONSE_ID") == "resp-1", var(aic, "AI_LAST_RESPONSE_ID"))
d:advance(61000)
d:executeCommand(aic, "AI_RECORD_EVENT", { NAME = "after restart" })
d:advance(40000)
local newMax, dup, seen = 0, 0, {}
for _, e in ipairs(cloudEnvelopes(S)) do
  if e.module_id == "ai_core" then
    if seen[e.event_id] then
      dup = dup + 1
    end
    seen[e.event_id] = true
    newMax = math.max(newMax, e.sequence)
  end
end
check("event sequence continues after the restart", newMax > lastSeq)
check("no AI Core event id reached the cloud twice in the whole run", dup == 0, dup)

print("[13] licence expiry and grace (real signed assertions, enforcement from the refresh)")
S.pending.enforcement = { SBOS_AI_CORE = "enforce" }
S.cloud.catalog.SBOS_AI_CORE.status = "ENTITLEMENT_EXPIRED"
d:executeCommand(agent, "REFRESH_ENTITLEMENTS", {})
d:advance(40000)
check("expired + enforce → AI_STATUS unlicensed", var(aic, "AI_STATUS") == "unlicensed", var(aic, "AI_STATUS"))
local n = #S.rpc.calls
d:advance(61000)
d:executeCommand(aic, "AI_ASK", { QUESTION = "still there?" })
d:advance(3000)
check(
  "unlicensed: the command is refused, nothing sent",
  #S.rpc.calls == n and tostring(aic.Properties["Last Error"]):find("not licensed") ~= nil,
  aic.Properties["Last Error"]
)
S.cloud.catalog.SBOS_AI_CORE.status = "AUTHORIZED_GRACE"
d:executeCommand(agent, "REFRESH_ENTITLEMENTS", {})
d:advance(40000)
check(
  "grace → operational again",
  var(aic, "AI_STATUS") == "ready" or var(aic, "AI_STATUS") == "working",
  var(aic, "AI_STATUS")
)

-- ── licensing end to end, real Agent + real signatures (EMULATOR ONLY) ──────
local digest = require("director.digest")
local aicAsk = aic.env.EC.AI_ASK -- a reload would build a new one
local function refresh()
  d:executeCommand(agent, "REFRESH_ENTITLEMENTS", {})
  d:advance(40000)
end
local function aiStatus()
  return var(aic, "AI_STATUS")
end
local function operational()
  return aiStatus() ~= "unlicensed" and aiStatus() ~= "no_agent"
end
--- Sends one BASE command; true when it reached the rpc route.
local function commandGoes()
  d:advance(61000)
  local n = #S.rpc.calls
  d:executeCommand(aic, "AI_ANALYZE_SYSTEM", {})
  d:advance(3000)
  return #S.rpc.calls == n + 1
end
--- Re-signs AI Core's assertion in the refresh answer as `fields`, with `secret`.
local function resign(secret, fields)
  return function(body)
    for _, a in ipairs(body.assertions or {}) do
      if a.driver_sku == "SBOS_AI_CORE" then
        for k, v in pairs(fields) do
          a[k] = v
        end
        local canonical = table.concat({
          "1",
          a.sig_alg,
          a.company_id,
          a.controller_id,
          a.driver_sku,
          a.status,
          a.license_type,
          table.concat(a.features, ","),
          a.issued_at,
          "",
          "",
        }, "|")
        a.sig = digest.tohex(digest.hmac("SHA256", secret, canonical))
      end
    end
  end
end
local GRANT_ALL = {
  status = "AUTHORIZED_PERPETUAL",
  license_type = "PERPETUAL",
  features = { "BASE", "AI_LEARNING", "AI_ACTIONS", "AI_CONCIERGE" },
}
S.cloud.catalog.SBOS_AI_CORE.status = "AUTHORIZED_SUBSCRIPTION"

print("[13a] a controller-bound assertion is accepted")
S.pending.refreshEdit = resign(S.cloud.secret, GRANT_ALL)
refresh()
check(
  "signed for this controller: Licensed / Permanent",
  aic.Properties["License Status"] == "Licensed / Permanent" and operational(),
  aic.Properties["License Status"]
)

print("[13b] an assertion for another controller is refused")
local other = { controller_id = "controller-0002" }
for k, v in pairs(GRANT_ALL) do
  other[k] = v
end
S.pending.refreshEdit = resign("another-controllers-secret-00000000", other)
refresh()
check(
  "signed with another controller's secret: not honoured (the Agent drops it at fetch)",
  aic.Properties["License Status"] ~= "Licensed / Permanent",
  aic.Properties["License Status"]
)
check(
  "…AI Core falls back to the no-assertion status (LEGACY), as the Agent answers today",
  aic.Properties["License Status"] == "Licensing Not Yet Enforced",
  aic.Properties["License Status"]
)
S.pending.refreshEdit = nil
S.cloud.catalog.SBOS_AI_CORE.status = "CONTROLLER_MISMATCH"
S.cloud.catalog.SBOS_AI_CORE.features = {}
refresh()
check(
  "server-issued CONTROLLER_MISMATCH (signed, enforced): unlicensed, read-only",
  aiStatus() == "unlicensed"
    and aic.Properties["License Status"] == "License Registered To Another Controller (read-only)",
  aic.Properties["License Status"]
)
check(
  "…commands refused, the reason named, nothing sent",
  not commandGoes() and tostring(aic.Properties["Last Error"]):find("Another Controller") ~= nil,
  aic.Properties["Last Error"]
)
S.cloud.catalog.SBOS_AI_CORE.status = "AUTHORIZED_SUBSCRIPTION"
S.cloud.catalog.SBOS_AI_CORE.features = { "BASE", "AI_LEARNING" }
refresh()

print("[13c] signature tampering is refused")
S.cloud.tamper.SBOS_AI_CORE = true
S.cloud.catalog.SBOS_AI_CORE.status = "AUTHORIZED_PERPETUAL"
refresh()
check(
  "a tampered assertion is not honoured (no Licensed / Permanent)",
  aic.Properties["License Status"] == "Licensing Not Yet Enforced",
  aic.Properties["License Status"]
)
S.cloud.tamper.SBOS_AI_CORE = nil
S.cloud.catalog.SBOS_AI_CORE.status = "AUTHORIZED_SUBSCRIPTION"
refresh()
check("a correctly signed one is honoured again", aic.Properties["License Status"] == "Licensed / Subscribed")

print("[13d] cache → grace → cloud validation required (virtual time, cloud down)")
--- Moves the controller's wall clock (timers then fire once, late).
local function jump(ms)
  d.clock.epochMs = d.clock.epochMs + ms
  d.clock.tickMs = d.clock.tickMs + ms
  d:advance(5000)
end
S.cloud.down = true
jump(8 * 86400 * 1000)
d:advance(3600 * 1000) -- the Agent's hourly licence tick
check(
  "day 8 offline: the Agent rides grace",
  tostring(agent.Properties["License Cloud"]):find("^Offline %- riding grace until") ~= nil,
  agent.Properties["License Cloud"]
)
check(
  "day 8: AI Core told Licensed / Grace (dated) without a refresh",
  tostring(aic.Properties["License Status"]):find("^Licensed / Grace %(until") ~= nil,
  aic.Properties["License Status"]
)
check("day 8: AI Core operational (commands go)", operational() and commandGoes(), aiStatus())
jump(3 * 86400 * 1000)
d:advance(3600 * 1000)
check(
  "day 11: Cloud Validation Required",
  aic.Properties["License Status"] == "Cloud Validation Required",
  aic.Properties["License Status"]
)
check("day 11: never bricked (not unlicensed; commands go)", operational() and commandGoes(), aiStatus())

print("[13e] renewal restores service without a reload")
S.cloud.down = false
refresh()
check("cloud back: Licensed / Subscribed", aic.Properties["License Status"] == "Licensed / Subscribed")
check("…operational, commands go", operational() and commandGoes(), aiStatus())
check("…AI Core was not reloaded", aic.env.EC.AI_ASK == aicAsk)

print("[13f] clock skew is flagged, never enforced")
S.pending.refreshEdit = function(body)
  body.checked_at = os.date("!%Y-%m-%dT%H:%M:%S.000Z", math.floor(d.clock:now() / 1000) - 3 * 86400)
end
refresh()
local skewReported = false
for _, e in ipairs(S.cloud.events) do
  skewReported = skewReported or e.code == "clock_skew"
end
check("the Agent reports the skew to SmartBuildOS (clock_skew licence event)", skewReported)
check(
  "AI Core stays licensed and operational",
  aic.Properties["License Status"] == "Licensed / Subscribed" and commandGoes()
)
S.pending.refreshEdit = nil

print("[13g] transfer: revoked on this controller, then granted again")
-- After the platform's licence transfer closes this controller's row, the
-- next refresh signs NOT_ENTITLED here (decideCatalogEntitlement).
S.cloud.catalog.SBOS_AI_CORE = { status = "NOT_ENTITLED", license_type = "", features = {} }
refresh()
check(
  "moved away: unlicensed, commands refused",
  aiStatus() == "unlicensed" and not commandGoes(),
  aic.Properties["License Status"]
)
S.cloud.catalog.SBOS_AI_CORE = GRANT_ALL
refresh()
check(
  "granted again: Licensed / Permanent, commands go, no reload",
  aic.Properties["License Status"] == "Licensed / Permanent" and commandGoes() and aic.env.EC.AI_ASK == aicAsk,
  aic.Properties["License Status"]
)

print("[14] no equipment control reachable")
local outsiders = {}
for _, f in ipairs(fromAic) do
  if f.to ~= agent.id then
    outsiders[#outsiders + 1] = tostring(f.to) .. ":" .. f.command
  end
end
check(
  "every SendToDevice AI Core made in the run went to the Agent (" .. #fromAic .. " frames)",
  #fromAic > 0 and #outsiders == 0,
  table.concat(outsiders, ",")
)

print("[15] runtime errors")
local errs = #agent.errors + #fr.errors + #aic.errors
check(
  "no Lua runtime errors in the Agent, Flight Recorder or AI Core",
  errs == 0,
  agent.errors[1] or fr.errors[1] or aic.errors[1]
)

-- ════════════════════════════════════════════════════════════════════════════
print("[16] a v1-only Agent (git " .. "7db22e7, before module contract v2)")
local V1 = newDirector("-v1")
local dv = V1.d
local r2 = dv:addRoom("Equipment")
local agent1 = assert(dv:addDevice(OUT .. "/v1/smartbuildos", { roomId = r2, name = "SmartBuildOS" }))
dv:setProperty(agent1, "Automatic Updates", "Off")
dv:advance(1000)
dv:setProperty(agent1, "Pairing Code", "ABCD-2345")
dv:advance(5000)
local aic1 = assert(dv:addDevice(OUT .. "/smartbuildos-ai-core", { roomId = r2, name = "AI Core" }))
dv:advance(10000)
check(
  "registered at protocol 1 → AI_STATUS agent_update_required",
  var(aic1, "AI_STATUS") == "agent_update_required",
  var(aic1, "AI_STATUS")
)
check(
  "Connection Status says the Agent must be updated",
  tostring(aic1.Properties["SmartBuildOS Connection Status"]):find("update required") ~= nil,
  aic1.Properties["SmartBuildOS Connection Status"]
)
dv:executeCommand(aic1, "AI_ASK", { QUESTION = "hello?" })
dv:advance(20000)
check(
  "AI_ASK refused locally; no rpc POST",
  #V1.rpc.calls == 0 and tostring(aic1.Properties["Last Error"]):find("updated") ~= nil,
  aic1.Properties["Last Error"]
)
dv:executeCommand(aic1, "AI_RECORD_EVENT", { NAME = "v1 still records" })
dv:advance(40000)
check(
  "v1 services still work: the record reached the cloud through the v1 Agent",
  #cloudEnvelopes(V1, "ai_core.record") == 1
)
check("no runtime errors (v1 Agent, AI Core)", #agent1.errors + #aic1.errors == 0, agent1.errors[1] or aic1.errors[1])

print(string.format("\nEMULATOR ONLY: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
