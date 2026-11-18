-- SmartBuildOS AI Core DRIVER under the shim with a scripted Agent
-- (test/aicore_harness.lua). SIMULATION ONLY: no controller, no real Agent
-- (the emulator scenario test/emulator/ai_core.lua runs the real one).
--
--   [1]  start with no Agent: degraded, critical status events buffered
--   [2]  the Agent appears: registration contract, buffer flushed in order
--   [3]  Flight Recorder discovered → subscribed to its topics (D7)
--   [4]  consumed events: dedup, exclusions, nothing re-uploaded
--   [5]  every Composer command → envelope + cloud op (idempotency key)
--   [6]  local validation refuses before anything is sent
--   [7]  cloud refusals surfaced truthfully
--   [8]  deliver_result → variables + AI Response Ready
--   [9]  raise_event: closed list
--   [10] configuration: apply, refuse (whole document), keep last valid
--   [11] exclusions and pause suppress collection
--   [12] Flight Recorder absent: own minimal collector
--   [13] local diagnostics with and without the Flight Recorder
--   [14] Agent stops answering: buffer, counted drops, ordered flush
--   [15] Agent restart: hello → re-register → re-subscribe
--   [16] v1-only Agent: agent_update_required, nothing v2 sent
--   [17] licence: enforced denial, grace, missing feature, uncertain states
--   [18] controller restart: config, learning, results, buffer, sequence
--   [19] no operation path reaches equipment
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

local H = require("aicore_harness")
local A = H.agent
local prop = H.prop

local EV = {
  response = 1,
  pattern = 2,
  recommendation = 3,
  conflict = 4,
  failure = 5,
  approval = 6,
  done = 7,
  failed = 8,
  disconnected = 9,
  provider = 10,
}

