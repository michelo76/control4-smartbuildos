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
--   [9] set_learning and the configuration document: the document decides
--       (precedence, DRIVER.md §9), across versions, refusals and a restart
--  [10] AI_RECORD_EVENT is a dealer's marker, not learning: recorded with
--       learning off, paused or on; exclusions still refuse it; bounded
--  [11] envelope text: every payload string AI Core records is cut to the
--       envelope's 512 bytes BETWEEN characters (sbos.envelope would split one
--       and the Agent could not decode the frame; KNOWN-ISSUES.md KI-1)
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
  "no configuration: AI_RECORD_EVENT IS recorded (a dealer's marker, not learning; architect's ruling)",
  #H.envelopes("ai_core.record") == 1 and H.envelopes("ai_core.record")[1].payload.name == "Bedtime",
  #H.envelopes("ai_core.record")
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
-- the platform's PRE-CLOSEOUT document shape (settings.ts before 2026-11-18): a
-- deliberately wrong document now; the platform's goldens are accepted
-- (test_aicore_platform_parity.lua [10])
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

print("[9] set_learning and the configuration document: the document decides")
local function learning()
  return H.vars.LEARNING_ACTIVE == "true"
end
local function op(args)
  local state, detail = H.finalState(H.operation("set_learning", args))
  return state, tostring(detail)
end
ack = H.config(H.learningOn(), 10)
check("v10 (on) applied", ack.params.applied == "true" and learning())
local state, detail = op({ active = false, reason = "paused by the homeowner", config_version = 11 })
check("set_learning(false) previewing v11 → Completed, off at once", state == "Completed" and not learning(), detail)
check(
  "Learning Status names the preview",
  prop("Learning Status") == "Paused by System Studio: paused by the homeowner",
  prop("Learning Status")
)
ack = H.config(H.learningOn(), 10)
check("a re-delivered OLDER document (v10, on) does not undo it", ack.params.applied == "true" and not learning())
ack = H.config(H.learningOn({ provider = { name = "Anthropic" } }), 11)
check("the document it previewed (v11) decides — here: on", ack.params.applied == "true" and learning())
state, detail = op({ active = false, reason = "late", config_version = 11 })
check(
  "a stale set_learning (v11 already applied) is ignored, idempotently",
  state == "Completed" and learning() and detail:find("already decides", 1, true) ~= nil,
  detail
)
state = op({ active = false, config_version = 4 })
check("an older one too", state == "Completed" and learning())
state = op({ active = false, reason = "staff" })
check("set_learning without a version: off now", state == "Completed" and not learning())
H.config(H.learningOn({ provider = { name = "Anthropic" } }), 11)
check("… held against the version in force (v11 again)", not learning())
H.config(H.learningOn(), 12)
check("… until a newer document (v12) decides", learning())
st = H.operation("apply_config", { config = { schema = 1, learning = { active = false } }, version = 9 })
check(
  "a late apply_config older than the document in force is superseded, not applied",
  H.finalState(st) == "Completed" and learning() and select(2, H.finalState(st)):find("superseded", 1, true) ~= nil
)
ack = H.config({ schema = 1, learning = { enabled = true } }, 13)
check("an invalid document (v13) turns learning off", ack.params.applied == "false" and not learning())
state, detail = op({ active = true, config_version = 13 })
check(
  "set_learning(true) cannot switch it back on over a refused document",
  state == "Failed" and not learning() and detail:find("refused", 1, true) ~= nil,
  detail
)
check("set_learning(false) is always accepted", op({ active = false, config_version = 14 }) == "Completed")
H.config(H.learningOn(), 14)
check("a valid v14 decides again", learning())
op({ active = false, reason = "before restart", config_version = 20 })
H.load("DIT_STARTUP")
H.advance(31000)
check("the preview survives a restart", not learning() and prop("Learning Status"):find("before restart") ~= nil)
H.config(H.learningOn(), 19)
check("after the restart v19 still does not undo it", not learning())
H.config(H.learningOn(), 20)
check("v20 decides", learning())

print("[10] AI_RECORD_EVENT: a marker, not learning")
local function recordCount()
  return #H.envelopes("ai_core.record")
end
local function mark(params)
  H.advance(7000) -- under the 10-a-minute command bucket
  local before = recordCount()
  EC.AI_RECORD_EVENT(params)
  H.advance(3000)
  return recordCount() == before + 1
end
check("learning on: recorded", learning() and mark({ NAME = "on" }))
op({ active = false, reason = "paused", config_version = 21 })
check("learning paused: still recorded", not learning() and mark({ NAME = "paused" }))
H.config({ schema = 1, learning = { active = false }, exclusions = { rooms = { 3 }, categories = { "security" } } }, 21)
check("learning off by the document: still recorded", not learning() and mark({ NAME = "off", CATEGORY = "Lighting" }))
check(
  "an excluded category still refuses it",
  not mark({ NAME = "Alarm armed", CATEGORY = "Security" }) and H.vars.AI_LAST_ERROR:find("excluded_category") ~= nil,
  H.vars.AI_LAST_ERROR
)
check(
  "an excluded room still refuses it",
  not mark({ NAME = "Pendants", ROOM = "Kitchen" }) and H.vars.AI_LAST_ERROR:find("excluded") ~= nil,
  H.vars.AI_LAST_ERROR
)
check("bounded like other text: a NAME over 120 characters is refused", not mark({ NAME = string.rep("x", 121) }))
check("sanitised: control characters become spaces, ends trimmed", mark({ NAME = "\tLine\none\226\128\168 " }))
local last = H.envelopes("ai_core.record")[recordCount()]
check("… and the recorded name is clean", last.payload.name == "Line one", tostring(last.payload.name))
check("never a learning observation: no ai_core.observation.* for a marker", last.event_type == "ai_core.record")

print("[11] envelope text cut between characters, never inside one")
local EURO = "\226\130\172" -- 3 bytes
H.advance(7000)
local before11 = recordCount()
-- 400 characters = 1200 bytes; 512 is not a multiple of 3, so a byte cut splits one.
EC.AI_RECORD_EVENT({ NAME = string.rep(EURO, 120), DETAIL = string.rep(EURO, 400) })
H.advance(3000) -- the scripted Agent JSON-decodes every SBOS_MODULE_EVENTS frame it is sent
local rec = H.envelopes("ai_core.record")[recordCount()]
check("the marker reached the Agent in a frame it could decode", recordCount() == before11 + 1)
check(
  "DETAIL cut to 510 bytes (170 whole characters), marked partial",
  rec.payload.detail == string.rep(EURO, 170) and rec.quality == "partial",
  #tostring(rec.payload.detail)
)
check("the label cut to 120 bytes between characters", rec.label == string.rep(EURO, 40), #tostring(rec.label))
H.advance(7000)
EC.AI_ASK({ QUESTION = string.rep(EURO, 500) })
H.advance(3000)
local cmdEnv = H.envelopes("ai_core.command")
cmdEnv = cmdEnv[#cmdEnv]
check(
  "AI_ASK: the envelope's copy of a 1500-byte question is cut between characters",
  cmdEnv.payload.args.question == string.rep(EURO, 170) and cmdEnv.quality == "partial"
)
check(
  "… while the cloud body carries the whole question (the platform's bound is 500 characters)",
  A.cloudCalls[#A.cloudCalls].body.question == string.rep(EURO, 500)
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
