-- SmartBuildOS AI Core: the contract fixes from integration against the
-- platform (SIMULATION ONLY: the shim + the scripted Agent of
-- test/aicore_harness.lua; no controller, no real platform).
--
--   [1] raise_event carries an optional correlation_id (the platform's
--       actions service sends one with every approval/action event): the
--       operation completes, the event fires, the id reaches
--       AI_LAST_CORRELATION_ID and the ai_core.event envelope; a malformed
--       one, or any other unknown key, still refuses the whole operation
--   [2] every answer shape the platform's rpc/ops.ts gives, per cloud op:
--       a job ({accepted, job_id}) waits for deliver_result; a synchronous
--       answer ({accepted: true, job_id: null}: set_context,
--       send_notification) is a completed request — no pending job, no
--       "working", no AI Response Ready; learn_preference answers either
--       `unsupported` (no memory library wired) or a synchronous record;
--       rate_limited is a refusal, not silence; status answers its own shape
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
local function counters()
  -- (looked up each time: a reload loads a fresh module client)
  require("sbos.moduleclient").sendStatus()
  return JSON:decode(H.lastSent("SBOS_MODULE_STATUS").params.counters)
end

H.agentPresent = true
H.load("DIT_ADDING")
H.advance(31000)
H.config(H.learningOn(), 1) -- learning is off by default; learn_preference needs it on
check("ready to start", H.vars.AI_STATUS == "ready", H.vars.AI_STATUS)

