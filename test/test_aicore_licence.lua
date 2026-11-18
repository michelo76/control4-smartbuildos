-- SmartBuildOS AI Core: licensing as the DRIVER sees it (SIMULATION ONLY:
-- the shim + the scripted Agent of test/aicore_harness.lua; the Agent's
-- answers are scripted SBOS_ENTITLEMENT frames). The real Agent's half —
-- signature verification, the staleness ladder, clock handling — is covered
-- by test/test_sbos_entitlements.lua, and both halves together by the
-- emulator scenario test/emulator/ai_core.lua [13]-[13f].
--
--   [1]  activation: registration with the Agent on start and on module
--        registration; asked again until answered; Licensed on the answer
--   [2]  every status × observe/enforce: only a DEFINITIVE denial under
--        enforcement stops AI Core, and the refusal says which
--   [3]  CONTROLLER_MISMATCH (enforced): commands, run_diagnostic, the AI
--        test and collection all stop, each saying why
--   [4]  feature entitlements: AI_LEARNING gates exactly its paths;
--        AI_ACTIONS gates invoke_driver_action (test_aicore_reports.lua);
--        AI_CONCIERGE gates no driver path (none exists)
--   [5]  uncertain states never brick the driver
--   [6]  the cache → grace → validation-required ladder, as answered
--   [7]  renewal restores service without a reload
--   [8]  transfer: revoked on this controller, then granted again
--   [9]  trial: enforced at its deadline even with no Agent answer, and
--        after a restart
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

--- One AI_ANALYZE_SYSTEM (BASE) after refilling the local command bucket.
--- @return boolean sent, string lastError
local function tryCommand(name, params)
  H.advance(7000)
  local n = #A.cloudCalls
  EC[name or "AI_ANALYZE_SYSTEM"](params or {})
  H.advance(500)
  return #A.cloudCalls == n + 1, tostring(H.vars.AI_LAST_ERROR)
end

local function operational()
  return H.vars.AI_STATUS == "ready" or H.vars.AI_STATUS == "working"
end

print("[1] activation on first registration")
H.agentPresent = true
A.auto = false -- the Agent hears but does not answer yet
H.load("DIT_ADDING")
H.advance(1000)
local regs = H.sentOf("SBOS_REGISTER_DRIVER")
check(
  "SBOS_REGISTER_DRIVER to the Agent at start: sku, version, requester",
  #regs >= 1
    and regs[1].device == H.AGENT_ID
    and regs[1].params.sku == "SBOS_AI_CORE"
    and regs[1].params.version == "20261118.000000"
    and regs[1].params.requester == tostring(H.SELF_ID)
)
check(
  "License Status: Checking… until the Agent answers",
  prop("License Status") == "SmartBuildOS Agent Found - Checking...",
  prop("License Status")
)
H.advance(20000)
check(
  "asked again while unanswered (5 s, 15 s)",
  #H.sentOf("SBOS_REGISTER_DRIVER") >= 3,
  #H.sentOf("SBOS_REGISTER_DRIVER")
)
A.auto = true
H.advance(31000) -- module registration retry → registered → license.register()
local regAt, followed = nil, false
for i, f in ipairs(H.sent) do
  if f.command == "SBOS_MODULE_REGISTER" then
    regAt = i
  end
