-- SmartBuildOS AI Core: failure modes the other suites did not name
-- (SIMULATION ONLY: the shim + the scripted Agent of test/aicore_harness.lua).
-- docs/ai-core/TEST-MATRIX.md maps every driver-side item of the product
-- brief's test list to a named test; these are the rows that had none.
--
--   [1] Agent pairing as AI Core sees it: unpaired → paired while running
--   [2] network interruption at the Agent: cloud lost → back, nothing lost
--   [3] Flight Recorder: missing history (truncated ring), a refused query,
--       a recorder that never answers
--   [4] action-approval events: approval_required → action_completed /
--       action_failed, with the approvals count and its conditional
--   [5] refused operations: a forged sender, an unknown operation, an
--       operation the platform is not allowed to send with a device action
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

print("[1] Agent pairing: unpaired → paired while running")
H.agentPresent = true
A.paired = false
H.load("DIT_ADDING")
H.advance(31000)
H.config(H.learningOn(), 1) -- collection is off by default; [2] needs system events
check("AI_STATUS agent_unpaired", H.vars.AI_STATUS == "agent_unpaired", H.vars.AI_STATUS)
check("Agent Pairing Status: Not paired", prop("Agent Pairing Status") == "Not paired", prop("Agent Pairing Status"))
check(
  "Connection Status says the Agent is not paired",
  prop("SmartBuildOS Connection Status") == "SmartBuildOS Agent not paired"
)
check("AGENT_CONNECTED still true (registered and answering)", H.vars.AGENT_CONNECTED == "true")
local events0 = #H.envelopes("ai_core.status")
A.paired = true
EC.SBOS_MODULE_AGENT_STATE(H.auth({ paired = "true", connected = "true" }))
H.pump()
check("paired while running → ready, no reload", H.vars.AI_STATUS == "ready", H.vars.AI_STATUS)
check("Agent Pairing Status: Paired", prop("Agent Pairing Status") == "Paired")
H.advance(31000) -- the module client's stage flushes
local st = H.envelopes("ai_core.status")
check(
  "the transition is recorded (ai_core.status agent_unpaired → ready)",
  #st > events0 and st[#st].payload.state == "ready" and st[#st].payload.previous_state == "agent_unpaired",
  st[#st] and st[#st].payload.previous_state
)

print("[2] network interruption at the Agent")
EC.SBOS_MODULE_AGENT_STATE(H.auth({ paired = "true", connected = "false" }))
H.pump()
check("Agent reports no cloud → cloud_unreachable", H.vars.AI_STATUS == "cloud_unreachable", H.vars.AI_STATUS)
check(
  "AI Status degraded, saying why",
  prop("AI Status") == "Degraded: SmartBuildOS cloud unreachable",
  prop("AI Status")
)
OnSystemEvent('<event name="OnDeviceOffline" id="49"/>')
H.advance(31000)
local offline = H.envelopes("ai_core.observation.system")
check(
  "events keep flowing to the Agent's durable queue meanwhile",
  #offline >= 1 and offline[#offline].payload.event == "OnDeviceOffline"
)
EC.SBOS_MODULE_AGENT_STATE(H.auth({ paired = "true", connected = "true" }))
H.pump()
check("cloud back → ready", H.vars.AI_STATUS == "ready", H.vars.AI_STATUS)

print("[3] Flight Recorder: missing history, refusals, silence")
H.advance(61000)
A.frAnswer = function(capability)
  return "ok",
    {
      capability = capability,
      events = {
        { seq = 401, event_id = "flight_recorder:9001:nb:401", at = "2027-01-15T07:59:00Z", kind = "event" },
      },
      count = 1,
      truncated = true,
      retention = { held = 500, capacity = 500, oldest_available = { seq = 401, at = "2027-01-15T07:59:00Z" } },
    },
    "ok"
end
EC.AI_START_DIAGNOSTIC({ DEVICE = "12" })
H.advance(3000)
local diag = H.envelopes("ai_core.diagnostic")
local fr = diag[#diag].payload.flight_recorder
check(
  "a ring that no longer holds older matching events says truncated, with what it does hold",
  fr.available == true and fr.truncated == true and fr.oldest_available.seq == 401 and fr.held == 500,
  JSON:encode(fr)
)
check("…and nothing is filled in (one event cited, as given)", #fr.events == 1)
A.frAnswer = function()
  return "error", nil, "capability_not_found"
end
H.advance(61000)
EC.AI_START_DIAGNOSTIC({ DEVICE = "12" })
H.advance(3000)
diag = H.envelopes("ai_core.diagnostic")
fr = diag[#diag].payload.flight_recorder
check(
  "a refused query: available=false, request_failed, the code kept",
  fr.available == false and fr.reason == "request_failed" and fr.error_code == "capability_not_found",
  JSON:encode(fr)
)
check(
  "…the cloud op still goes, flagged",
  A.cloudCalls[#A.cloudCalls].op == "start_diagnostic"
    and A.cloudCalls[#A.cloudCalls].body.flight_recorder_available == false
)
A.frAnswer = nil
local realAnswer = A.auto
-- The Agent routes the request but the recorder never answers.
local savedSend = C4.SendToDevice
C4.SendToDevice = function(self, device, command, params)
  if command == "SBOS_MODULE_REQUEST" then
    H.sent[#H.sent + 1] = { device = device, command = command, params = params }
    A.processed = #H.sent -- swallowed: no ACK, no RESPONSE
    return
  end
  return savedSend(self, device, command, params)
end
H.advance(61000)
local cloud0 = #A.cloudCalls
EC.AI_START_DIAGNOSTIC({ DEVICE = "12" })
H.advance(40000) -- timeout 10 s, one retry
diag = H.envelopes("ai_core.diagnostic")
fr = diag[#diag].payload.flight_recorder
check(
  "a recorder that never answers: request_failed / deadline_exceeded, after its retry",
  fr.available == false and fr.reason == "request_failed" and fr.error_code == "deadline_exceeded",
  JSON:encode(fr)
)
check("…and the cloud op still goes once", #A.cloudCalls == cloud0 + 1)
C4.SendToDevice = savedSend
A.auto = realAnswer

print("[4] action-approval events")
local before = { H.firedCount(6), H.firedCount(7), H.firedCount(8) }
local s1 = H.operation("raise_event", {
  event = "approval_required",
  detail = "Close the garage door? (proposed by AI Core, waiting for the homeowner)",
  pending_approvals = 1,
})
check(
  "approval_required Completed → Approval Required fired",
  H.finalState(s1) == "Completed" and H.firedCount(6) == before[1] + 1
)
check(
  "AI_PENDING_APPROVALS 1, APPROVALS_PENDING true, detail shown",
  H.vars.AI_PENDING_APPROVALS == 1
    and TC.APPROVALS_PENDING() == true
    and H.vars.AI_LAST_EVENT_DETAIL:find("garage") ~= nil
)
local s2 =
  H.operation("raise_event", { event = "action_completed", detail = "Garage door closed", pending_approvals = 0 })
check(
  "action_completed → Action Completed, approvals back to 0",
  H.finalState(s2) == "Completed"
    and H.firedCount(7) == before[2] + 1
    and H.vars.AI_PENDING_APPROVALS == 0
    and TC.APPROVALS_PENDING() == false
)
local s3 = H.operation("raise_event", { event = "action_failed", detail = "Garage door did not report closed" })
check(
  "action_failed → Action Failed with its detail",
  H.finalState(s3) == "Completed"
    and H.firedCount(8) == before[3] + 1
    and H.vars.AI_LAST_EVENT_DETAIL == "Garage door did not report closed"
)
local equipment = #H.equipment
check("none of them touched a device", #H.equipment == equipment and #H.equipment == 0)

print("[5] refused operations")
local fired = #H.fired
local results = #H.sentOf("SBOS_MODULE_COMMAND_RESULT")
H.operation("raise_event", { event = "pattern_detected" }, "forged-token")
check(
  "an operation under a forged token is ignored: nothing fired, nothing answered",
  #H.fired == fired and #H.sentOf("SBOS_MODULE_COMMAND_RESULT") == results
)
local s4 = H.operation("open_garage", {})
check("an operation outside the closed list → Failed", H.finalState(s4) == "Failed")
local s5 = H.operation("raise_event", { event = "action_completed", device_id = 20, command = "OPEN" })
local _, why = H.finalState(s5)
check(
  "a device action smuggled into an operation's args → Failed, named",
  H.finalState(s5) == "Failed" and tostring(why):find("not accepted") ~= nil,
  why
)
check("…and still nothing reached equipment", #H.equipment == 0)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
