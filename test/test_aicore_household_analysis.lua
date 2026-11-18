-- SmartBuildOS AI Core: AI_RUN_HOUSEHOLD_ANALYSIS ("Run Household Analysis"),
-- the programming action that asks the cloud to run the household analysis
-- (op analyze_household). SIMULATION ONLY: the shim + the scripted Agent of
-- test/aicore_harness.lua; no controller, no real platform.
--
--   [1] licence: without AI_LEARNING (enforced, authorised) or under a
--       definitive denial it is refused locally and nothing reaches the cloud
--   [2] accepted: body {command, request_id}, idempotency key = request id;
--       "accepted (queued)" shown, no pending job, no AI Response Ready
--   [3] the loop guard: one accepted run an hour, survives a restart
--   [4] every typed refusal (result.reason), an unknown reason, the
--       Agent's own not_permitted (no reason: update the Agent); a refusal
--       never uses up the hour
--   [5] completed / plain accepted
--   [6] offline (cloud_unreachable) and timeout (no answer): one in flight
--       at a time; neither uses up the hour
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
local NAME = "AI_RUN_HOUSEHOLD_ANALYSIS"
local function counters()
  require("sbos.moduleclient").sendStatus()
  return JSON:decode(H.lastSent("SBOS_MODULE_STATUS").params.counters)
end

local answer = nil -- what the cloud answers analyze_household (nil = queued)
A.cloud = function(op)
  if op == "analyze_household" and answer ~= nil then
    return answer
  end
  if op == "analyze_household" then
    return {
      status = "ok",
      http_status = "200",
      error_code = "ok",
      result = { accepted = true, state = "queued", job_id = "hh-1" },
    }
  end
  return nil
end
local function refusal(code, result)
  return { status = "error", http_status = "200", error_code = code, result = result }
end
--- Presses the action once (inside the shared 10-a-minute budget) and lets
--- the module client finish its retries. Returns whether it reached the cloud.
local function press(waitMs)
  H.advance(7000)
  local n = #A.cloudCalls
  EC[NAME]({})
  H.advance(waitMs or 10000)
  return #A.cloudCalls > n
end
local function household(calls)
  local out = {}
  for _, c in ipairs(calls) do
    if c.op == "analyze_household" then
      out[#out + 1] = c
    end
  end
  return out
end

H.agentPresent = true
H.load("DIT_ADDING")
H.advance(31000)
H.config(H.learningOn(), 1)
check("ready to start", H.vars.AI_STATUS == "ready", H.vars.AI_STATUS)

print("[1] licence: AI_LEARNING, refused locally without a cloud call")
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "BASE" })
check("BASE only: nothing reaches the cloud", not press())
check(
  "…Last Error says the licence lacks AI_LEARNING",
  prop("Last Error"):find("the licence does not include AI_LEARNING", 1, true) ~= nil,
  prop("Last Error")
)
check(
  "…AI Status: refused locally (not_permitted)",
  prop("AI Status"):find("refused locally (not_permitted)", 1, true) ~= nil,
  prop("AI Status")
)
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "AI_LEARNING" })
local sentAt = #A.cloudCalls
EC.AI_ANALYZE_SYSTEM({})
H.advance(2000)
check(
  "the gate is per command: AI_LEARNING without BASE refuses AI_ANALYZE_SYSTEM (BASE) as before",
  #A.cloudCalls == sentAt and H.vars.AI_LAST_ERROR:find("BASE") ~= nil
)
H.entitlement({ status = "CONTROLLER_MISMATCH", enforcement = "enforce", features = "BASE,AI_LEARNING" })
check("a definitive denial: nothing reaches the cloud", not press())
check("…Last Error says not licensed", prop("Last Error"):find("not licensed", 1, true) ~= nil, prop("Last Error"))
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "BASE,AI_LEARNING" })
H.advance(31000)

