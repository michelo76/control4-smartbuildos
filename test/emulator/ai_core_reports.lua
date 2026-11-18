-- SmartBuildOS AI Core report hub under the Director emulator (EMULATOR ONLY
-- — not a bench result; no physical controller has run any of this). The
-- REAL Agent, the REAL AI Core and two reporters built on the REAL helper
-- (test/emulator/fixtures/sbos-ai-reporter, assembled as
-- smartbuildos-atmosphere.c4z and smartbuildos-mode-composer.c4z so the
-- Agent's identity binding verifies them) exchange frames through the
-- emulator's asynchronous SendToDevice → ExecuteCommand path. The cloud is
-- scripted: the emulator's fake cloud (pairing, heartbeat, signed licences)
-- plus /api/integrations/control4/modules/rpc answered here.
-- Run: test/emulator/run-ai-core.sh (exit 1 on any failure).

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

local d = Director.new({ cacheDir = os.getenv("DIRECTOR_CACHE") .. "-reports" })
local cloud = Cloud.new(d):install()
cloud.catalog.SBOS_AI_CORE = {
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "SUBSCRIPTION_INCLUDED",
  features = { "BASE", "AI_LEARNING", "AI_ACTIONS" },
}
local rpc = {} -- every modules/rpc call: { op, body, t }
local pending = { commands = {}, enforcement = nil }
d.http = function(req, dev)
  local path = tostring(req.url):match("^https?://[^/]+(/[^?]*)")
  if path == "/api/integrations/control4/modules/rpc" then
    local body = type(req.body) == "string" and json.decode(req.body) or req.body
    rpc[#rpc + 1] = { op = body.op, body = body.body, module_id = body.module_id, t = d.clock:now() }
    return {
      code = 200,
      headers = { ["Content-Type"] = "application/json" },
      body = json.encode({ ok = true, result = { accepted = true } }),
    }
  end
  local resp = cloud:handle(req, dev)
  if resp and resp.code == 200 and path == "/api/integrations/control4/heartbeat" and #pending.commands > 0 then
    local body = json.decode(resp.body)
    body.commands = pending.commands
    pending.commands = {}
    resp.body = json.encode(body)
  elseif resp and resp.code == 200 and path == "/api/driver-cloud/entitlements/refresh" and pending.enforcement then
    local body = json.decode(resp.body)
    body.enforcement = pending.enforcement
    resp.body = json.encode(body)
  end
  return resp
end

local function ops(op, since)
  local out = {}
  for i = (since or 0) + 1, #rpc do
    if rpc[i].op == op then
      out[#out + 1] = rpc[i]
    end
  end
  return out
end
local function items(since, pred)
  local out = {}
  for _, c in ipairs(ops("driver_reports", since)) do
    for _, it in ipairs(c.body.reports or {}) do
      if pred == nil or pred(it) then
        out[#out + 1] = it
      end
    end
  end
  return out
end

local room = d:addRoom("Equipment")
local agent = assert(d:addDevice(OUT .. "/smartbuildos", { roomId = room, name = "SmartBuildOS" }))
d:setProperty(agent, "Automatic Updates", "Off")
d:advance(1000)
d:setProperty(agent, "Pairing Code", "ABCD-2345")
d:advance(5000)
d:setProperty(agent, "Remote Control", "Comfort") -- driver-declared actions need Comfort

local cmdSeq = 0
local function moduleCommand(command, args)
  cmdSeq = cmdSeq + 1
  local requestId = "emu-op-" .. cmdSeq
  pending.commands[#pending.commands + 1] = {
    id = "cmd-" .. cmdSeq,
    command = "MODULE_COMMAND",
    payload = { module_id = "ai_core", command = command, request_id = requestId, args = args or {} },
  }
  d:executeCommand(agent, "SEND_HEARTBEAT", {})
  d:advance(3000)
  local rec = agent.env.gModuleCommands and agent.env.gModuleCommands[requestId]
  return rec and rec.state, rec and rec.detail
end
local uuidN = 0
local function uuid()
  uuidN = uuidN + 1
  return string.format("%08x-5b1c-4c8e-9f00-%012x", uuidN, uuidN)
end

-- Every report request a reporter sends (the "silent when absent" proof).
local reporterIds = {}
local reportFrames = 0
local realSend = d.sendToDevice
d.sendToDevice = function(self, from, id, command, params)
  if from ~= nil and reporterIds[from.id] and command == "SBOS_MODULE_REQUEST" and params and params.capability == "ai_core.report" then
    reportFrames = reportFrames + 1
  end
  return realSend(self, from, id, command, params)
end

print("[1] two reporters, AI Core absent: nothing is sent")
local repA = assert(d:addDevice(OUT .. "/rep-a/smartbuildos-atmosphere", { roomId = room, name = "Reporter A" }))
local repB = assert(d:addDevice(OUT .. "/rep-b/smartbuildos-mode-composer", { roomId = room, name = "Reporter B" }))
reporterIds[repA.id], reporterIds[repB.id] = true, true
d:advance(15000)
check("both reporters started (helper start mode)", repA.env.FIXTURE.started == true and repB.env.FIXTURE.started == true)
d:executeCommand(repA, "EMIT_EVENT", { TEXT = "while absent" })
d:executeCommand(repB, "SET_STATE", { VALUE = "3" })
d:advance(5000)
check("AI Core absent: no report frame left either reporter", reportFrames == 0, reportFrames)
check("…the helper said absent", repA.env.FIXTURE.lastEvent[2] == "absent", repA.env.FIXTURE.lastEvent[2])
check("AI Core property: Not installed", repA.Properties["AI Core"] == "Not installed", repA.Properties["AI Core"])

print("[2] AI Core added: describes and states arrive, stamped by the Agent")
local aic = assert(d:addDevice(OUT .. "/reports/smartbuildos-ai-core", { roomId = room, name = "AI Core" }))
d:advance(60000)
local ver = "20261118.000001" -- stamped by the run script
local aiRow
for _, e in ipairs(agent.env.gModules:instances("ai_core")) do
  aiRow = e
end
check(
  "the Agent's directory lists AI Core at its driver version",
  aiRow ~= nil and aiRow.driver_version == ver,
  aiRow and aiRow.driver_version
)
check(
  "reporter A: Found — reporting (v<AI Core's version>)",
  repA.Properties["AI Core"] == "Found — reporting (v" .. ver .. ")",
  repA.Properties["AI Core"] .. " / " .. ver
)
check("reporter B too", repB.Properties["AI Core"] == "Found — reporting (v" .. ver .. ")", repB.Properties["AI Core"])
local aRow
for _, e in ipairs(agent.env.gModules:instances("atmosphere")) do
  aRow = e
end
check("the Agent verified reporter A (identity binding)", aRow ~= nil and aRow.verified == true)
local function from(mod, dev, kind)
  return function(it)
    return it.from_module_id == mod and it.from_instance_id == tostring(dev.id) and (kind == nil or it.kind == kind)
  end
end
check("a describe from atmosphere@A reached the cloud", #items(0, from("atmosphere", repA, "describe")) >= 1)
check("a describe from mode_composer@B reached the cloud", #items(0, from("mode_composer", repB, "describe")) >= 1)
check("their states too", #items(0, from("atmosphere", repA, "state")) >= 1 and #items(0, from("mode_composer", repB, "state")) >= 1)
local desc = items(0, from("atmosphere", repA, "describe"))[1] or {}
check(
  "the describe item: driver, summary, declared query and actions, 16-hex hash",
  desc.driver and desc.driver.file == "smartbuildos-atmosphere.c4z" and desc.summary == "Test fixture reporter." and #desc.queries == 1 and #desc.actions == 2 and tostring(desc.hash):match("^%x+$") and #desc.hash == 16,
  json.encode(desc)
)
check("every driver_reports call is AI Core's (module_id ai_core)", (function()
  for _, c in ipairs(ops("driver_reports")) do
    if c.module_id ~= "ai_core" then
      return false
    end
  end
  return #ops("driver_reports") > 0
end)())

print("[3] each kind accepted")
local mark = #rpc
d:executeCommand(repA, "EMIT_EVENT", { TEXT = "hello", N = "1" })
d:executeCommand(repB, "EMIT_DIAGNOSTIC", { TEXT = "a fault" })
d:executeCommand(repA, "SET_STATE", { VALUE = "7" })
d:advance(25000)
local ev = items(mark, from("atmosphere", repA, "event"))[1]
local dg = items(mark, from("mode_composer", repB, "diagnostic"))[1]
local st = items(mark, from("atmosphere", repA, "state"))[1]
check("event uploaded, `at` in epoch seconds", ev and ev.text == "hello" and type(ev.at) == "number" and ev.at == math.floor(ev.at), ev and json.encode(ev))
check("diagnostic uploaded", dg and dg.code == "fixture.fault" and dg.severity == "warning")
check("state uploaded with the driver's facts and the baseline", st and st.facts.value == 7 and st.facts.driver_status ~= nil, st and json.encode(st))
check("the helper saw accepted answers", repA.env.FIXTURE.aireport.counters().accepted >= 3)

print("[4] refused: unknown kind, oversize, a sender named in the report")
local function raw(dev, args)
  local n = #dev.env.FIXTURE.raw
  d:executeCommand(dev, "RAW_REPORT", { ARGS = json.encode(args) })
  d:advance(3000)
  local a = dev.env.FIXTURE.raw[n + 1]
  return a and a.result or {}, a
end
local refusedMark = #rpc
local r = raw(repA, { v = 1, kind = "telemetry", facts = {} })
check("unknown kind → accepted false, invalid", r.accepted == false and r.reason == "invalid", json.encode(r))
r = raw(repA, {
  v = 1,
  kind = "describe",
  driver = { name = "x", version = "1", sku = "", file = "smartbuildos-atmosphere.c4z" },
  summary = string.rep("s", 9000),
  controls = {},
  vocabulary = {},
  queries = {},
  actions = {},
  hash = "0123456789abcdef",
})
check("oversize describe (> 8 KB) → accepted false, too_large", r.accepted == false and r.reason == "too_large", json.encode(r))
mark = #rpc
r = raw(repA, { v = 1, kind = "event", type = "x.y", text = "spoof", data = {}, at = os.time(), from_module_id = "pin_lock" })
check("a report naming its sender → accepted false, invalid", r.accepted == false and r.reason == "invalid", json.encode(r))
-- Refusals alone do not trigger a batch; the next accepted report does, and
-- that batch carries the count.
d:advance(61000)
d:executeCommand(repB, "SET_STATE", { VALUE = "4" })
d:advance(25000)
check("…and no item under that name ever reaches the cloud", #items(0, function(it)
  return it.from_module_id == "pin_lock" or it.text == "spoof"
end) == 0)
local batch = ops("driver_reports", refusedMark)[1]
check(
  "the next batch counts the refused reports in `dropped`",
  batch ~= nil and (batch.body.dropped or 0) >= 3,
  batch and json.encode(batch.body.dropped)
)

print("[5] batching within the budget (at most 3 driver_reports a minute)")
mark = #rpc
for i = 1, 24 do
  d:executeCommand(repA, "EMIT_EVENT", { TEXT = "burst " .. i, N = tostring(i) })
  d:executeCommand(repB, "EMIT_DIAGNOSTIC", { TEXT = "burst " .. i })
  d:advance(5000)
end
d:advance(60000)
local times = {}
for _, c in ipairs(ops("driver_reports", mark)) do
  times[#times + 1] = c.t
end
local worst = 0
for i = 1, #times do
  local n = 0
  for j = i, #times do
    if times[j] - times[i] < 60000 then
      n = n + 1
    end
  end
  worst = math.max(worst, n)
end
check(
  "at most 3 batches in any 60 s (" .. worst .. " at most, " .. #times .. " batches)",
  worst <= 3 and #times >= 3,
  worst .. " in a minute over " .. #times .. " batches"
)
local bursts = #items(mark, function(it)
  return (it.kind == "event" or it.kind == "diagnostic") and tostring(it.text):find("^burst") ~= nil
end)
check(
  "every burst report the helpers sent reached the cloud, batched",
  bursts >= 20 and bursts <= 48,
  bursts .. " items (helpers rate-limit at 10 events / 6 diagnostics a minute)"
)

print("[6] a query round trip")
local qref = uuid()
local state = moduleCommand("run_driver_query", {
  query_ref = qref,
  module_id = "atmosphere",
  instance_id = tostring(repA.id),
  query_id = "current_value",
  params = {},
})
d:advance(5000)
local qr
for _, c in ipairs(ops("driver_query_result")) do
  if c.body.query_ref == qref then
    qr = c.body
  end
end
check("driver_query_result completed with the driver's data", qr and qr.status == "completed" and qr.data and qr.data.value == 42, qr and json.encode(qr))
check("the reporter's handler ran once", repA.env.FIXTURE.queries == 1, repA.env.FIXTURE.queries)
check("the Agent's command record ended Completed", agent.env.gModuleCommands["emu-op-" .. cmdSeq].state == "Completed", tostring(state))

print("[7] an action round trip with its real outcome")
local function actionResult(id)
  for _, c in ipairs(ops("driver_action_result")) do
    if c.body.ai_action_id == id then
      return c.body
    end
  end
  return nil
end
local hashA = repA.env.FIXTURE.aireport.declarationHash()
local aid = uuid()
moduleCommand("invoke_driver_action", {
  ai_action_id = aid,
  module_id = "atmosphere",
  instance_id = tostring(repA.id),
  action_id = "set_level",
  params = { level = 7 },
  declaration_hash = hashA,
})
d:advance(5000)
local ar = actionResult(aid)
check("completed, with the driver's result_text", ar and ar.status == "completed" and ar.result_text == "level set to 7", ar and json.encode(ar))
check("the declared handler ran with the approved params", repA.env.FIXTURE.actions == 1 and repA.env.FIXTURE.level == 7)
aid = uuid()
moduleCommand("invoke_driver_action", {
  ai_action_id = aid,
  module_id = "atmosphere",
  instance_id = tostring(repA.id),
  action_id = "jam",
  params = {},
  declaration_hash = hashA,
})
d:advance(5000)
ar = actionResult(aid)
check(
  "the driver refused: failed, its words as result_text (never completed)",
  ar and ar.status == "failed" and ar.error_code == "internal_error" and ar.result_text == "the fixture is jammed",
  ar and json.encode(ar)
)
check("…the Agent's record ended Failed", agent.env.gModuleCommands["emu-op-" .. cmdSeq].state == "Failed")

print("[8] declaration_changed")
d:executeCommand(repA, "CHANGE_DECLARATION", {})
d:advance(3000)
check("the reporter's hash changed", repA.env.FIXTURE.aireport.declarationHash() ~= hashA)
aid = uuid()
local before = repA.env.FIXTURE.actions
moduleCommand("invoke_driver_action", {
  ai_action_id = aid,
  module_id = "atmosphere",
  instance_id = tostring(repA.id),
  action_id = "set_level",
  params = { level = 9 },
  declaration_hash = hashA,
})
d:advance(5000)
ar = actionResult(aid)
check(
  "the approved (old) declaration → failed not_permitted, declaration_changed",
  ar and ar.status == "failed" and ar.error_code == "not_permitted" and ar.result_text == "declaration_changed",
  ar and json.encode(ar)
)
check("…the handler did not run", repA.env.FIXTURE.actions == before)

print("[9] an action for an unverified module is refused")
local realByFile = d.devicesByDriverFile
d.devicesByDriverFile = function(self, name)
  if tostring(name):find("mode%-composer") then
    return nil -- Director gives no answer: the Agent registers it unverified
  end
  return realByFile(self, name)
end
d:updateDriver(repB)
reporterIds[repB.id] = true
d:advance(30000)
local bRow
for _, e in ipairs(agent.env.gModules:instances("mode_composer")) do
  bRow = e
end
check("the Agent registered reporter B unverified", bRow ~= nil and bRow.verified == false, bRow and tostring(bRow.verified))
aid = uuid()
moduleCommand("invoke_driver_action", {
  ai_action_id = aid,
  module_id = "mode_composer",
  instance_id = tostring(repB.id),
  action_id = "set_level",
  params = { level = 1 },
  declaration_hash = repB.env.FIXTURE.aireport.declarationHash(),
})
d:advance(5000)
ar = actionResult(aid)
check(
  "failed not_permitted, target_unverified",
  ar and ar.status == "failed" and ar.error_code == "not_permitted" and ar.result_text == "target_unverified",
  ar and json.encode(ar)
)
check("…nothing reached reporter B", repB.env.FIXTURE.actions == 0)
d.devicesByDriverFile = realByFile
d:updateDriver(repB)
d:advance(30000)

print("[10] AI Core restart → need_describe → describes re-sent at once")
d:advance(61000)
mark = #rpc
local askedA = repA.env.FIXTURE.aireport.counters().describe_requested
d:updateDriver(aic)
d:advance(60000)
d:executeCommand(repA, "SET_STATE", { VALUE = "11" })
d:executeCommand(repB, "SET_STATE", { VALUE = "12" })
d:advance(60000)
check(
  "reporter A was told need_describe and re-sent its describe",
  repA.env.FIXTURE.aireport.counters().describe_requested > askedA,
  repA.env.FIXTURE.aireport.counters().describe_requested
)
check("atmosphere's describe reached the cloud again after the restart", #items(mark, from("atmosphere", repA, "describe")) >= 1)
check("mode_composer's too", #items(mark, from("mode_composer", repB, "describe")) >= 1)
check("reporters still reporting", repA.Properties["AI Core"] == "Found — reporting (v" .. ver .. ")", repA.Properties["AI Core"])

print("[11] an unlicensed AI Core answers, accepting nothing")
pending.enforcement = { SBOS_AI_CORE = "enforce" }
cloud.catalog.SBOS_AI_CORE.status = "ENTITLEMENT_EXPIRED"
d:executeCommand(agent, "REFRESH_ENTITLEMENTS", {})
d:advance(40000)
d:advance(61000)
mark = #rpc
d:executeCommand(repA, "SET_STATE", { VALUE = "13" })
d:advance(5000)
check(
  "reporter A: Found — not licensed (v…)",
  repA.Properties["AI Core"] == "Found — not licensed (v" .. ver .. ")",
  repA.Properties["AI Core"]
)
aid = uuid()
moduleCommand("invoke_driver_action", {
  ai_action_id = aid,
  module_id = "atmosphere",
  instance_id = tostring(repA.id),
  action_id = "set_level",
  params = { level = 2 },
  declaration_hash = repA.env.FIXTURE.aireport.declarationHash(),
})
d:advance(5000)
ar = actionResult(aid)
check("unlicensed: invoke refused (not_permitted, not_licensed)", ar and ar.status == "failed" and ar.result_text == "not_licensed", ar and json.encode(ar))
d:advance(60000)
check("unlicensed: no driver_reports batch", #ops("driver_reports", mark) == 0, #ops("driver_reports", mark))

print("[12] AI Core removed: the reporters go quiet")
d:removeDevice(aic)
d:advance(30000)
local framesBefore = reportFrames
d:executeCommand(repA, "EMIT_EVENT", { TEXT = "after removal" })
d:executeCommand(repB, "EMIT_DIAGNOSTIC", { TEXT = "after removal" })
d:advance(10000)
check("no report frame after AI Core is gone", reportFrames == framesBefore, reportFrames - framesBefore)
check("AI Core property: Not installed", repA.Properties["AI Core"] == "Not installed", repA.Properties["AI Core"])
check(
  "no runtime errors (Agent, AI Core, reporters)",
  #agent.errors + #repA.errors + #repB.errors + #aic.errors == 0,
  agent.errors[1] or repA.errors[1] or repB.errors[1] or aic.errors[1]
)

print(string.format("\nEMULATOR ONLY: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