print("[1] start with no Agent in the project")
H.load("DIT_ADDING")
H.advance(1000)
check("Driver Status Online", H.props["Driver Status"] == "Online")
check(
  "connection status says no Agent",
  prop("SmartBuildOS Connection Status") == "No SmartBuildOS Agent in this project",
  prop("SmartBuildOS Connection Status")
)
check("AI_STATUS no_agent", H.vars.AI_STATUS == "no_agent", H.vars.AI_STATUS)
check("AGENT_CONNECTED false", H.vars.AGENT_CONNECTED == "false")
check("no register frame without an Agent", #H.sentOf("SBOS_MODULE_REGISTER") == 0)
check(
  "documented system events registered system-wide (device 0)",
  H.sysRegs[48] == 0 and H.sysRegs[49] == 0 and H.sysRegs[17] == 0 and H.sysRegs[90] == 0
)
local undocumented = false
for id in pairs(H.sysRegs) do
  if not ({ [17] = 1, [18] = 1, [19] = 1, [20] = 1, [48] = 1, [49] = 1, [90] = 1 })[id] then
    undocumented = true
  end
end
check("no undocumented system event id registered", not undocumented)
check(
  "the degraded status event is held in the persisted buffer",
  (H.persisted.aicore_buffer_v1 or { items = {} }).items[1] ~= nil
)
check("Learning Status Active by default", prop("Learning Status") == "Active", prop("Learning Status"))
check("AI API Credential: status only, nothing configured", prop("AI API Credential") == "Not configured")
check("Permission Mode read-only, owned by System Studio", prop("Permission Mode"):find("System Studio") ~= nil)

print("[2] the Agent appears")
H.agentPresent = true
H.advance(31000) -- the module client's registration retry
local reg = H.lastSent("SBOS_MODULE_REGISTER")
check("register frame to the Agent", reg ~= nil and reg.device == H.AGENT_ID)
check(
  "registration contract: ai_core, protocol 1..2, SKU, singleton",
  reg.params.module_id == "ai_core"
    and reg.params.protocol_min == "1"
    and reg.params.protocol_max == "2"
    and reg.params.entitlements == "SBOS_AI_CORE"
    and reg.params.singleton == "true"
    and reg.params.event_types == "ai_core."
)
check(
  "registers exactly the six restricted operations",
  reg.params.commands == "apply_config,refresh_status,deliver_result,raise_event,set_learning,run_diagnostic",
  reg.params.commands
)
local manifest = JSON:decode(reg.params.manifest)
check("manifest driver sbos.ai_core, protocol 2", manifest.driver == "sbos.ai_core" and manifest.protocol == 2)
check("AGENT_CONNECTED true", H.vars.AGENT_CONNECTED == "true")
check("AI_STATUS ready", H.vars.AI_STATUS == "ready", H.vars.AI_STATUS)
check("connection Connected", prop("SmartBuildOS Connection Status") == "Connected")
check("pairing Paired", prop("Agent Pairing Status") == "Paired")
local statuses = H.envelopes("ai_core.status")
check("the buffered status event reached the Agent", #statuses >= 1 and statuses[1].payload.state == "no_agent")
check("buffer drained", #((H.persisted.aicore_buffer_v1 or {}).items or {}) == 0)
local ordered = true
for i = 2, #statuses do
  ordered = ordered and statuses[i].sequence > statuses[i - 1].sequence
end
check("status events in sequence order", ordered)
check("licence registered with the Agent", H.lastSent("SBOS_REGISTER_DRIVER").params.sku == "SBOS_AI_CORE")

print("[3] the Flight Recorder is discovered and subscribed to")
local disc = H.lastSent("SBOS_MODULE_DISCOVER")
check(
  "directory asked for flight_recorder",
  disc ~= nil and JSON:decode(disc.params.filter).module_id == "flight_recorder"
)
local sub = H.lastSent("SBOS_MODULE_SUBSCRIBE")
check("subscribed", sub ~= nil and sub.params.subscription_id == "fr")
local topics = sub and JSON:decode(sub.params.topics) or {}
check(
  "exactly capture./observation./trace.",
  #topics == 3 and topics[1] == "capture." and topics[2] == "observation." and topics[3] == "trace."
)
check(
  "Flight Recorder Link reports it",
  prop("Flight Recorder Link"):find("topics subscribed") ~= nil,
  prop("Flight Recorder Link")
)
check("no own variable listeners while FR present", next(H.listeners) == nil)

print("[4] consumed Flight Recorder events")
local function frEvent(n, roomId, category)
  return {
    event_id = "flight_recorder:9001:nb:" .. n,
    schema_version = 1,
    event_type = category and "observation.change" or "capture.event",
    module_id = "flight_recorder",
    room_id = roomId,
    severity = "info",
    evidence_source = "observed",
    quality = "confirmed",
    observed_at = "2027-01-15T08:00:00Z",
    sequence = n,
    payload = { category = category },
  }
end
local recordedBefore = #H.envelopes()
H.publish({ frEvent(1, 3), frEvent(2, 7, "lighting") }, 0)
H.publish({ frEvent(1, 3) }, 4) -- a duplicate after a re-subscribe, and the Agent dropped 4
local core = require("sbos.moduleclient")
local function counters()
  core.sendStatus()
  return JSON:decode(H.lastSent("SBOS_MODULE_STATUS").params.counters)
end
local c4 = counters()
check("two distinct events consumed", c4.collector_consumed == 2, c4.collector_consumed)
check("the repeat is dropped as a duplicate (dedup by event id)", c4.collector_duplicate == 1, c4.collector_duplicate)
check("the Agent's reported drops are counted", c4.collector_consumed_dropped_by_agent == 4)
H.publish({ frEvent(3, 3) }, 0, "forged-token")
check("a PUBLISH with another token is ignored", counters().collector_consumed == 2)
H.advance(3000)
check("nothing re-uploaded: FR events already reach the cloud", #H.envelopes() == recordedBefore)
local frForged = 0
for _, e in ipairs(H.envelopes()) do
  if e.module_id ~= "ai_core" then
    frForged = frForged + 1
  end
end
check("every envelope this driver sends is its own (ai_core)", frForged == 0)

print("[5] every Composer command → envelope + cloud op")
local function command(name, params)
  local before = #A.cloudCalls
  EC[name](params)
  H.advance(2500) -- the module client frames events after 2 s
  return A.cloudCalls[#A.cloudCalls], #A.cloudCalls > before
end
local call, called = command("AI_ASK", { QUESTION = "Why did the garage light turn on at 3 am?", ROOM = "Garage" })
check("AI_ASK → op ask", called and call.op == "ask")
check(
  "body carries question, resolved room, request id",
  call.body.question:find("garage light") and call.body.room_id == 7 and call.body.request_id ~= nil
)
check("idempotency key = the request id", call.idempotency_key == call.body.request_id)
check("AI_LAST_REQUEST_ID set", H.vars.AI_LAST_REQUEST_ID == call.body.request_id)
local cmdEnv = H.envelopes("ai_core.command")
local last = cmdEnv[#cmdEnv]
check(
  "ai_core.command envelope for it",
  last and last.payload.command == "AI_ASK" and last.correlation_id == call.body.request_id
)
check("a request is recorded as requested, never as a result", last.evidence_source == "requested")
check("question text marked unreviewed", last.quality == "unreviewed_text")
check(
  "accepted → AI Status Working, AI_STATUS working",
  H.vars.AI_STATUS == "working" and prop("AI Status"):find("Working") ~= nil,
  prop("AI Status")
)

local expect = {
  { "AI_ANALYZE_ROOM", { ROOM = "3" }, "analyze_room" },
  { "AI_ANALYZE_SYSTEM", {}, "analyze_system" },
  { "AI_SET_CONTEXT", { KEY = "Guests Present", VALUE = "yes, until Sunday" }, "set_context" },
  { "AI_LEARN_PREFERENCE", { STATEMENT = "Kitchen lights at 40% after 10 pm", ROOM = "Kitchen" }, "learn_preference" },
  { "AI_SUGGEST_SCENE", { ROOM = "Kitchen", OCCASION = "dinner party" }, "suggest_scene" },
  { "AI_GENERATE_REPORT", { TYPE = "Device Reliability", PERIOD = "Last 7 Days" }, "generate_report" },
  { "AI_SEND_NOTIFICATION", { TITLE = "Garage", MESSAGE = "Left open", AUDIENCE = "Homeowner" }, "send_notification" },
}
for _, e in ipairs(expect) do
  H.advance(7000) -- stay inside the local command budget (10/min)
  local c, ok = command(e[1], e[2])
  check(e[1] .. " → " .. e[3], ok and c.op == e[3], c and c.op)
end
local ctxCall = nil
for _, c in ipairs(A.cloudCalls) do
  if c.op == "set_context" then
    ctxCall = c
  end
end
check(
  "closed context key normalised",
  ctxCall.body.context_key == "guests_present" and ctxCall.body.value == "yes, until Sunday"
)
local rep = A.cloudCalls[#A.cloudCalls - 1]
check("report type and period normalised", rep.body.type == "device_reliability" and rep.body.period == "last_7_days")
H.advance(7000)
local before = #A.cloudCalls
local recBefore = #H.envelopes("ai_core.record")
EC.AI_RECORD_EVENT({ NAME = "Bedtime routine started", DETAIL = "keypad", ROOM = "Kitchen", CATEGORY = "Lighting" })
H.advance(3000)
local rec = H.envelopes("ai_core.record")
check("AI_RECORD_EVENT → ai_core.record (durable), no cloud op", #rec == recBefore + 1 and #A.cloudCalls == before)
check(
  "record says it is instrumented, not observed",
  rec[#rec].evidence_source == "instrumented" and rec[#rec].payload.category == "lighting"
)

print("[6] local validation refuses before anything is sent")
local function refused(name, params, pattern)
  H.advance(7000)
  local calls, sentN = #A.cloudCalls, #H.sent
  EC[name](params)
  H.advance(100)
  local err = H.vars.AI_LAST_ERROR or ""
  local nothing = #A.cloudCalls == calls
  for i = sentN + 1, #H.sent do
    if H.sent[i].command == "SBOS_MODULE_CLOUD_REQUEST" then
      nothing = false
    end
  end
  check(name .. " refused locally: " .. pattern, nothing and err:find(pattern, 1, true) ~= nil, err)
end
refused("AI_ASK", { QUESTION = "   " }, "QUESTION: is required")
refused("AI_ASK", { QUESTION = string.rep("x", 501) }, "longer than 500")
refused("AI_ASK", { QUESTION = "hi", ROOM = "Ballroom" }, "no room named")
refused("AI_ANALYZE_ROOM", {}, "ROOM: is required")
refused("AI_GENERATE_REPORT", { TYPE = "Everything", PERIOD = "Today" }, "not one of the allowed values")
refused("AI_SET_CONTEXT", { KEY = "door_code", VALUE = "1234" }, "not one of the allowed values")
refused("AI_START_DIAGNOSTIC", {}, "one of them is required")
refused("AI_START_DIAGNOSTIC", { DEVICE = "12", ROOM = "Kitchen" }, "give one, not both")
refused("AI_START_DIAGNOSTIC", { DEVICE = "999" }, "no device 999")
refused("AI_SEND_NOTIFICATION", { TITLE = "x" }, "MESSAGE: is required")
check(
  "AI Status says the last request was refused",
  prop("AI Status"):find("refused locally") ~= nil,
  prop("AI Status")
)
H.advance(61000)
for _ = 1, 10 do
  EC.AI_ANALYZE_SYSTEM({})
end
H.advance(100)
local calls = #A.cloudCalls
EC.AI_ANALYZE_SYSTEM({})
H.advance(100)
check(
  "an 11th command in a minute is refused (rate_limited)",
  #A.cloudCalls == calls and H.vars.AI_LAST_ERROR:find("a minute") ~= nil,
  H.vars.AI_LAST_ERROR
)

print("[7] cloud refusals are surfaced truthfully")
H.advance(61000)
A.cloud = function()
  return { status = "error", http_status = "200", error_code = "not_permitted" }
end
local jobsBefore = H.vars.AI_STATUS
EC.AI_ASK({ QUESTION = "Unlock the front door" })
H.advance(500)
check(
  "Last Error: refused by SmartBuildOS: not_permitted",
  prop("Last Error"):find("refused by SmartBuildOS: not_permitted", 1, true) ~= nil,
  prop("Last Error")
)
check(
  "AI Status: last request refused (not_permitted)",
  prop("AI Status"):find("refused (not_permitted)", 1, true) ~= nil,
  prop("AI Status")
)
check("no job recorded for a refusal", H.vars.AI_STATUS == jobsBefore)
A.cloud = function()
  return { status = "error", http_status = "200", error_code = "unsupported" }
end
EC.AI_SUGGEST_SCENE({ ROOM = "Kitchen", OCCASION = "movie" })
H.advance(500)
check("unsupported surfaced", prop("Last Error"):find("unsupported") ~= nil)
A.cloud = function()
  return { status = "ok", http_status = "200", result = { queued = "maybe" } }
end
EC.AI_ANALYZE_SYSTEM({})
H.advance(500)
check(
  "an answer without accepted is not success",
  prop("Last Error"):find("without accepting") ~= nil,
  prop("Last Error")
)
A.cloud = function()
  return { status = "error", http_status = "", error_code = "cloud_unreachable" }
end
EC.AI_ANALYZE_SYSTEM({})
H.advance(20000) -- retried twice by the client library, same key
check(
  "cloud unreachable after retries → connection status says so",
  prop("SmartBuildOS Connection Status") == "SmartBuildOS cloud unreachable",
  prop("SmartBuildOS Connection Status")
)
local keys = {}
for i = #A.cloudCalls - 2, #A.cloudCalls do
  keys[A.cloudCalls[i].idempotency_key] = true
end
local nKeys = 0
for _ in pairs(keys) do
  nKeys = nKeys + 1
end
check("three attempts, one idempotency key", nKeys == 1)
A.cloud = nil
H.advance(61000)
EC.AI_ANALYZE_SYSTEM({})
H.advance(500)
check("the next accepted answer clears cloud_unreachable", prop("SmartBuildOS Connection Status") == "Connected")

print("[8] deliver_result")
local job = A.cloudCalls[#A.cloudCalls]
local long = string.rep("é", 700) -- 1400 bytes, multi-byte
local states = H.operation("deliver_result", {
  response_id = "resp-42",
  request_id = job.body.request_id,
  job_id = "job-" .. #A.cloudCalls,
  text = long,
  kind = "analysis",
  recommendation_count = 2,
})
check("Completed", H.finalState(states) == "Completed", H.finalState(states))
check("AI_LAST_RESPONSE_ID", H.vars.AI_LAST_RESPONSE_ID == "resp-42")
check(
  "AI_LAST_RESPONSE bounded to 1024 bytes and marked",
  #H.vars.AI_LAST_RESPONSE <= 1024 and H.vars.AI_LAST_RESPONSE:sub(-3) == "..."
)
check("no split UTF-8 sequence", H.vars.AI_LAST_RESPONSE:sub(1, -4):match("[\195]$") == nil)
check("AI Response Ready fired", H.fired_(EV.response))
check("AI_RECOMMENDATION_COUNT", H.vars.AI_RECOMMENDATION_COUNT == 2)
check("conditional RECOMMENDATIONS_AVAILABLE", TC.RECOMMENDATIONS_AVAILABLE() == true)
states = H.operation("deliver_result", { response_id = "r", text = "x", command = "UNLOCK" })
check("an extra argument refuses the whole operation", H.finalState(states) == "Failed")
states = H.operation("deliver_result", { response_id = "r" })
check("no text → Failed", H.finalState(states) == "Failed")

print("[9] raise_event: the closed list")
local map = {
  ai_response_ready = 1,
  pattern_detected = 2,
  recommendation_available = 3,
  automation_conflict_detected = 4,
  device_failure_pattern_detected = 5,
  approval_required = 6,
  action_completed = 7,
  action_failed = 8,
  ai_provider_error = 10,
}
for name, id in pairs(map) do
  local n = H.firedCount(id)
  local st = H.operation("raise_event", { event = name, detail = "detail for " .. name })
  check("raise_event " .. name .. " → event " .. id, H.finalState(st) == "Completed" and H.firedCount(id) == n + 1)
end
check("AI_LAST_EVENT_DETAIL set", H.vars.AI_LAST_EVENT_DETAIL:find("^detail for") ~= nil)
local firedBefore = #H.fired
for _, bad in ipairs({ "agent_disconnected", "OPEN_GARAGE", "AI Response Ready", "", "unlock" }) do
  local st = H.operation("raise_event", { event = bad })
  check("raise_event '" .. bad .. "' refused", H.finalState(st) == "Failed")
end
check("no event fired by a refused raise_event", #H.fired == firedBefore)
H.operation("raise_event", { event = "approval_required", detail = string.rep("d", 900), pending_approvals = 3 })
check("detail bounded to 512", #H.vars.AI_LAST_EVENT_DETAIL == 512)
check(
  "AI_PENDING_APPROVALS = 3 and the conditional",
  H.vars.AI_PENDING_APPROVALS == 3 and TC.APPROVALS_PENDING() == true
)

print("[10] configuration")
local good = {
  schema = 1,
  learning = { active = true },
  exclusions = { rooms = { 9 }, categories = { "security" } },
  permission_mode = "recommend",
  provider = { name = "Anthropic", model = "claude-opus" },
  credential_status = "Configured in System Studio · Anthropic ••••abcd",
  collection = { variables = { { device_id = 12, variable = "LIGHT_STATE" } } },
  property_id = "prop-123",
  controller_id = "ctrl-9",
}
local ack = H.config(good, 7)
check(
  "ACK applied",
  ack.params.applied == "true" and ack.params.settings_version == "7" and ack.params.sku == "SBOS_AI_CORE"
)
check("AI Provider / Model painted", prop("AI Provider") == "Anthropic" and prop("AI Model") == "claude-opus")
check(
  "AI API Credential shows the status string only",
  prop("AI API Credential") == "Configured in System Studio · Anthropic ••••abcd"
)
check("Permission Mode", prop("Permission Mode") == "recommend (set in System Studio)")
check("Property ID / Controller ID", prop("Property ID") == "prop-123" and prop("Controller ID") == "ctrl-9")
local st = H.lastSent("SBOS_MODULE_STATUS")
check(
  "status frame reports applied_config_version 7",
  st.params.applied_config_version == "7",
  st.params.applied_config_version
)
local bad = JSON:decode(JSON:encode(good))
bad.provider.api_key = "sk-ant-abcdef0123456789"
ack = H.config(bad, 8)
check("a credential in the document → refused whole", ack.params.applied == "false")
check(
  "last valid kept (v7)",
  prop("AI Provider") == "Anthropic" and require("sbos.moduleclient")._state().opts.configVersion() == "7"
)
check("Last Error names the refusal", prop("Last Error"):find("v8 refused") ~= nil, prop("Last Error"))
local bad2 = JSON:decode(JSON:encode(good))
bad2.permission_mode = "execute_everything"
st = H.operation("apply_config", { config = bad2, version = 9 })
check(
  "apply_config refusal → Failed, v7 kept",
  H.finalState(st) == "Failed" and prop("Permission Mode"):find("^recommend")
)
st = H.operation("apply_config", { config = good, version = 10 })
check("apply_config valid → Completed", H.finalState(st) == "Completed")
local statusFrame = H.lastSent("SBOS_MODULE_STATUS")
check("applied_config_version 10 reported", statusFrame.params.applied_config_version == "10")

print("[11] exclusions and pause suppress collection")
local recs = #H.envelopes("ai_core.record")
H.advance(61000)
EC.AI_RECORD_EVENT({ NAME = "Spare room lamp", ROOM = "Spare Room", CATEGORY = "Lighting" })
H.advance(3000)
check(
  "excluded room: not recorded",
  #H.envelopes("ai_core.record") == recs and H.vars.AI_LAST_ERROR:find("excluded") ~= nil,
  H.vars.AI_LAST_ERROR
)
EC.AI_RECORD_EVENT({ NAME = "Alarm armed", CATEGORY = "Security" })
H.advance(3000)
check(
  "excluded category: not recorded",
  #H.envelopes("ai_core.record") == recs and H.vars.AI_LAST_ERROR:find("excluded_category") ~= nil,
  H.vars.AI_LAST_ERROR
)
local sysBefore = #H.envelopes("ai_core.observation.system")
OnSystemEvent('<event name="OnDeviceOnline" id="48"/>')
H.advance(3000)
check("system event recorded while active", #H.envelopes("ai_core.observation.system") == sysBefore + 1)
local ex0 = counters().collector_excluded_room
H.publish({ frEvent(50, 9, "lighting") }, 0)
check("a consumed event from an excluded room is dropped", counters().collector_excluded_room == ex0 + 1)
local sysEnv = H.envelopes("ai_core.observation.system")[sysBefore + 1]
check("system event claims no cause", sysEnv.payload.note:find("no cause") ~= nil and sysEnv.payload.previous == nil)
st = H.operation("set_learning", { active = false, reason = "homeowner asked" })
check("set_learning false → Completed", H.finalState(st) == "Completed")
check("LEARNING_ACTIVE false", H.vars.LEARNING_ACTIVE == "false")
check(
  "Learning Status says who paused it",
  prop("Learning Status"):find("Paused by System Studio") ~= nil,
  prop("Learning Status")
)
check(
  "unsubscribed from the Flight Recorder topics",
  H.lastSent("SBOS_MODULE_UNSUBSCRIBE") ~= nil and A.subscriptions.fr == nil
)
OnSystemEvent('<event name="OnDeviceOnline" id="48"/>')
H.advance(3000)
check("paused: system event not recorded", #H.envelopes("ai_core.observation.system") == sysBefore + 1)
local cons0 = counters().collector_consumed
H.publish({ frEvent(51, 3, "lighting") }, 0)
check("paused: a late PUBLISH is not consumed", counters().collector_consumed == cons0)
H.advance(61000)
EC.AI_LEARN_PREFERENCE({ STATEMENT = "warmer mornings" })
H.advance(500)
check(
  "paused: AI_LEARN_PREFERENCE refused",
  H.vars.AI_LAST_ERROR:find("learning is paused") ~= nil,
  H.vars.AI_LAST_ERROR
)
H.operation("set_learning", { active = true })
check("resumed → re-subscribed", A.subscriptions.fr ~= nil and H.vars.LEARNING_ACTIVE == "true")
check("TC.LEARNING_ACTIVE", TC.LEARNING_ACTIVE() == true)

print("[12] Flight Recorder absent: AI Core's own minimal collector")
A.fr.present = false
EC.SBOS_MODULE_DIRECTORY_CHANGED(H.auth({ directory_version = "2" }))
H.advance(3000)
check(
  "Flight Recorder Link: not installed",
  prop("Flight Recorder Link"):find("Not installed") ~= nil,
  prop("Flight Recorder Link")
)
check("the configured variable is listened to (by its id)", H.listeners["12:1000"] == true)
check("unsubscribed from the absent recorder", A.subscriptions.fr == nil)
local vBefore = #H.envelopes("ai_core.observation.variable")
OnWatchedVariableChanged(12, 1000, "1") -- Director's immediate first callback
OnWatchedVariableChanged(12, 1000, "0")
OnWatchedVariableChanged(12, 1001, "50") -- not a listened variable
H.advance(3000)
local vEnv = H.envelopes("ai_core.observation.variable")
check("two variable observations", #vEnv == vBefore + 2, #vEnv - vBefore)
check(
  "the first is a state, not a change",
  vEnv[vBefore + 1].evidence_source == "initial" and vEnv[vBefore + 1].payload.initial == true
)
check(
  "the second observed, with no previous value claimed",
  vEnv[vBefore + 2].evidence_source == "observed" and vEnv[vBefore + 2].payload.previous == nil
)
local aBefore = #H.envelopes("ai_core.observation.agent")
EC.SBOS_MODULE_AGENT_EVENT({ name = "device_offline", detail = JSON:encode({ name = "Kitchen Pendants" }) })
H.advance(3000)
check(
  "Agent-classified events recorded only when the recorder is absent",
  #H.envelopes("ai_core.observation.agent") == aBefore + 1
)
A.fr.present = true
EC.SBOS_MODULE_DIRECTORY_CHANGED(H.auth({ directory_version = "3" }))
H.advance(3000)
check("recorder back: own variable listeners released (no double capture)", next(H.listeners) == nil)
EC.SBOS_MODULE_AGENT_EVENT({ name = "device_offline", detail = "{}" })
H.advance(3000)
check("recorder back: Agent events left to it", #H.envelopes("ai_core.observation.agent") == aBefore + 1)
check("recorder back: subscribed again", A.subscriptions.fr ~= nil)

print("[13] local diagnostics")
A.frAnswer = function(capability, args)
  return "ok",
    {
      capability = capability,
      events = {
        {
          seq = 9,
          event_id = "flight_recorder:9001:nb:9",
          at = "2027-01-15T07:59:00Z",
          kind = "event",
          device_label = "Kitchen Pendants",
          event_name = "Off",
        },
        {
          seq = 8,
          no_event_id = "over_upload_budget",
          at = "2027-01-15T07:58:00Z",
          kind = "event",
          device_label = "Kitchen Pendants",
          event_name = "On",
        },
      },
      count = 2,
      truncated = false,
      retention = { held = 2, capacity = 500, oldest_available = { seq = 8 } },
    },
    "ok"
end
H.advance(61000)
local cBefore = #A.cloudCalls
EC.AI_START_DIAGNOSTIC({ DEVICE = "12" })
H.advance(3000)
local frReq = A.frRequests[#A.frRequests]
check(
  "asked the Flight Recorder for the device's history",
  frReq and frReq.to == "flight_recorder" and frReq.capability == "events.device_history" and frReq.args.device_id == 12
)
local diag = H.envelopes("ai_core.diagnostic")
local d1 = diag[#diag]
check(
  "ai_core.diagnostic envelope with the recorder's events",
  d1 and d1.payload.flight_recorder.available == true and #d1.payload.flight_recorder.events == 2
)
check(
  "event ids cited as the recorder gave them",
  d1.payload.flight_recorder.events[1].event_id == "flight_recorder:9001:nb:9"
    and d1.payload.flight_recorder.events[2].no_event_id == "over_upload_budget"
)
local sd = A.cloudCalls[#A.cloudCalls]
check(
  "then start_diagnostic with the envelope id and cited ids",
  #A.cloudCalls == cBefore + 1
    and sd.op == "start_diagnostic"
    and sd.body.diagnostic_event_id == d1.event_id
    and sd.body.local_event_ids[1] == "flight_recorder:9001:nb:9"
)
A.fr.present = false
EC.SBOS_MODULE_DIRECTORY_CHANGED(H.auth({ directory_version = "4" }))
H.advance(3000)
local reqs = #A.frRequests
EC.AI_START_DIAGNOSTIC({ ROOM = "Kitchen" })
H.advance(3000)
diag = H.envelopes("ai_core.diagnostic")
local d2 = diag[#diag]
check("recorder absent: no request sent", #A.frRequests == reqs)
check(
  "recorder absent: the envelope says so",
  d2.payload.flight_recorder.available == false and d2.payload.flight_recorder.reason == "flight_recorder_not_installed"
)
check(
  "recorder absent: still sent to the cloud, flagged",
  A.cloudCalls[#A.cloudCalls].body.flight_recorder_available == false
)
A.fr.present = true
EC.SBOS_MODULE_DIRECTORY_CHANGED(H.auth({ directory_version = "5" }))
H.advance(3000)
A.frAnswer = function()
  return "ok",
    {
      capability = "events.room_activity",
      events = {},
      count = 0,
      truncated = false,
      retention = { held = 0, capacity = 500 },
    },
    "ok"
end
st = H.operation("run_diagnostic", { room_id = 3 })
H.advance(3000)
local fin, det = H.finalState((function()
  local out = {}
  for _, s in ipairs(H.sentOf("SBOS_MODULE_COMMAND_RESULT")) do
    out[#out + 1] = { state = s.params.state, detail = s.params.detail }
  end
  return out
end)())
check(
  "run_diagnostic on an empty ring: Completed, 0 local events",
  fin == "Completed" and det:find("0 local event") ~= nil,
  det
)
st = H.operation("run_diagnostic", { device_id = 12, room_id = 3 })
check("run_diagnostic with both targets refused", H.finalState(st) == "Failed")

print("[14] the Agent stops answering: buffer, drops, ordered flush")
H.advance(61000)
A.reachable = false
H.advance(5 * 60 * 1000 + 15000) -- the liveness probe and its deadline
check("AGENT_CONNECTED false", H.vars.AGENT_CONNECTED == "false", H.vars.AGENT_CONNECTED)
check("Agent Disconnected fired", H.fired_(EV.disconnected))
check(
  "connection status: not responding",
  prop("SmartBuildOS Connection Status") == "SmartBuildOS Agent not responding",
  prop("SmartBuildOS Connection Status")
)
check("conditional AGENT_CONNECTED false", TC.AGENT_CONNECTED() == false)
local sentBefore = #H.envelopes()
for _ = 1, 60 do
  OnSystemEvent('<event name="OnDeviceOffline" id="49"/>') -- critical (warning)
end
local buf = H.persisted.aicore_buffer_v1
check("critical events held in the persisted buffer, bounded at 50", buf and #buf.items == 50, buf and #buf.items)
check("drops counted", buf.dropped >= 1, buf and buf.dropped)
H.advance(30000)
check(
  "Telemetry Status: no Agent answering, buffered",
  prop("Telemetry Status"):find("No Agent answering") ~= nil,
  prop("Telemetry Status")
)
A.reachable = true
EC.SBOS_MODULE_AGENT_HELLO(H.auth({}))
H.advance(5000)
local after = H.envelopes()
local flushed = {}
for i = sentBefore + 1, #after do
  if after[i].event_type == "ai_core.observation.system" or after[i].event_type == "ai_core.status" then
    flushed[#flushed + 1] = after[i]
  end
end
check("buffered events delivered on recovery", #flushed >= 50, #flushed)
local inOrder = true
for i = 2, #flushed do
  inOrder = inOrder and flushed[i].sequence > flushed[i - 1].sequence
end
check("delivered in order", inOrder)
check("buffer empty", #H.persisted.aicore_buffer_v1.items == 0)
check("AGENT_CONNECTED true again", H.vars.AGENT_CONNECTED == "true")
local statusAfter = H.lastSent("SBOS_MODULE_STATUS")
local counters = JSON:decode(statusAfter.params.counters)
check(
  "status counters report buffer drops and bus counters",
  counters.buffer_dropped >= 1 and counters.bus ~= nil and counters.requests ~= nil
)

print("[15] Agent restart: hello → re-register → re-subscribe")
local regs = A.registrations
A.subscriptions = {}
EC.SBOS_MODULE_AGENT_HELLO(H.auth({}))
H.advance(5000)
check("re-registered with a new token", A.registrations == regs + 1)
check("re-subscribed to the recorder", A.subscriptions.fr ~= nil)
local firedN = H.firedCount(EV.pattern)
local oldStates = H.operation("raise_event", { event = "pattern_detected" }, "tok-1")
check(
  "a restricted operation under a pre-restart token is ignored",
  #oldStates == 0 and H.firedCount(EV.pattern) == firedN
)

print("[16] v1-only Agent")
A.protocol = 1
local v2Before = #H.sentOf("SBOS_MODULE_CLOUD_REQUEST")
  + #H.sentOf("SBOS_MODULE_DISCOVER")
  + #H.sentOf("SBOS_MODULE_SUBSCRIBE")
EC.SBOS_MODULE_AGENT_HELLO(H.auth({}))
H.advance(5000)
check("AI_STATUS agent_update_required", H.vars.AI_STATUS == "agent_update_required", H.vars.AI_STATUS)
check(
  "connection status says the Agent needs an update",
  prop("SmartBuildOS Connection Status"):find("update required") ~= nil
)
H.advance(61000)
EC.AI_ASK({ QUESTION = "anything?" })
H.advance(20000)
check(
  "AI_ASK refused locally (incompatible_protocol)",
  H.vars.AI_LAST_ERROR:find("updated") ~= nil,
  H.vars.AI_LAST_ERROR
)
check(
  "nothing v2 sent to a v1 Agent",
  #H.sentOf("SBOS_MODULE_CLOUD_REQUEST") + #H.sentOf("SBOS_MODULE_DISCOVER") + #H.sentOf("SBOS_MODULE_SUBSCRIBE")
    == v2Before
)
local rb = #H.envelopes("ai_core.record")
EC.AI_RECORD_EVENT({ NAME = "still recordable on v1" })
H.advance(5000)
check("v1 services still work (event upload)", #H.envelopes("ai_core.record") == rb + 1)
A.protocol = 2
EC.SBOS_MODULE_AGENT_HELLO(H.auth({}))
H.advance(5000)
check(
  "an updated Agent → ready again",
  H.vars.AI_STATUS == "ready" or H.vars.AI_STATUS == "working",
  H.vars.AI_STATUS
)

print("[17] licence")
H.entitlement({ status = "ENTITLEMENT_EXPIRED", enforcement = "enforce", features = "" })
H.advance(31000)
check("enforced denial → AI_STATUS unlicensed", H.vars.AI_STATUS == "unlicensed", H.vars.AI_STATUS)
check("collection stopped (system events released)", next(H.sysRegs) == nil)
H.advance(61000)
local cc = #A.cloudCalls
EC.AI_ASK({ QUESTION = "hello?" })
H.advance(500)
check(
  "commands refused while unlicensed, nothing sent",
  #A.cloudCalls == cc and H.vars.AI_LAST_ERROR:find("not licensed") ~= nil,
  H.vars.AI_LAST_ERROR
)
H.entitlement({
  status = "AUTHORIZED_GRACE",
  enforcement = "enforce",
  features = "BASE,AI_LEARNING",
  grace_until = "2027-02-01",
})
H.advance(31000)
check(
  "grace → ready, collection back",
  (H.vars.AI_STATUS == "ready" or H.vars.AI_STATUS == "working") and H.sysRegs[48] == 0
)
check("License Status shows grace", prop("License Status"):find("Grace") ~= nil, prop("License Status"))
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "BASE" })
H.advance(61000)
EC.AI_LEARN_PREFERENCE({ STATEMENT = "cooler nights" })
H.advance(500)
check(
  "no AI_LEARNING feature (enforced) → AI_LEARN_PREFERENCE refused",
  H.vars.AI_LAST_ERROR:find("AI_LEARNING") ~= nil,
  H.vars.AI_LAST_ERROR
)
st = H.operation("set_learning", { active = true })
check("set_learning(true) without AI_LEARNING → Failed", H.finalState(st) == "Failed")
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "observe", features = "BASE" })
H.advance(61000)
cc = #A.cloudCalls
EC.AI_LEARN_PREFERENCE({ STATEMENT = "cooler nights" })
H.advance(500)
check("observe mode never refuses on a feature", #A.cloudCalls == cc + 1)
H.entitlement({ status = "CLOUD_VALIDATION_REQUIRED", enforcement = "enforce", features = "" })
H.advance(61000)
cc = #A.cloudCalls
EC.AI_ANALYZE_SYSTEM({})
H.advance(500)
check("uncertain licence state fails open", #A.cloudCalls == cc + 1 and H.vars.AI_STATUS ~= "unlicensed")
H.entitlement({
  status = "TRIAL",
  enforcement = "enforce",
  features = "BASE,AI_LEARNING",
  trial_expires_epoch = tostring(os.time() + 60),
})
H.advance(120000)
check("an expired trial is enforced after its deadline", H.vars.AI_STATUS == "unlicensed", H.vars.AI_STATUS)
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "BASE,AI_LEARNING" })
H.advance(31000)

print("[18] controller restart")
H.operation(
  "deliver_result",
  { response_id = "resp-before-restart", text = "The garage light was turned on by the 3 am schedule." }
)
H.operation("set_learning", { active = false, reason = "testing restart" })
A.reachable = false
H.advance(5 * 60 * 1000 + 15000)
OnSystemEvent('<event name="OnDeviceOffline" id="49"/>')
local lastIdBefore = nil
for _, e in ipairs(H.envelopes()) do
  lastIdBefore = e.sequence
end
local held = #H.persisted.aicore_buffer_v1.items
H.vars = {}
H.load("DIT_STARTUP")
check("config version survives", require("sbos.moduleclient")._state().opts.configVersion() == "10")
check("AI Provider survives", prop("AI Provider") == "Anthropic")
check(
  "learning pause survives",
  H.vars.LEARNING_ACTIVE == "false" and prop("Learning Status"):find("testing restart") ~= nil
)
check("AI_LAST_RESPONSE_ID survives", H.vars.AI_LAST_RESPONSE_ID == "resp-before-restart")
check("AI_LAST_RESPONSE survives", H.vars.AI_LAST_RESPONSE:find("3 am schedule") ~= nil)
check("buffer survives", #H.persisted.aicore_buffer_v1.items >= held and held >= 0)
A.reachable = true
H.advance(60000)
local maxSeqAfter, dupIds, seen = 0, 0, {}
for _, e in ipairs(H.envelopes()) do
  if seen[e.event_id] then
    dupIds = dupIds + 1
  end
  seen[e.event_id] = true
  maxSeqAfter = math.max(maxSeqAfter, e.sequence)
end
check("sequence continues after the restart (never reused)", maxSeqAfter > (lastIdBefore or 0))
check("no event id handed to the Agent twice", dupIds == 0, dupIds)

print("[19] no operation path reaches equipment")
H.operation("set_learning", { active = true })
for _, args in ipairs({
  { "raise_event", { event = "action_completed", device_id = 30, command = "UNLOCK" } },
  { "deliver_result", { response_id = "x", text = "y", device_id = 30 } },
  { "run_diagnostic", { device_id = 30, command = "LOCK" } },
  { "apply_config", { config = { actions = { { device_id = 30, command = "UNLOCK" } } }, version = 11 } },
  { "set_learning", { active = true, lua = "C4:SendToDevice(30,'UNLOCK',{})" } },
  { "send_to_device", { device_id = 30, command = "UNLOCK" } },
  { "execute_lua", { code = "os.exit()" } },
}) do
  local s = H.operation(args[1], args[2])
  check("refused: " .. args[1] .. " with equipment-shaped args", H.finalState(s) == "Failed")
end
EC.AI_ASK({ QUESTION = "unlock the front door now", ROOM = "Entry" })
H.advance(5000)
local outsiders = {}
for _, s in ipairs(H.sent) do
  if s.device ~= H.AGENT_ID then
    outsiders[#outsiders + 1] = tostring(s.device) .. ":" .. s.command
  end
end
check(
  "every C4:SendToDevice of the whole run went to the SmartBuildOS Agent",
  #outsiders == 0,
  table.concat(outsiders, ",")
)
check(
  "no SetDeviceVariable / SendToProxy / SendUIRequest / RegisterDeviceEvent / Bind",
  #H.equipment == 0,
  #H.equipment
)

OnDriverDestroyed()
check("destroyed: system events released", next(H.sysRegs) == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
