-- SmartBuildOS AI Core: robustness against malformed input (SIMULATION ONLY,
-- the shim + the scripted Agent of test/aicore_harness.lua).
--
-- Every entry point Director or the Agent can reach is driven with
-- malformed frames, configuration, cloud answers, Flight Recorder answers,
-- persisted state and Director callbacks. The rule: nothing throws out of a
-- handler, nothing is half-applied, and every operation reaches a final
-- state (fail closed, never fail silent).
--
--   [1]  every EC handler is pcall-safe against malformed params
--   [2]  a malformed directory does not break discovery or the liveness probe
--   [3]  a malformed Flight Recorder answer still yields ONE diagnostic, and
--        run_diagnostic still reaches a final state
--   [4]  Director callbacks (OnSystemEvent, OnWatchedVariableChanged) never throw
--   [5]  corrupted persisted state cannot stop the driver from starting
--   [6]  the persisted buffer is bounded on load; an id-less envelope is refused
--   [7]  OnDriverDestroyed cancels every timer the driver, the module client,
--        the bus client and the licence SDK armed
--   [8]  module tokens are never printed, even at Log Level 5 (Trace)
--   [9]  a refusal reason built from a platform-chosen key is bounded
--   [10] persistence does not grow with use
--   [11] raise_event ai_provider_error → AI Provider Error + AI_LAST_ERROR
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