end
for i = (regAt or #H.sent) + 1, math.min(#H.sent, (regAt or 0) + 4) do
  followed = followed or H.sent[i].command == "SBOS_REGISTER_DRIVER"
end
check("the licence registration is re-sent the moment the module registers", regAt ~= nil and followed)
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "BASE,AI_LEARNING" })
check("Licensed / Subscribed", prop("License Status") == "Licensed / Subscribed", prop("License Status"))
local settled = #H.sentOf("SBOS_REGISTER_DRIVER")
H.advance(400000)
check("an answered driver stops asking", #H.sentOf("SBOS_REGISTER_DRIVER") == settled)
check("operational", operational(), H.vars.AI_STATUS)

print("[2] every status × observe / enforce")
local STATUSES = {
  { "AUTHORIZED_SUBSCRIPTION", false, "Licensed / Subscribed" },
  { "AUTHORIZED_PERPETUAL", false, "Licensed / Permanent" },
  { "AUTHORIZED_GRACE", false, "Licensed / Grace" },
  { "TRIAL", false, "Licensed / Trial" },
  { "LEGACY", false, "Licensing Not Yet Enforced" },
  { "CLOUD_VALIDATION_REQUIRED", false, "Cloud Validation Required" },
  { "AGENT_UNAUTHENTICATED", false, "SmartBuildOS Agent Not Authenticated" },
  { "NOT_ENTITLED", true, "Agent Linked - Not Licensed (see SmartBuildOS)" },
  { "ENTITLEMENT_EXPIRED", true, "License Expired (see SmartBuildOS)" },
  { "ACCOUNT_SUSPENDED", true, "Account Suspended (see SmartBuildOS)" },
  { "CONTROLLER_MISMATCH", true, "License Registered To Another Controller" },
}
local wrong = {}
for _, row in ipairs(STATUSES) do
  local status, denies, label = row[1], row[2], row[3]
  for _, mode in ipairs({ "observe", "enforce" }) do
    H.entitlement({ status = status, enforcement = mode, features = "BASE,AI_LEARNING" })
    local sent, err = tryCommand()
    local refused = denies and mode == "enforce"
    local okRow = (sent ~= refused)
      and ((H.vars.AI_STATUS == "unlicensed") == refused)
      and (not refused or err:find("not licensed: " .. label, 1, true) ~= nil)
      and prop("License Status"):find(label, 1, true) == 1
    if not okRow then
      wrong[#wrong + 1] = status
        .. "/"
        .. mode
        .. " sent="
        .. tostring(sent)
        .. " AI_STATUS="
        .. tostring(H.vars.AI_STATUS)
        .. " err="
        .. err
    end
  end
end
check("22 combinations: refused exactly when enforce AND a definitive denial", #wrong == 0, table.concat(wrong, " | "))

print("[3] CONTROLLER_MISMATCH under enforcement")
H.entitlement({ status = "CONTROLLER_MISMATCH", enforcement = "enforce", features = "" })
H.advance(1000)
check(
  "License Status says another controller holds it (read-only)",
  prop("License Status") == "License Registered To Another Controller (read-only)",
  prop("License Status")
)
check("AI_STATUS unlicensed", H.vars.AI_STATUS == "unlicensed", H.vars.AI_STATUS)
check(
  "AI Status shows the licence line",
  prop("AI Status"):find("^Unavailable: License Registered To Another Controller") ~= nil,
  prop("AI Status")
)
local sent, err = tryCommand("AI_ASK", { QUESTION = "Is this controller licensed?" })
check("AI_ASK refused, nothing sent, the reason named", not sent and err:find("Another Controller") ~= nil, err)
local st = H.operation("run_diagnostic", { device_id = 12 })
check("run_diagnostic Failed with the reason", H.finalState(st) == "Failed")
EC.TEST_AI_CONNECTION()
check(
  "Test AI Connection says not licensed",
  prop("Last Test Result"):find("not licensed") ~= nil,
  prop("Last Test Result")
)
check("collection stopped: no system event registered", next(H.sysRegs) == nil)
check("collection stopped: the Flight Recorder subscription released", next(A.subscriptions) == nil)
local recs = #H.envelopes("ai_core.record")
EC.AI_RECORD_EVENT({ NAME = "marker while unlicensed" })
H.advance(31000)
check("AI_RECORD_EVENT recorded nothing", #H.envelopes("ai_core.record") == recs)
check(
  "restricted operations that only show results still work (deliver_result)",
  H.finalState(H.operation("deliver_result", { response_id = "r-mm", text = "still shown" })) == "Completed"
)

print("[4] feature entitlements")
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "BASE" })
H.advance(1000)
local baseCommands = {
  { "AI_ASK", { QUESTION = "what happened at 3 am?" } },
  { "AI_ANALYZE_ROOM", { ROOM = "Kitchen" } },
  { "AI_ANALYZE_SYSTEM", {} },
  { "AI_SET_CONTEXT", { KEY = "Vacation", VALUE = "yes" } },
  { "AI_SUGGEST_SCENE", { ROOM = "Kitchen", OCCASION = "dinner" } },
  { "AI_GENERATE_REPORT", { TYPE = "Usage", PERIOD = "Today" } },
  { "AI_START_DIAGNOSTIC", { DEVICE = "12" } },
  { "AI_SEND_NOTIFICATION", { TITLE = "t", MESSAGE = "m" } },
}
local blocked = {}
for _, c in ipairs(baseCommands) do
  if not tryCommand(c[1], c[2]) then
    blocked[#blocked + 1] = c[1]
  end
end
check("BASE only: every BASE command goes", #blocked == 0, table.concat(blocked, ","))
sent, err = tryCommand("AI_LEARN_PREFERENCE", { STATEMENT = "cooler at night" })
check(
  "BASE only: AI_LEARN_PREFERENCE refused — 'the licence does not include AI_LEARNING'",
  not sent and err:find("the licence does not include AI_LEARNING", 1, true) ~= nil,
  err
)
st = H.operation("set_learning", { active = true })
local stName, stDetail = H.finalState(st)
check(
  "BASE only: set_learning(true) Failed, saying so",
  stName == "Failed" and tostring(stDetail):find("AI_LEARNING") ~= nil,
  stDetail
)
H.config(H.learningOn(), 21) -- learning and every collection source asked for
check(
  "BASE only: a configuration asking for learning keeps it paused, and says why",
  H.vars.LEARNING_ACTIVE == "false" and prop("Learning Status"):find("AI_LEARNING") ~= nil,
  prop("Learning Status")
)
check(
  "BASE only: set_learning(false) is always allowed",
  H.finalState(H.operation("set_learning", { active = false })) == "Completed"
)
local raisedOk = true
for _, ev in ipairs({ "approval_required", "action_completed", "action_failed" }) do
  raisedOk = raisedOk and H.finalState(H.operation("raise_event", { event = ev, pending_approvals = 1 })) == "Completed"
end
check(
  "without AI_ACTIONS the driver still shows approval/action events (it executes no action; the platform gates them)",
  raisedOk and H.firedCount(6) >= 1 and H.firedCount(7) >= 1 and H.firedCount(8) >= 1
)
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "BASE,AI_LEARNING" })
check(
  "AI_LEARNING present: set_learning(true) Completed",
  H.finalState(H.operation("set_learning", { active = true })) == "Completed"
)
sent = tryCommand("AI_LEARN_PREFERENCE", { STATEMENT = "cooler at night" })
check("AI_LEARNING present: AI_LEARN_PREFERENCE goes", sent, H.vars.AI_LAST_ERROR)
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "AI_LEARNING" })
sent, err = tryCommand("AI_ANALYZE_SYSTEM")
check(
  "BASE absent (enforced, authorised): BASE commands refused, naming BASE",
  not sent and err:find("BASE") ~= nil,
  err
)
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "observe", features = "" })
check("observe: no feature ever refuses", tryCommand("AI_LEARN_PREFERENCE", { STATEMENT = "x" }))
-- Which features the driver gates at all: read from the source, so a new
-- gate (or a removed one) is a visible change to this list.
local function read(path)
  local f = assert(io.open(path))
  local s = f:read("*a")
  f:close()
  return s