print("[1] raise_event correlation_id")
local ACTION = "0d6f9a2e-5b1c-4c8e-9f00-123456789abc"
local fired6 = H.firedCount(6)
local s1, opId = H.operation("raise_event", {
  event = "approval_required",
  detail = "AI Core action awaiting approval: lights.set_level",
  pending_approvals = 1,
  correlation_id = ACTION,
})
check(
  "approval_required WITH correlation_id → Completed (it used to end Failed)",
  H.finalState(s1) == "Completed",
  select(2, H.finalState(s1))
)
check("Approval Required fired", H.firedCount(6) == fired6 + 1)
check("AI_LAST_CORRELATION_ID = the action id", H.vars.AI_LAST_CORRELATION_ID == ACTION, H.vars.AI_LAST_CORRELATION_ID)
check(
  "AI_LAST_EVENT_DETAIL unchanged in meaning (the detail only)",
  H.vars.AI_LAST_EVENT_DETAIL == "AI Core action awaiting approval: lights.set_level"
)
H.advance(31000) -- the module client frames the envelope
local ev = H.envelopes("ai_core.event")
local last = ev[#ev]
check(
  "an ai_core.event envelope carries it as its correlation_id",
  last ~= nil and last.correlation_id == ACTION,
  last and tostring(last.correlation_id)
)
check(
  "…and in its payload, with the event, the operation's request id and the count",
  last ~= nil
    and last.payload.correlation_id == ACTION
    and last.payload.event == "approval_required"
    and last.payload.operation_request_id == opId
    and last.payload.pending_approvals == 1
    and last.evidence_source == "system"
    and last.severity == "info"
)

local fired8 = H.firedCount(8)
local s2 = H.operation("raise_event", { event = "action_failed", detail = "Garage door did not report closed" })
check(
  "an event WITHOUT correlation_id → Completed, Action Failed fired",
  H.finalState(s2) == "Completed" and H.firedCount(8) == fired8 + 1
)
check(
  "AI_LAST_CORRELATION_ID cleared: it never names an earlier event's subject",
  H.vars.AI_LAST_CORRELATION_ID == "",
  H.vars.AI_LAST_CORRELATION_ID
)
H.advance(31000)
ev = H.envelopes("ai_core.event")
last = ev[#ev]
check(
  "its envelope has no correlation_id and is a warning (action_failed)",
  last ~= nil and last.correlation_id == nil and last.payload.correlation_id == nil and last.severity == "warning"
)

local fired = #H.fired
local s3 = H.operation("raise_event", { event = "action_completed", correlation_id = string.rep("c", 97) })
check(
  "a correlation_id over 96 characters → Failed, named, nothing fired",
  H.finalState(s3) == "Failed"
    and tostring(select(2, H.finalState(s3))):find("correlation_id") ~= nil
    and #H.fired == fired,
  select(2, H.finalState(s3))
)
local s4 = H.operation("raise_event", { event = "action_completed", correlation_id = "a\nb" })
check("a correlation_id with a control character → Failed", H.finalState(s4) == "Failed" and #H.fired == fired)
local s5 = H.operation("raise_event", { event = "action_completed", correlation_id = ACTION, action_id = ACTION })
check(
  "any OTHER unknown key still refuses the whole operation",
  H.finalState(s5) == "Failed" and tostring(select(2, H.finalState(s5))):find("action_id") ~= nil and #H.fired == fired,
  select(2, H.finalState(s5))
)
H.operation("raise_event", { event = "recommendation_available", correlation_id = "rec-42" })
H.load("DIT_STARTUP")
H.advance(31000)
check(
  "AI_LAST_CORRELATION_ID survives a restart",
  H.vars.AI_LAST_CORRELATION_ID == "rec-42",
  H.vars.AI_LAST_CORRELATION_ID
)

print("[2] every cloud answer shape, per op (rpc/ops.ts)")
--- The platform's answers, as rpc/ops.ts and status.ts write them.
local answers = {}
A.cloud = function(op)
  local a = answers[op]
  if a ~= nil then
    return a
  end
  return {
    status = "ok",
    http_status = "200",
    error_code = "ok",
    raw_result = '{"accepted":true,"job_id":"job-' .. op .. '"}',
  }
end
local function run(name, params)
  H.advance(7000) -- inside the local budget (10 a minute)
  EC[name](params)
  H.advance(10000) -- past the module client's retries (2 s, 5 s) of a retryable code
end

-- set_context: {accepted: true, applied: true, key, job_id: null}
answers.set_context = {
  status = "ok",
  http_status = "200",
  error_code = "ok",
  raw_result = '{"accepted":true,"applied":true,"key":"vacation","job_id":null}',
}
local c0 = counters()
local ready0 = H.firedCount(1)
run("AI_SET_CONTEXT", { KEY = "Vacation", VALUE = "until Sunday" })
check("set_context reached the cloud", A.cloudCalls[#A.cloudCalls].op == "set_context")
check(
  "set_context {accepted, job_id: null} → AI_STATUS ready, NOT working",
  H.vars.AI_STATUS == "ready",
  H.vars.AI_STATUS
)
check("AI Status says Ready (nothing is waiting)", prop("AI Status") == "Ready", prop("AI Status"))
local c1 = counters()
check(
  "counted as completed, not as an accepted job",
  c1.cloud_completed == c0.cloud_completed + 1 and c1.cloud_accepted == c0.cloud_accepted,
  JSON:encode({ c1.cloud_completed, c1.cloud_accepted })
)
check("last cloud result: completed", c1.last_cloud_result == "AI_SET_CONTEXT: completed", c1.last_cloud_result)
check("no error shown", prop("Last Error") == "none", prop("Last Error"))

-- send_notification: {accepted: true, sent: {...}, job_id: null}
answers.send_notification = {
  status = "ok",
  http_status = "200",
  error_code = "ok",
  raw_result = '{"accepted":true,"sent":{"audience":"homeowner","homeowner":{"recipients":2}},"job_id":null}',
}
run("AI_SEND_NOTIFICATION", { TITLE = "Garage", MESSAGE = "Left open", AUDIENCE = "Homeowner" })
check(
  "send_notification {accepted, job_id: null} → ready, not working",
  H.vars.AI_STATUS == "ready",
  H.vars.AI_STATUS
)
check(
  "last cloud result: completed",
  counters().last_cloud_result == "AI_SEND_NOTIFICATION: completed",
  counters().last_cloud_result
)
H.advance(31 * 60 * 1000) -- past the pending-job lifetime
check("no AI Response Ready for either, ever", H.firedCount(1) == ready0, H.firedCount(1) - ready0)
check("and no job expired: none was ever tracked", counters().jobs_expired == c0.jobs_expired, counters().jobs_expired)

-- a job op: {accepted: true, job_id} → waits for deliver_result
run("AI_ANALYZE_SYSTEM", {})
check("analyze_system {accepted, job_id} → working", H.vars.AI_STATUS == "working", H.vars.AI_STATUS)
local ds = H.operation(
  "deliver_result",
  { response_id = "resp-1", job_id = "job-analyze_system", text = "All quiet.", kind = "analysis" }
)
check(
  "its deliver_result → ready, AI Response Ready",
  H.finalState(ds) == "Completed" and H.vars.AI_STATUS == "ready" and H.firedCount(1) == ready0 + 1
)

-- learn_preference: not registered on the platform → unsupported
answers.learn_preference =
  { status = "ok", http_status = "200", error_code = "unsupported", result = { op = "learn_preference" } }
answers.learn_preference.status = "error"
run("AI_LEARN_PREFERENCE", { STATEMENT = "Kitchen lights at 40% after 10 pm" })
check("learn_preference reached the cloud", A.cloudCalls[#A.cloudCalls].op == "learn_preference")
check(
  "learn_preference unsupported → refused as it is, no job",
  H.vars.AI_STATUS == "ready" and prop("Last Error"):find("unsupported") ~= nil,
  prop("Last Error")
)
check("AI Status names the refusal", prop("AI Status"):find("refused %(unsupported%)") ~= nil, prop("AI Status"))
-- learn_preference where the platform's memory library is wired:
-- {accepted: true, applied: true, memory_id, created, job_id: null}
answers.learn_preference = {
  status = "ok",
  http_status = "200",
  error_code = "ok",
  raw_result = '{"accepted":true,"applied":true,"memory_id":"m-1","created":true,"job_id":null}',
}
local readyBefore = H.firedCount(1)
run("AI_LEARN_PREFERENCE", { STATEMENT = "Kitchen lights at 40% after 10 pm" })
check(
  "learn_preference recorded at once (job_id null) → completed, ready, the refusal cleared",
  H.vars.AI_STATUS == "ready"
    and counters().last_cloud_result == "AI_LEARN_PREFERENCE: completed"
    and prop("AI Status") == "Ready"
    and H.firedCount(1) == readyBefore,
  prop("AI Status")
)

-- send_notification over the platform's per-system limit
answers.send_notification =
  { status = "error", http_status = "200", error_code = "rate_limited", result = { retry_after_seconds = 3600 } }
run("AI_SEND_NOTIFICATION", { TITLE = "Garage", MESSAGE = "Left open again" })
check(
  "send_notification rate_limited → refused, says rate limited (not 'no answer'), no job",
  H.vars.AI_STATUS == "ready"
    and prop("Last Error"):find("rate limited") ~= nil
    and prop("Last Error"):find("no answer") == nil,
  prop("Last Error")
)
check(
  "…and the connection is not called unreachable",
  prop("SmartBuildOS Connection Status") == "Connected",
  prop("SmartBuildOS Connection Status")
)

-- test_provider: a job; then rate_limited; then (defensively) no job id
H.advance(61000)
EC.TEST_AI_CONNECTION()
H.advance(2500)
check(
  "test_provider {accepted, job_id} → the test waits for AI Response Ready",
  prop("Last Test Result"):find("job job%-test_provider") ~= nil and H.vars.AI_STATUS == "working",
  prop("Last Test Result")
)
H.operation("deliver_result", { response_id = "resp-2", job_id = "job-test_provider", text = "Provider reachable." })
answers.test_provider =
  { status = "error", http_status = "200", error_code = "rate_limited", result = { retry_after_seconds = 3600 } }
EC.TEST_AI_CONNECTION()
H.advance(10000)
check(
  "test_provider rate_limited → shown as refused (rate_limited), nothing pending",
  prop("Last Test Result") == "AI connection: refused (rate_limited)" and H.vars.AI_STATUS == "ready",
  prop("Last Test Result")
)
answers.test_provider =
  { status = "ok", http_status = "200", error_code = "ok", raw_result = '{"accepted":true,"job_id":null}' }
EC.TEST_AI_CONNECTION()
H.advance(2500)
check(
  "test_provider without a job id → no promise of a result, nothing pending",
  prop("Last Test Result") == "AI connection: answered by SmartBuildOS (no result follows)"
    and H.vars.AI_STATUS == "ready",
  prop("Last Test Result")
)

-- status (Sync Now): its own synchronous shape, no `accepted`
answers.status = {
  status = "ok",
  http_status = "200",
  error_code = "ok",
  raw_result = '{"module_id":"ai_core","protocol":{"min":1,"max":2},"property_linked":true}',
}
local syncBefore = prop("Last Synchronization")
H.advance(1000)
EC.SYNC_NOW()
H.advance(2500)
check(
  "status answered (no `accepted` in its shape) → synchronised, no Sync Now error, nothing pending",
  H.vars.AI_STATUS == "ready"
    and prop("Last Synchronization") ~= syncBefore
    and prop("Last Error"):find("Sync Now") == nil,
  prop("Last Error")
)
answers.status = { status = "error", http_status = "200", error_code = "not_permitted", result = { reason = "x" } }
EC.SYNC_NOW()
H.advance(2500)
check(
  "status refused → Last Error names it",
  prop("Last Error") == "Sync Now: refused by SmartBuildOS: not_permitted",
  prop("Last Error")
)
check("nothing reached equipment", #H.equipment == 0)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