-- Everything printed (the vendored handler debug output ends in print()).
local printed = {}
local realPrint = print
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring((select(i, ...)))
  end
  printed[#printed + 1] = table.concat(parts, "\t")
  realPrint(...)
end

local H = require("aicore_harness")
local A = H.agent

local function ready()
  H.agentPresent = true
  H.load("DIT_ADDING")
  H.advance(31000)
  H.advance(61000)
end
ready()
check("setup: AI Core ready behind the scripted Agent", H.vars.AI_STATUS == "ready", H.vars.AI_STATUS)

print("[1] every EC handler is pcall-safe against malformed params")
local LONG = string.rep("x", 70000)
local junk = {
  {},
  { token = A.token, module_id = "ai_core", instance_id = tostring(H.SELF_ID) },
  {
    module_id = "ai_core",
    instance_id = tostring(H.SELF_ID),
    token = A.token,
    request_id = LONG,
    subscription_id = "fr",
    events = '[1,2,"x",{"event_id":{}}]',
    modules = '{"a":1}',
    agent = "5",
    result = "not json",
    args = "[1,2,3]",
    command = "raise_event",
    settings = "[]",
    settings_version = "x",
    directory_version = "NaN",
    dropped = "-5",
    status = "ok",
    error_code = LONG,
    protocol = "99",
    ok = "true",
  },
  { QUESTION = LONG, ROOM = { 1 }, DEVICE = "-1", KEY = 5, NAME = "\0\1\2", CATEGORY = LONG },
}
local names = {}
for name, fn in pairs(EC) do
  if type(fn) == "function" then
    names[#names + 1] = name
  end
end
table.sort(names)
local thrown = {}
for _, name in ipairs(names) do
  for i, params in ipairs(junk) do
    local copy = {}
    for k, v in pairs(params) do
      copy[k] = v
    end
    local ok, err = pcall(EC[name], copy)
    if not ok then
      thrown[#thrown + 1] = name .. "#" .. i .. ": " .. tostring(err):sub(1, 120)
    end
    H.pump()
  end
  local ok, err = pcall(EC[name], nil)
  if not ok then
    thrown[#thrown + 1] = name .. "#nil: " .. tostring(err):sub(1, 120)
  end
  H.pump()
end
check(
  "no handler threw (" .. #names .. " handlers × " .. (#junk + 1) .. " malformed inputs)",
  #thrown == 0,
  table.concat(thrown, " | ")
)
H.advance(61000)
check(
  "…and the driver still answers afterwards",
  H.vars.AI_STATUS == "ready" or H.vars.AI_STATUS == "working",
  H.vars.AI_STATUS
)

print("[2] a malformed directory does not break discovery or the liveness probe")
local function directoryFrame(modules, agent)
  local disc = H.lastSent("SBOS_MODULE_DISCOVER")
  return pcall(
    EC.SBOS_MODULE_DIRECTORY,
    H.auth({
      request_id = disc.params.request_id,
      error_code = "ok",
      directory_version = "7",
      agent = agent,
      modules = modules,
      truncated = "false",
    })
  )
end
A.auto = false
EC.TEST_AGENT_LINK()
local okD, errD = directoryFrame('[1, true, "flight_recorder", {"module_id":5}]', "5")
check("TEST_AGENT_LINK with a malformed directory does not throw", okD, errD)
check(
  "…and says what it got (no module counted as the recorder)",
  H.prop("Last Test Result"):find("Agent link: OK") ~= nil,
  H.prop("Last Test Result")
)
EC.TEST_AGENT_LINK()
okD, errD = directoryFrame("[]", JSON:encode({ version = string.rep("v", 20000), protocol_min = string.rep("1", 500) }))
check(
  "an oversized Agent version is bounded in Last Test Result",
  okD and #H.prop("Last Test Result") <= 200,
  #tostring(H.prop("Last Test Result"))
)
EC.TEST_AGENT_LINK()
okD, errD = directoryFrame("[]", JSON:encode({ version = string.rep("v", 39) .. "é", protocol_min = "1" }))
check(
  "an Agent version cut at 40 bytes in Last Test Result is cut between characters",
  okD and H.prop("Last Test Result"):find("Agent " .. string.rep("v", 39) .. ",", 1, true) ~= nil,
  H.prop("Last Test Result")
)
EC.SYNC_NOW()
okD, errD = directoryFrame('[1, true, {"module_id":"flight_recorder","capabilities":7,"protocol":{}}]', "[]")
check("the recorder probe with a malformed directory does not throw", okD, errD)
A.auto = true
EC.SYNC_NOW()
H.advance(61000)
check(
  "discovery still works on the next well-formed directory",
  H.prop("Flight Recorder Link"):find("^Installed: local history served") ~= nil,
  H.prop("Flight Recorder Link")
)

print("[3] a malformed Flight Recorder answer still yields ONE diagnostic")
A.frAnswer = function()
  return "ok",
    { events = { 5, "text", { event_id = { nested = true }, at = 3, kind = {} }, false }, retention = 7 },
    "ok"
end
local diag0 = #H.envelopes("ai_core.diagnostic")
local calls0 = #A.cloudCalls
local fr0 = #A.frRequests
EC.AI_START_DIAGNOSTIC({ DEVICE = "12" })
H.advance(3000)
check("the Flight Recorder was asked", #A.frRequests == fr0 + 1)
check(
  "AI_START_DIAGNOSTIC recorded one diagnostic envelope",
  #H.envelopes("ai_core.diagnostic") == diag0 + 1,
  #H.envelopes("ai_core.diagnostic") - diag0
)
check(
  "…and called start_diagnostic",
  #A.cloudCalls == calls0 + 1 and A.cloudCalls[#A.cloudCalls].op == "start_diagnostic"
)
local _, opId = H.operation("run_diagnostic", { device_id = 12 })
H.advance(3000)
local final = nil
for _, s in ipairs(H.sentOf("SBOS_MODULE_COMMAND_RESULT")) do
  if s.params.request_id == opId then
    final = s.params.state
  end
end
check("run_diagnostic reached a final state (Completed)", final == "Completed", final)
A.frAnswer = nil

print("[4] Director callbacks never throw")
local cbThrown = {}
for _, args in ipairs({
  { nil },
  { 42 },
  { {} },
  { '<event name="OnDeviceOffline"' },
  { LONG },
  { '<event name="' .. LONG .. '"/>' },
}) do
  local ok, err = pcall(OnSystemEvent, args[1])
  if not ok then
    cbThrown[#cbThrown + 1] = "OnSystemEvent: " .. tostring(err)
  end
end
for _, args in ipairs({ { nil, nil, nil }, { "x", {}, LONG }, { 12, 1000, {} }, { {}, {}, {} } }) do
  local ok, err = pcall(OnWatchedVariableChanged, args[1], args[2], args[3])
  if not ok then
    cbThrown[#cbThrown + 1] = "OnWatchedVariableChanged: " .. tostring(err)
  end
end
check("no Director callback threw", #cbThrown == 0, table.concat(cbThrown, " | "))

print("[5] corrupted persisted state cannot stop the driver from starting")
local saved = {}
for k, v in pairs(H.persisted) do
  saved[k] = v
end
-- Stop first: OnDriverDestroyed saves the live state over the document.
OnDriverDestroyed()
H.loaded = false
H.persisted.aicore_last_v1 = {
  response = { "a table" },
  response_id = 5,
  request_id = {},
  event_detail = true,
  error = { nested = { deeper = 1 } },
  sync_at = "yesterday",
  pending_approvals = "many",
  recommendation_count = {},
  test = 7,
  cloud_result = {},
}
H.persisted.aicore_config_v1 = { cfg = "not a table", version = {} }
H.persisted.aicore_learning_v1 = { active = "yes" }
H.persisted.aicore_buffer_v1 = { items = "nope", dropped = {} }
local okLoad, errLoad = pcall(H.load, "DIT_STARTUP")
if okLoad then
  okLoad, errLoad = pcall(H.advance, 31000)
end
check("LateInit completed (Driver Status Online)", okLoad and H.props["Driver Status"] == "Online", errLoad)
check("timers armed", H.clock.timers.AiCoreTick ~= nil and H.clock.timers.AiCoreLiveness ~= nil)
check(
  "Last Error painted as text, never a table",
  type(H.prop("Last Error")) == "string" and H.prop("Last Error") == "none",
  tostring(H.prop("Last Error"))
)
local okTc, tcPending = pcall(TC.APPROVALS_PENDING)
check("the corrupted counters read as numbers", okTc and tcPending == false and TC.RECOMMENDATIONS_AVAILABLE() == false)
check("the driver works afterwards", H.vars.AI_STATUS == "ready" or H.vars.AI_STATUS == "working", H.vars.AI_STATUS)
for k in pairs(H.persisted) do
  H.persisted[k] = nil
end
for k, v in pairs(saved) do
  H.persisted[k] = v
end

print("[6] the persisted buffer is bounded on load; an id-less envelope is refused")
local Buffer = require("aicore.buffer")
local many = {}
for i = 1, 500 do
  many[i] = { event_id = "e" .. i, severity = (i % 2 == 0) and "warning" or "critical" }
end
local b = Buffer.new({
  load = function()
    return { items = many, dropped = 2 }
  end,
  save = function() end,
})
check("a 500-item persisted buffer loads at most capacity (50)", b:depth() == 50, b:depth())
check("…the excess is counted as dropped", b:counters().dropped == 2 + 450, b:counters().dropped)
local kept = b.items
check(
  "…the most severe are kept, then the newest",
  kept[1].severity == "critical" and kept[#kept].event_id == "e499",
  kept[#kept] and kept[#kept].event_id
)
local okPush, outcome = pcall(b.push, b, { severity = "critical" })
check("an envelope without an event id is refused, not thrown", okPush and outcome == "invalid", tostring(outcome))

print("[7] OnDriverDestroyed cancels every timer")
EC.AI_ASK({ QUESTION = "anything in flight?" }) -- arms request/deadline timers
A.auto = false
EC.TEST_AGENT_LINK() -- a discover left waiting
OnDriverDestroyed()
local left = {}
for id in pairs(H.clock.timers) do
  left[#left + 1] = id
end
table.sort(left)
check("no timer left behind", #left == 0, table.concat(left, ", "))
A.auto = true
H.loaded = false
ready()

print("[8] module tokens are never printed, even at Log Level 5 (Trace)")
OPC.Log_Level("5 - Trace")
printed = {}
local secretToken = "tok-SECRET-0123456789"
H.register(2, { token = secretToken })
A.token = secretToken
H.pump()
for _, cmd in ipairs({ "SBOS_MODULE_COMMAND", "SBOS_MODULE_PUBLISH", "SBOS_MODULE_DIRECTORY", "SBOS_MODULE_RESPONSE" }) do
  ExecuteCommand(cmd, H.auth({ request_id = "r-1", subscription_id = "fr", events = "[]", command = "refresh_status" }))
end
ExecuteCommand("SBOS_MODULE_REGISTERED", { module_id = "ai_core", token = secretToken, ok = "true" })
local leaked = {}
for _, line in ipairs(printed) do
  if line:find(secretToken, 1, true) then
    leaked[#leaked + 1] = line:sub(1, 80)
  end
end
check("no printed line carries the module token", #leaked == 0, table.concat(leaked, " | "))
OPC.Log_Level("3 - Info")

print("[9] a refusal reason built from a platform-chosen key is bounded")
local hugeKey = string.rep("k", 5000)
local states = H.operation("raise_event", { event = "pattern_detected", [hugeKey] = 1 })
local _, detail = H.finalState(states)
check("the operation is refused", H.finalState(states) == "Failed")
check("its detail is bounded (≤ 240)", #tostring(detail) <= 240, #tostring(detail))
-- A key whose 64th byte starts a two-byte character: cut before it, never
-- through it (the detail travels to the platform as JSON).
states = H.operation("raise_event", { event = "pattern_detected", [string.rep("k", 63) .. "é"] = 1 })
_, detail = H.finalState(states)
check(
  "a multi-byte key is cut between characters in the refusal",
  tostring(detail):find("'" .. string.rep("k", 63) .. "'", 1, true) ~= nil,
  detail
)

print("[10] persistence does not grow with use")
for i = 1, 300 do
  H.operation("deliver_result", { response_id = "r" .. i, text = string.rep("y", 3999) })
  H.operation("raise_event", { event = "pattern_detected", detail = string.rep("z", 600) })
  OnSystemEvent('<event name="OnDeviceOffline" id="49"/>')
end
H.advance(1000)
local sizes, worst = {}, 0
for k, v in pairs(H.persisted) do
  local n = #JSON:encode(v)
  sizes[#sizes + 1] = k .. "=" .. n
  worst = math.max(worst, n)
end
check("every persisted value stays under 64 KB after 900 operations", worst < 64 * 1024, table.concat(sizes, ", "))

print("[11] raise_event ai_provider_error → AI Provider Error + AI_LAST_ERROR")
local fired0 = H.firedCount(10)
states = H.operation("raise_event", { event = "ai_provider_error", detail = "Anthropic: rate limited (429)" })
check("Completed", H.finalState(states) == "Completed")
check("AI Provider Error (event 10) fired", H.firedCount(10) == fired0 + 1)
check(
  "AI_LAST_ERROR names the provider error",
  tostring(H.vars.AI_LAST_ERROR):find("AI provider error: Anthropic: rate limited %(429%)") ~= nil,
  H.vars.AI_LAST_ERROR
)
check("Last Error property too", H.prop("Last Error"):find("AI provider error") ~= nil, H.prop("Last Error"))
H.operation("raise_event", { event = "ai_provider_error" })
check(
  "with no detail it still says so",
  H.vars.AI_LAST_ERROR == "AI provider error (no detail from SmartBuildOS)",
  H.vars.AI_LAST_ERROR
)
H.operation("deliver_result", { response_id = "after-error", text = "The provider answered again." })
check("a delivered result clears the provider error", H.vars.AI_LAST_ERROR == "", H.vars.AI_LAST_ERROR)
H.operation("raise_event", { event = "ai_provider_error", detail = "x" })
EC.AI_ASK({ QUESTION = "" }) -- a local refusal replaces it
H.operation("deliver_result", { response_id = "after-local", text = "ok" })
check(
  "a later local refusal is not cleared by a result",
  tostring(H.vars.AI_LAST_ERROR):find("QUESTION") ~= nil,
  H.vars.AI_LAST_ERROR
)

print = realPrint
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