end
local gated = {}
local src = read("drivers/smartbuildos-ai-core/driver.lua") .. read("src/aicore/commands.lua")
for feature in src:gmatch('licenceBlocks%("([%u_]+)"%)') do
  gated[feature] = true
end
for feature in src:gmatch('feature = "([%u_]+)"') do
  gated[feature] = true
end
local list = {}
for f in pairs(gated) do
  list[#list + 1] = f
end
table.sort(list)
check(
  "the driver gates exactly BASE, AI_LEARNING and AI_ACTIONS (invoke_driver_action; AI_CONCIERGE: no driver path)",
  table.concat(list, ",") == "AI_ACTIONS,AI_LEARNING,BASE",
  table.concat(list, ",")
)

print("[5] uncertain states never brick the driver")
local bricked = {}
for _, status in ipairs({ "CLOUD_VALIDATION_REQUIRED", "AGENT_UNAUTHENTICATED", "LEGACY", "SOMETHING_NEW" }) do
  H.entitlement({ status = status, enforcement = "enforce", features = "" })
  if not tryCommand() or H.vars.AI_STATUS == "unlicensed" then
    bricked[#bricked + 1] = status
  end
end
check(
  "validation required, unauthenticated, legacy, an unknown status: all operational",
  #bricked == 0,
  table.concat(bricked, ",")
)
check(
  "an unknown status is shown as Cloud Validation Required",
  prop("License Status") == "Cloud Validation Required",
  prop("License Status")
)
A.reachable = false -- the Agent stops answering anything
H.advance(6 * 60 * 1000)
check("Agent unreachable: AI_STATUS agent_lost, never unlicensed", H.vars.AI_STATUS == "agent_lost", H.vars.AI_STATUS)
A.reachable = true
H.advance(61000)
check("…and ready again when it answers", operational(), H.vars.AI_STATUS)

print("[6] the cache → grace → validation-required ladder, as answered")
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "BASE,AI_LEARNING" })
check("fresh: Licensed / Subscribed", prop("License Status") == "Licensed / Subscribed")
H.entitlement({
  status = "AUTHORIZED_GRACE",
  enforcement = "enforce",
  features = "BASE,AI_LEARNING",
  grace_until = "2027-03-01",
})
check(
  "grace: dated, operational",
  prop("License Status") == "Licensed / Grace (until 2027-03-01)" and tryCommand() and operational(),
  prop("License Status")
)
check("grace keeps the features (AI_LEARN_PREFERENCE goes)", tryCommand("AI_LEARN_PREFERENCE", { STATEMENT = "x" }))
H.entitlement({ status = "CLOUD_VALIDATION_REQUIRED", enforcement = "enforce", features = "" })
check(
  "past grace: Cloud Validation Required, still operational",
  prop("License Status") == "Cloud Validation Required" and tryCommand() and operational(),
  prop("License Status")
)
check(
  "validation required does not refuse a feature (the feature list is not definitive)",
  tryCommand("AI_LEARN_PREFERENCE", { STATEMENT = "x" })
)

