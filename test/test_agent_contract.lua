local Agent = require("sbos.agent_contract")

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and (" -> " .. tostring(detail)) or ""))
  end
end

print("\n[1] Contract identity and strict settings validation")
check("contract version is v1", Agent.CONTRACT_VERSION == 1)
check("driver sku is stable", Agent.DRIVER_SKU == "SBOS_AGENT")
local defaults, defaultRefusals = Agent.validateConfig({})
check("an empty object receives contract defaults", defaults ~= nil and defaults.startupThreshold == 3)
check("defaults have no refusals", #defaultRefusals == 0)
local valid = Agent.validateConfig({
  startupMonitoring = false,
  notificationPolicy = "every-observation",
  countBasis = "controller-reboots",
  startupThreshold = 7,
  stabilizationSeconds = 0,
  serviceModeMinutes = 1440,
  reportSchedule = "weekdays-at-08:00",
  recipientProfileId = "11111111-1111-1111-1111-111111111111",
  autoUpdatePreference = "automatic",
})
check("the complete platform document validates", valid ~= nil and valid.serviceModeMinutes == 1440)
check("equal normalized configs compare equal", Agent.sameConfig(valid, valid))
check("different normalized configs do not compare equal", not Agent.sameConfig(valid, defaults))
local invalid, refusals = Agent.validateConfig({ startupThreshold = 0, surprise = true })
check("one invalid field rejects the whole document", invalid == nil)
check("all invalid fields are named", #refusals == 2)

print("\n[2] Adding and updating never invent system startups")
local state = Agent.newState()
local added = Agent.recordStartup(state, {
  eventId = "agent-start:19:100:1",
  observedAt = "2026-10-19T12:00:00Z",
  localDate = "2026-10-19",
  initReason = "DIT_ADDING",
  observedBootId = "boot-a",
  bootIdSupported = true,
  nowEpoch = 100,
}, defaults)
check("adding is retained as a baseline, not observed", added.ok and not added.observed)
check("adding establishes the boot baseline", added.state.lastBootId == "boot-a")
check("adding does not increment", added.state.systemStartupsLifetime == 0)
local updated = Agent.recordStartup(added.state, {
  eventId = "agent-start:19:101:2",
  observedAt = "2026-10-19T12:01:00Z",
  localDate = "2026-10-19",
  initReason = "DIT_UPDATING",
  observedBootId = "boot-a",
  bootIdSupported = true,
  nowEpoch = 101,
}, defaults)
check("updating is not a startup", updated.ok and not updated.observed and updated.state.systemStartupsLifetime == 0)

print("\n[3] Startup, boot change and identity evidence stay distinct")
local started = Agent.recordStartup(updated.state, {
  eventId = "agent-start:19:102:3",
  observedAt = "2026-10-19T12:02:00Z",
  localDate = "2026-10-19",
  initReason = "DIT_STARTUP",
  observedBootId = "boot-b",
  bootIdSupported = true,
  executionControllerIdentity = "AA:BB:CC:DD:EE:FF",
  primaryControllerIdentity = nil,
  nowEpoch = 102,
}, defaults)
check("startup is observed", started.ok and started.observed)
check(
  "both counters increment on combined evidence",
  started.state.systemStartupsToday == 1 and started.state.controllerRebootsObservedToday == 1
)
check(
  "unknown primary identity prevents a primary reboot claim",
  started.event.primary_controller_reboot_observed == false
)
check("combined evidence is evaluated once", started.state.notificationIntentsToday == 1)
check("first selected event notifies", started.event.notification_decision == "notify")

print("\n[4] Duplicate, rollover and backward clock behavior are bounded")
local duplicate = Agent.recordStartup(started.state, {
  eventId = "agent-start:19:102:3",
  observedAt = "2026-10-19T12:02:00Z",
  localDate = "2026-10-19",
  initReason = "DIT_STARTUP",
  observedBootId = "boot-b",
  bootIdSupported = true,
  nowEpoch = 102,
}, defaults)
check("duplicate event is ignored", duplicate.duplicate and duplicate.state.systemStartupsLifetime == 1)
local tomorrow = Agent.recordStartup(started.state, {
  eventId = "agent-start:19:103:4",
  observedAt = "2026-10-20T00:01:00Z",
  localDate = "2026-10-20",
  initReason = "DIT_STARTUP",
  observedBootId = "boot-b",
  bootIdSupported = true,
  nowEpoch = 103,
}, defaults)
check(
  "new local date resets only daily counters",
  tomorrow.state.systemStartupsToday == 1 and tomorrow.state.systemStartupsLifetime == 2
)
local regressed = Agent.recordStartup(tomorrow.state, {
  eventId = "agent-start:19:104:5",
  observedAt = "2026-10-20T00:02:00Z",
  localDate = "2026-10-18",
  initReason = "DIT_STARTUP",
  observedBootId = "boot-b",
  bootIdSupported = true,
  nowEpoch = 104,
}, defaults)
check(
  "backward local date never resurrects an old bucket",
  regressed.event.clock_status == "regressed" and regressed.state.systemStartupsToday == 1
)
check("lifetime evidence remains usable under bad time", regressed.state.systemStartupsLifetime == 3)

print("\n[5] Service mode is bounded, visible and suppresses notices")
local service = Agent.enterServiceMode(started.state, 1000, 60, "2026-10-19T13:00:00Z")
check("service mode is active", Agent.serviceModeActive(service, 1001))
local suppressed = Agent.recordStartup(service, {
  eventId = "agent-start:19:110:6",
  observedAt = "2026-10-19T12:10:00Z",
  localDate = "2026-10-19",
  initReason = "DIT_STARTUP",
  observedBootId = "boot-b",
  bootIdSupported = true,
  nowEpoch = 1001,
}, defaults)
check(
  "service mode records but suppresses",
  suppressed.observed and suppressed.event.notification_decision == "suppressed-service-mode"
)
check("exit clears both expiry forms", not Agent.serviceModeActive(Agent.exitServiceMode(service), 1001))

print("\n[6] Storm ceiling retains observations and emits one aggregate")
local storm = Agent.restoreState(started.state)
storm.notificationIntentsToday = Agent.STORM_CEILING
local everyObservation = Agent.validateConfig({ notificationPolicy = "every-observation" })
local aggregated = Agent.recordStartup(storm, {
  eventId = "agent-start:19:120:7",
  observedAt = "2026-10-19T12:20:00Z",
  localDate = "2026-10-19",
  initReason = "DIT_STARTUP",
  observedBootId = "boot-b",
  bootIdSupported = true,
  nowEpoch = 1200,
}, everyObservation)
check(
  "first over-ceiling observation becomes the aggregate",
  aggregated.event.notification_decision == "storm-aggregate"
)
local later = Agent.recordStartup(aggregated.state, {
  eventId = "agent-start:19:121:8",
  observedAt = "2026-10-19T12:21:00Z",
  localDate = "2026-10-19",
  initReason = "DIT_STARTUP",
  observedBootId = "boot-b",
  bootIdSupported = true,
  nowEpoch = 1201,
}, everyObservation)
check(
  "later events remain recorded without another aggregate",
  later.observed and later.event.notification_decision == "record-only"
)
check(
  "later event still increments lifetime evidence",
  later.state.systemStartupsLifetime == aggregated.state.systemStartupsLifetime + 1
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