print("[2] accepted (queued): what goes over the wire, what is shown")
local ready0 = H.firedCount(1)
local c0 = counters()
check("licensed: it reaches the cloud", press())
local call = household(A.cloudCalls)[1]
local keys = {}
for k in pairs(call and call.body or {}) do
  keys[#keys + 1] = k
end
table.sort(keys)
check(
  "op analyze_household, body exactly {command, request_id}",
  call ~= nil and table.concat(keys, ",") == "command,request_id" and call.body.command == NAME,
  table.concat(keys, ",")
)
check(
  "idempotency key = request id = AI_LAST_REQUEST_ID",
  call.idempotency_key == call.body.request_id and H.vars.AI_LAST_REQUEST_ID == call.body.request_id
)
local c1 = counters()
check(
  "last cloud result: accepted (queued)",
  c1.last_cloud_result == NAME .. ": accepted (queued)",
  c1.last_cloud_result
)
check(
  "no job held: AI_STATUS ready, not working",
  H.vars.AI_STATUS == "ready" and prop("AI Status") == "Ready",
  prop("AI Status")
)
check("no AI Response Ready", H.firedCount(1) == ready0)
check("counted as accepted", c1.cloud_accepted == c0.cloud_accepted + 1)
check(
  "Last Error is not a cloud error (a LOCAL refusal stays until replaced, as for every command)",
  prop("Last Error"):find("refused by SmartBuildOS", 1, true) == nil,
  prop("Last Error")
)
local cmdEnv = H.envelopes("ai_core.command")
check(
  "an ai_core.command envelope records the request (requested, not a result)",
  cmdEnv[#cmdEnv] ~= nil
    and cmdEnv[#cmdEnv].payload.op == "analyze_household"
    and cmdEnv[#cmdEnv].evidence_source == "requested"
)
H.advance(31 * 60 * 1000)
check(
  "still nothing pending after the job lifetime",
  counters().jobs_expired == c0.jobs_expired and H.firedCount(1) == ready0
)

print("[3] the loop guard: one accepted run an hour")
local n3 = #A.cloudCalls
for _ = 1, 50 do
  EC[NAME]({})
end
H.advance(1000)
check("50 presses in a loop within the hour: zero cloud calls", #A.cloudCalls == n3, #A.cloudCalls - n3)
check(
  "AI Status: refused locally (rate_limited)",
  prop("AI Status"):find("refused locally (rate_limited)", 1, true) ~= nil,
  prop("AI Status")
)
check(
  "Last Error names the hour and when the next is allowed",
  prop("Last Error"):find("one household analysis an hour", 1, true) ~= nil
    and prop("Last Error"):find("next is allowed after", 1, true) ~= nil,
  prop("Last Error")
)
check(
  "the shared 10-a-minute budget was not drained by the guard",
  (function()
    H.advance(1000)
    local m = #A.cloudCalls
    EC.AI_ANALYZE_SYSTEM({})
    H.advance(1000)
    return #A.cloudCalls == m + 1
  end)()
)
H.load("DIT_STARTUP")
H.advance(31000)
check("after a restart within the hour: still refused locally", not press())
H.advance(30 * 60 * 1000) -- past the hour since the accepted run
check("after the hour: allowed again", press())

print("[4] refusals: the typed reason is shown; a refusal never uses up the hour")
H.advance(61 * 60 * 1000)
for _, case in ipairs({
  { "rate_limited", { reason = "rate_limited", retry_after_seconds = 1800 } },
  { "not_permitted", { reason = "learning_not_allowed" } },
  { "not_permitted", { reason = "not_licensed" } },
  { "not_permitted", { reason = "already_running" } },
  { "not_permitted", { reason = "not_permitted" } },
  { "invalid_args", { reason = "invalid_args" } },
  { "not_permitted", { reason = "a_reason_added_later" } },
}) do
  answer = refusal(case[1], case[2])
  local reached = press()
  local r = case[2].reason
  check(
    r .. ": reached the cloud (the previous refusal used nothing up), AI Status refused (" .. r .. ")",
    reached and prop("AI Status"):find("refused (" .. r .. ")", 1, true) ~= nil,
    prop("AI Status")
  )
  check(
    r .. ": Last Error / AI_LAST_ERROR name it; last cloud result too",
    prop("Last Error"):find("(" .. r .. ")", 1, true) ~= nil
      and H.vars.AI_LAST_ERROR == prop("Last Error")
      and counters().last_cloud_result == NAME .. ": refused (" .. r .. ")",
    prop("Last Error")
  )
end
answer = refusal("rate_limited", { reason = "rate_limited", retry_after_seconds = 1800 })
press()
check(
  "rate_limited: says when SmartBuildOS allows the next run",
  prop("Last Error"):find("about 30 minute", 1, true) ~= nil,
  prop("Last Error")
)
check("rate_limited: the connection is not called unreachable", prop("SmartBuildOS Connection Status") == "Connected")
answer = refusal("not_permitted", nil)
press()
check(
  "not_permitted with NO reason (the Agent refused the op itself): tells the dealer to update the Agent",
  prop("Last Error"):find("update the SmartBuildOS Agent", 1, true) ~= nil,
  prop("Last Error")
)
answer = refusal("cloud_refused", nil)
press()
check(
  "a code without a reason: refused (that code)",
  prop("AI Status"):find("refused (cloud_refused)", 1, true) ~= nil,
  prop("AI Status")
)

print("[5] completed and plain accepted")
answer = { status = "ok", http_status = "200", error_code = "ok", result = { accepted = true, state = "completed" } }
local ready5 = H.firedCount(1)
check("completed: reached the cloud", press())
check(
  "completed: shown as completed",
  counters().last_cloud_result == NAME .. ": completed",
  counters().last_cloud_result
)
check(
  "…the refusal cleared, Last Error none, no AI Response Ready",
  prop("AI Status") == "Ready" and prop("Last Error") == "none" and H.firedCount(1) == ready5
)
H.advance(61 * 60 * 1000)
answer = { status = "ok", http_status = "200", error_code = "ok", result = { accepted = true, job_id = "x" } }
press()
check(
  "accepted with no state: plain 'accepted', never 'completed', no job held",
  counters().last_cloud_result == NAME .. ": accepted" and H.vars.AI_STATUS == "ready",
  counters().last_cloud_result
)
H.advance(61 * 60 * 1000)
answer = { status = "ok", http_status = "200", error_code = "ok", result = { accepted = true, state = "done-ish" } }
press()
check(
  "an unknown state: plain 'accepted'",
  counters().last_cloud_result == NAME .. ": accepted",
  counters().last_cloud_result
)

print("[6] offline and timeout; one in flight at a time")
H.advance(61 * 60 * 1000)
answer = refusal("cloud_unreachable", nil)
check("offline: it tried", press())
check(
  "offline: unreachable (cloud_unreachable), the connection says so",
  counters().last_cloud_result == NAME .. ": unreachable (cloud_unreachable)"
    and prop("SmartBuildOS Connection Status") == "SmartBuildOS cloud unreachable",
  counters().last_cloud_result
)
answer = nil -- back online: queued
check("back online: allowed at once (offline used nothing up)", press())
check("…accepted (queued)", counters().last_cloud_result == NAME .. ": accepted (queued)")
H.advance(61 * 60 * 1000)
A.auto = false -- the Agent takes the frame and never answers
local function framesOut()
  local k = 0
  for _, f in ipairs(H.sentOf("SBOS_MODULE_CLOUD_REQUEST")) do
    if f.params.op == "analyze_household" then
      k = k + 1
    end
  end
  return k
end
local n6 = framesOut()
H.advance(7000)
EC[NAME]({})
H.advance(500)
check("timeout case: the first press went out", framesOut() == n6 + 1, framesOut() - n6)
EC[NAME]({})
H.advance(500)
check("a second press while it is in flight: refused locally, not sent", framesOut() == n6 + 1, framesOut() - n6)
check(
  "…saying a request is already waiting",
  prop("Last Error"):find("already waiting", 1, true) ~= nil,
  prop("Last Error")
)
H.advance(120000) -- the module client gives up (timeout, retries)
A.auto = true
check(
  "the unanswered request ends as unreachable (deadline_exceeded)",
  counters().last_cloud_result == NAME .. ": unreachable (deadline_exceeded)",
  counters().last_cloud_result
)
answer = nil
check("after the timeout: allowed again at once (a timeout used nothing up)", press())
check("nothing reached equipment", #H.equipment == 0)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