print("[7] renewal restores service without a reload")
local tickTimer = H.clock.timers.AiCoreTick
H.entitlement({ status = "ENTITLEMENT_EXPIRED", enforcement = "enforce", features = "" })
H.advance(1000)
check("expired: unlicensed, collection stopped", H.vars.AI_STATUS == "unlicensed" and next(H.sysRegs) == nil)
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "BASE,AI_LEARNING" })
H.advance(1000)
check("renewed: operational at once", operational(), H.vars.AI_STATUS)
check("renewed: system events registered again", H.sysRegs[48] == 0 and H.sysRegs[49] == 0)
check("renewed: the Flight Recorder subscription is back", A.subscriptions.fr ~= nil)
check("renewed: commands go", tryCommand())
check("renewed: Learning Status Active", prop("Learning Status") == "Active", prop("Learning Status"))
check("no reload happened (the same tick timer)", H.clock.timers.AiCoreTick == tickTimer)

print("[8] transfer: revoked on this controller, then granted again")
H.entitlement({
  status = "AUTHORIZED_PERPETUAL",
  enforcement = "enforce",
  features = "BASE,AI_LEARNING",
  license_type = "PERPETUAL",
})
check("perpetual: Licensed / Permanent, Purchased outright", prop("License Source") == "Purchased outright")
-- After /api/platform/driver-cloud/licenses/transfer closes this controller's
-- row, the next refresh signs NOT_ENTITLED for it (decideCatalogEntitlement).
H.entitlement({ status = "NOT_ENTITLED", enforcement = "enforce", features = "" })
H.advance(1000)
sent, err = tryCommand()
check("moved away: refused, 'Not Licensed'", not sent and err:find("Not Licensed", 1, true) ~= nil, err)
check("moved away: AI_STATUS unlicensed", H.vars.AI_STATUS == "unlicensed")
H.entitlement({
  status = "AUTHORIZED_PERPETUAL",
  enforcement = "enforce",
  features = "BASE,AI_LEARNING",
  license_type = "PERPETUAL",
})
H.advance(1000)
check(
  "moved back: operational, commands go, no reload",
  operational() and tryCommand() and H.clock.timers.AiCoreTick == tickTimer
)

print("[9] trial deadline")
H.entitlement({
  status = "TRIAL",
  enforcement = "enforce",
  features = "BASE,AI_LEARNING",
  license_type = "TRIAL",
  trial_expires_epoch = tostring(os.time() + 3600),
})
check("trial: operational", tryCommand() and prop("License Status") == "Licensed / Trial")
-- The Agent stays reachable but sends no new licence answer.
H.advance(3700 * 1000)
check("past the deadline with no new licence answer: unlicensed", H.vars.AI_STATUS == "unlicensed", H.vars.AI_STATUS)
H.load("DIT_STARTUP")
H.advance(1000)
check("…and still after a restart (persisted deadline)", H.vars.AI_STATUS == "unlicensed", H.vars.AI_STATUS)
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "BASE,AI_LEARNING" })
H.advance(1000)
check("a paid licence clears the trial deadline", operational() and tryCommand(), H.vars.AI_STATUS)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
