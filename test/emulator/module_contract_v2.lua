-- Module contract v2 under the Director emulator (EMULATOR ONLY — not a
-- bench result): the real Agent (drivers/smartbuildos) plus two copies of the
-- test-fixture module driver, all exchanging frames through the emulator's
-- asynchronous SendToDevice → ExecuteCommand path. The Agent pairs against
-- the emulator's scripted cloud (examples/connector/fake_cloud.lua, read
-- only); /api/integrations/control4/modules/rpc is answered here.
--
-- Run: test/emulator/run-module-contract-v2.sh   (exit 1 on any failed CHECK)

local EMU = assert(os.getenv("DIRECTOR_EMULATOR"), "DIRECTOR_EMULATOR not set (use the run script)")
local OUT = assert(os.getenv("SBOS_V2_OUT"), "SBOS_V2_OUT not set (use the run script)")
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

local d = Director.new({ cacheDir = os.getenv("DIRECTOR_CACHE") })
local cloud = Cloud.new(d):install()
local rpc = { calls = {}, down = false }
d.http = function(req, dev)
  local path = tostring(req.url):match("^https?://[^/]+(/[^?]*)")
  if path == "/api/integrations/control4/modules/rpc" then
    local body = type(req.body) == "string" and json.decode(req.body) or req.body
    rpc.calls[#rpc.calls + 1] = { body = body, headers = req.headers }
    if rpc.down then
      return nil
    end
    return {
      code = 200,
      headers = { ["Content-Type"] = "application/json" },
      body = json.encode({ ok = true, result = { accepted = true, job_id = "job-" .. #rpc.calls } }),
    }
  end
  return cloud:handle(req, dev)
end

local room = d:addRoom("Equipment")
local agent = assert(d:addDevice(OUT .. "/smartbuildos", { roomId = room, name = "SmartBuildOS" }))
d:setProperty(agent, "Automatic Updates", "Off")
d:advance(1000)
d:setProperty(agent, "Pairing Code", "ABCD-2345")
d:advance(5000)

print("[1] modules register with the real Agent at protocol 2")
local provider = assert(d:addDevice(OUT .. "/sbos-v2-provider", { roomId = room, name = "Probe Provider" }))
local consumer = assert(d:addDevice(OUT .. "/sbos-v2-consumer", { roomId = room, name = "Probe Consumer" }))
d:advance(5000)
d:executeCommand(consumer, "PROBE_INFO", {})
d:executeCommand(provider, "PROBE_INFO", {})
d:run()
local P = consumer.env.PROBE
local Q = provider.env.PROBE
check("Agent paired against the scripted cloud", agent.env.gBus ~= nil and agent.env.gModules ~= nil)
check("both registered", agent.env.gModules:count() == 2, agent.env.gModules:count())
check(
  "consumer negotiated protocol 2, status ready",
  P.registered and P.protocol == 2 and P.display == "ready",
  tostring(P.protocol) .. " " .. tostring(P.display)
)
check("provider negotiated protocol 2", Q.registered and Q.protocol == 2)

print("[2] discovery")
d:executeCommand(consumer, "PROBE_DISCOVER", {})
d:advance(1000)
local fr
for _, m in ipairs(P.directory and P.directory.modules or {}) do
  if m.module_id == "flight_recorder" then
    fr = m
  end
end
check(
  "directory lists the provider with its manifest",
  fr ~= nil and fr.capabilities[1].id == "events.query",
  P.directory_code
)
check("directory changes were pushed after the registrations", P.changes >= 1, P.changes)

print("[3] pub/sub through the Agent's accepted-envelope path")
d:executeCommand(consumer, "PROBE_SUBSCRIBE", { ID = "fr", TOPIC = "capture." })
d:advance(1000)
check("subscription granted by MODULE_TOPIC_POLICY", P.subscribed == "ok", P.subscribed)
d:executeCommand(provider, "PROBE_EMIT", { TYPE = "capture.device", N = "7" })
d:advance(5000)
check("the provider's envelope reached the consumer", #P.events == 1 and P.events[1].payload.n == 7, #P.events)
check(
  "the Agent stamped the installation id on it",
  P.events[1] and P.events[1].installation_id ~= nil and P.events[1].installation_id ~= ""
)

print("[4] request / response")
d:executeCommand(consumer, "PROBE_REQUEST", { TAG = "ok" })
d:advance(2000)
local a = P.answers.ok
check(
  "answered by the provider, sender stamped both ways",
  a and a.status == "ok" and a.from_module_id == "flight_recorder" and a.result.asked_by == "ai_core",
  a and a.error_code
)
check("the provider's handler ran once", Q.served == 1, Q.served)
d:executeCommand(consumer, "PROBE_REQUEST", { TAG = "denied", CAPABILITY = "events.delete" })
d:advance(1000)
check(
  "a capability outside MODULE_REQUEST_POLICY → not_permitted",
  P.answers.denied and P.answers.denied.error_code == "not_permitted"
)
d:executeCommand(consumer, "PROBE_REQUEST", { TAG = "again", KEY = a and a.idempotency_key })
d:advance(1000)
check(
  "same idempotency key → stored answer, provider not asked again",
  P.answers.again and P.answers.again.status == "ok" and P.answers.again.replayed == true and Q.served == 1
)

print("[5] cloud relay over the Agent's authenticated send()")
d:executeCommand(consumer, "PROBE_CLOUD", { TAG = "cloud" })
d:advance(2000)
local c = P.answers.cloud
local call = rpc.calls[1]
check("POST /api/integrations/control4/modules/rpc reached the cloud", call ~= nil)
check(
  "body: module_id, instance_id, op, request_id, idempotency_key, body",
  call
    and call.body.module_id == "ai_core"
    and call.body.instance_id == tostring(consumer.id)
    and call.body.op == "ask"
    and call.body.request_id ~= nil
    and call.body.idempotency_key ~= nil
    and call.body.body.question == "probe"
)
local auth = call and call.headers and (call.headers.Authorization or call.headers.authorization)
check("carried the Agent's pairing token", type(auth) == "string" and auth:find("^Bearer sbc4_") ~= nil, auth)
check("CLOUD_RESPONSE ok with the result", c and c.status == "ok" and c.result.job_id == "job-1", c and c.error_code)
rpc.down = true
local before = #rpc.calls
d:executeCommand(consumer, "PROBE_CLOUD", { TAG = "down" })
d:advance(20000)
local down = P.answers.down
check(
  "cloud unreachable → retried twice (same key), then cloud_unreachable",
  down and down.error_code == "cloud_unreachable" and down.attempts == 3 and #rpc.calls == before + 3,
  down and (down.error_code .. " attempts=" .. tostring(down.attempts) .. " posts=" .. (#rpc.calls - before))
)
rpc.down = false

print("[6] an unauthenticated frame is ignored")
local ignored = agent.env.gBus.totals.ignored
d:sendToDevice(nil, agent.id, "SBOS_MODULE_REQUEST", {
  module_id = "ai_core",
  instance_id = tostring(consumer.id),
  token = "forged",
  request_id = "forged-1",
  to = "flight_recorder",
  capability = "events.query",
  args = "{}",
  deadline = tostring(os.time() + 10),
})
d:advance(1000)
check("counted as ignored, provider not asked", agent.env.gBus.totals.ignored == ignored + 1 and Q.served == 1)

print("[7] Agent update (reload): hello → re-register → re-subscribe")
d:updateDriver(agent)
d:advance(10000)
local sawHello = false
for _, s in ipairs(P.states) do
  if s == "hello" then
    sawHello = true
  end
end
check("the consumer saw the Agent's hello", sawHello)
check(
  "the subscription is back on the reloaded Agent",
  agent.env.gBus:health().subscriptions == 1,
  agent.env.gBus:health().subscriptions
)
d:executeCommand(provider, "PROBE_EMIT", { TYPE = "capture.device", N = "8" })
d:advance(5000)
check("delivery resumes", #P.events == 2 and P.events[2].payload.n == 8, #P.events)

print("[8] runtime errors")
local errs = #agent.errors + #provider.errors + #consumer.errors
check(
  "no Lua runtime errors in any of the three drivers",
  errs == 0,
  (agent.errors[1] or provider.errors[1] or consumer.errors[1])
)

print(string.format("\nEMULATOR ONLY: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
