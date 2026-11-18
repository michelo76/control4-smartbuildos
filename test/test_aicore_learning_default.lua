-- AI Core: learning is OFF until System Studio switches it on, and every
-- configuration field defaults to its conservative value. Driver under the
-- shim with the scripted Agent (test/aicore_harness.lua) — simulation.
--
--   [1] no configuration at all
--   [2] a valid document that does not mention learning
--   [3] explicit on (and nothing else: collection stays off)
--   [4] explicit off
--   [5] an invalid document turns learning off, the rest stays in force
--   [6] an invalid document as the very first one
--   [7] a restart keeps learning off
--   [8] non-learning features work with learning off; names reach the cloud bounded
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

local function off(label, status)
  check(label .. ": LEARNING_ACTIVE false", H.vars.LEARNING_ACTIVE == "false", H.vars.LEARNING_ACTIVE)
  check(label .. ": conditional LEARNING_ACTIVE false", TC.LEARNING_ACTIVE() == false)
  check(label .. ": Learning Status says " .. status, prop("Learning Status") == status, prop("Learning Status"))
  check(label .. ": no system event registered", next(H.sysRegs) == nil)
  check(label .. ": no Flight Recorder subscription", A.subscriptions.fr == nil)
  check(label .. ": no variable listener", next(H.listeners) == nil)
  local before = #H.envelopes("ai_core.observation.system")
  OnSystemEvent('<event name="OnDeviceOffline" id="49"/>')
  H.advance(3000)
  check(label .. ": a system event is not recorded", #H.envelopes("ai_core.observation.system") == before)
end

local function learnRefused(label)
  H.advance(7000)
  local calls = #A.cloudCalls
  EC.AI_LEARN_PREFERENCE({ STATEMENT = "warmer mornings" })
  H.advance(500)
  check(
    label .. ": AI_LEARN_PREFERENCE refused locally, nothing sent",
    #A.cloudCalls == calls and H.vars.AI_LAST_ERROR:find("learning is paused", 1, true) ~= nil,
    H.vars.AI_LAST_ERROR
  )
end

print("[1] no configuration")
H.agentPresent = true
H.load("DIT_ADDING")
H.advance(31000)
check("registered and ready", H.vars.AI_STATUS == "ready", H.vars.AI_STATUS)
check("the Flight Recorder is known (present)", prop("Flight Recorder Link"):find("^Installed") ~= nil)
off("no configuration", "Off (not switched on in System Studio)")
check("AI Status says learning is off", prop("AI Status") == "Ready (learning paused)", prop("AI Status"))
check("Telemetry Status says nothing is collected", prop("Telemetry Status"):find("^Learning paused") ~= nil)
check("status counters say learning_active false", JSON:decode((function()
  require("sbos.moduleclient").sendStatus()
  return H.lastSent("SBOS_MODULE_STATUS").params.counters
end)()).learning_active == false)
learnRefused("no configuration")
EC.SBOS_MODULE_AGENT_EVENT(H.auth({ name = "device_offline", detail = "{}" }))
H.advance(3000)
check("no configuration: Agent events not recorded", #H.envelopes("ai_core.observation.agent") == 0)
H.advance(7000)
EC.AI_RECORD_EVENT({ NAME = "Bedtime", CATEGORY = "Lighting" })
H.advance(3000)
check(
  "no configuration: AI_RECORD_EVENT is not recorded (the paused rule applies to AI Core's own marker)",
  #H.envelopes("ai_core.record") == 0 and H.vars.AI_LAST_ERROR:find("paused", 1, true) ~= nil,
  H.vars.AI_LAST_ERROR
)

print("[2] a valid document that does not mention learning")
local ack = H.config({ schema = 1, provider = { name = "Anthropic", model = "m" } }, 2)
check("applied", ack.params.applied == "true")
off("learning absent", "Paused by System Studio: the configuration does not switch it on")
learnRefused("learning absent")

print("[3] explicit on")
ack = H.config({ schema = 1, learning = { active = true }, provider = { name = "Anthropic", model = "m" } }, 3)
check("applied", ack.params.applied == "true")
check("LEARNING_ACTIVE true", H.vars.LEARNING_ACTIVE == "true" and TC.LEARNING_ACTIVE() == true)
check("Learning Status Active", prop("Learning Status") == "Active", prop("Learning Status"))
check(
  "collection not mentioned → every source stays off",
  next(H.sysRegs) == nil and A.subscriptions.fr == nil and next(H.listeners) == nil
)
H.advance(7000)
local calls = #A.cloudCalls
EC.AI_LEARN_PREFERENCE({ STATEMENT = "warmer mornings" })
H.advance(500)
check(
  "AI_LEARN_PREFERENCE reaches the cloud",
  #A.cloudCalls == calls + 1 and A.cloudCalls[#A.cloudCalls].op == "learn_preference"
)
ack = H.config(H.learningOn({ provider = { name = "Anthropic", model = "m" } }), 4)
check("collection switched on explicitly → system events registered", H.sysRegs[49] == 0)
check("collection switched on explicitly → topics subscribed", A.subscriptions.fr ~= nil)

print("[4] explicit off")
H.config({ schema = 1, learning = { active = false }, provider = { name = "Anthropic", model = "m" } }, 5)
off("explicit off", "Paused by System Studio")
learnRefused("explicit off")

print("[5] an invalid document after learning was on")
H.config(H.learningOn({ provider = { name = "Anthropic", model = "m" } }), 6)
check("on again", H.vars.LEARNING_ACTIVE == "true")
ack = H.config({ schema = 1, learning = { enabled = true }, provider = { name = "Other", model = "x" } }, 7)
check("refused", ack.params.applied == "false")
off("invalid document", "Paused by configuration: v7 refused")
check("the rest of the last valid document stays in force", prop("AI Provider") == "Anthropic")
check("Last Error names the refusal", prop("Last Error"):find("v7 refused", 1, true) ~= nil, prop("Last Error"))
learnRefused("invalid document")
local st = H.operation("apply_config", { config = { learning = "yes" }, version = 8 })
check("apply_config with an invalid document → Failed", H.finalState(st) == "Failed")
check(
  "still off",
  H.vars.LEARNING_ACTIVE == "false" and prop("Learning Status") == "Paused by configuration: v8 refused"
)
H.config(H.learningOn({ provider = { name = "Anthropic", model = "m" } }), 9)
check(
  "a valid document that says on turns it back on",
  H.vars.LEARNING_ACTIVE == "true" and prop("Learning Status") == "Active"
)

print("[6] an invalid document as the very first one")
for k in pairs(H.persisted) do
  H.persisted[k] = nil
end
A.subscriptions = {} -- the scripted Agent forgets the old instance's subscription
H.load("DIT_ADDING")
H.advance(31000)
off("fresh install", "Off (not switched on in System Studio)")
-- the platform's own document shape (settings.ts driverConfigDocument) is not this schema
ack = H.config({
  schema = 1,
  settings_revision = 3,
  permission_mode = "observe",
  learning = { enabled = true, paused = false },
  excluded_room_ids = {},
  excluded_categories = {},
  provider = nil,
  credential_status = "Not configured",
}, 1)
check("refused", ack.params.applied == "false")
off("first document invalid", "Paused by configuration: v1 refused")

print("[7] a restart keeps learning off")
H.load("DIT_STARTUP")
H.advance(31000)
off("after a restart", "Paused by configuration: v1 refused")

print("[8] learning off: the non-learning features still work")
H.advance(7000)
calls = #A.cloudCalls
EC.AI_ASK({ QUESTION = "Why is the garage cold?", ROOM = "Garage" })
H.advance(500)
check("AI_ASK reaches the cloud", #A.cloudCalls == calls + 1 and A.cloudCalls[#A.cloudCalls].op == "ask")
local frBefore = #A.frRequests
H.advance(7000)
EC.AI_START_DIAGNOSTIC({ DEVICE = "12" })
H.advance(3000)
check(
  "AI_START_DIAGNOSTIC still asks the Flight Recorder for local history",
  #A.frRequests == frBefore + 1 and A.frRequests[#A.frRequests].capability == "events.device_history"
)
check("… and calls start_diagnostic", A.cloudCalls[#A.cloudCalls].op == "start_diagnostic")
-- a long, odd name from Director reaches the cloud bounded and clean
H.devices[77] = {
  deviceName = string.rep("\240\159\146\161", 130) .. "\194\133",
  driverFileName = "light_v2.c4i",
  roomId = 60,
  roomName = "\226\128\168Primary " .. string.rep("\195\169", 70),
}
H.advance(7000)
EC.AI_START_DIAGNOSTIC({ DEVICE = "77" })
H.advance(3000)
local body = A.cloudCalls[#A.cloudCalls].body
check(
  "device_name cut to 120 characters (480 bytes), the C1 control gone",
  body.device_name == string.rep("\240\159\146\161", 120),
  #tostring(body.device_name)
)
H.advance(7000)
EC.AI_ANALYZE_ROOM({ ROOM = "60" })
H.advance(500)
body = A.cloudCalls[#A.cloudCalls].body
check(
  "room_name: U+2028 removed, cut to 64 characters",
  body.room_name == "Primary " .. string.rep("\195\169", 56),
  tostring(body.room_name)
)
local diag = H.envelopes("ai_core.diagnostic")
local label = diag[#diag].label
check(
  "the diagnostic label is cut between characters (≤ 120 bytes)",
  #label <= 120 and label:sub(-4) == "\240\159\146\161",
  #label
)
st = H.operation("run_diagnostic", { device_id = 77 })
check("run_diagnostic on the long-named device → Completed", H.finalState(st) == "Completed", H.finalState(st))
diag = H.envelopes("ai_core.diagnostic")
check(
  "run_diagnostic: the target name is cleaned and bounded like a cloud body",
  diag[#diag].payload.target.device_name == string.rep("\240\159\146\161", 120)
)
H.devices[77] = nil

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
