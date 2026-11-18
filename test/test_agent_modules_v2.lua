-- The AGENT driver's contract v2 wiring under the shim (drivers/smartbuildos):
-- EC handlers for every v2 frame, authentication before the bus, sender
-- stamping, the negotiated protocol in the REGISTERED reply (v1 modules stay
-- at 1), UUID registration tokens, fan-out of accepted envelopes, the cloud
-- relay over send() to /api/integrations/control4/modules/rpc, heartbeat
-- bus counters, Agent restart → hello → re-register + re-subscribe, and
-- MODULE_COMMANDS.ai_core through the existing MODULE_COMMAND gateway.
-- The harness prelude is the one test_agent_modules.lua uses.
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

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")

-- ── timers ──────────────────────────────────────────────────────────────────
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    clock.timers[id] = nil
  end
  function KillAllTimers()
    clock.timers = {}
  end
  return true
end
local function advance(ms)
  local target = clock.now + ms
  while true do
    local bestId, bestAt
    for id, t in pairs(clock.timers) do
      if t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and id < bestId)) then
        bestId, bestAt = id, t.at
      end
    end
    if not bestId then
      break
    end
    clock.now = bestAt
    local t = clock.timers[bestId]
    if t.every then
      t.at = clock.now + t.every
    else
      clock.timers[bestId] = nil
    end
    t.cb()
  end
  clock.now = target
end
local realTime = os.time
local base = 1800000000
os.time = function(t)
  if t then
    return realTime(t)
  end
  return base + math.floor(clock.now / 1000)
end
local realDate = os.date
os.date = function(fmt, t)
  return realDate(fmt, t or os.time())
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end
package.preload["drivers-common-public.module.websocket"] = function()
  local WS = {}
  WS.__index = WS
  function WS:new()
    return nil
  end
  return WS
end
package.preload["drivers-common-public.module.ssdp"] = function()
  return {
    new = function()
      return { StartDiscovery = function() end, StopDiscovery = function() end }
    end,
  }
end
package.preload["lib.github-updater"] = function()
  return { checkForUpdates = function() end, updateAll = function() end }
end
package.preload["lib.sbos-updater"] = function()
  return { checkForUpdates = function() end, updateAll = function() end }
end

-- ── persist ─────────────────────────────────────────────────────────────────
local store = {}
package.preload["lib.persist"] = function()
  local EMPTY = {}
  return {
    get = function(_, key, default)
      if default == nil then
        default = EMPTY
      end
      local value = store[key]
      if value == nil then
        return default
      end
      return value
    end,
    set = function(_, key, value)
      store[key] = value
    end,
    delete = function(_, key)
      store[key] = nil
    end,
  }
end

-- ── fake platform behind lib.http ───────────────────────────────────────────
local requests = {}
--- url suffix -> function(data) -> { ok, code, body } ; default accepts.
local responders = {}
local function settled(isOk, value)
  return {
    next = function(_, onOk, onErr)
      if isOk then
        if onOk then
          onOk(value)
        end
      elseif onErr then
        onErr(value)
      end
    end,
  }
end
package.preload["lib.http"] = function()
  return {
    get = function(_, url)
      return settled(true, { url = url, code = 200, headers = {}, body = "" })
    end,
    post = function(_, url, data, headers, options)
      requests[#requests + 1] = { url = url, data = data, headers = headers }
      local path = url:match("/api/integrations/control4/(.*)$") or url:match("/api/driver%-cloud/(.*)$") or url
      local r = responders[path]
      local answer = r and r(data) or { ok = true, code = 200, body = { ok = true } }
      if answer.ok then
        return settled(
          true,
          { url = url, code = answer.code or 200, headers = {}, body = JSON:encode(answer.body or {}) }
        )
      end
      return settled(false, {
        url = url,
        code = answer.code or 0,
        headers = {},
        body = answer.body or "",
        error = answer.error or "unreachable",
      })
    end,
  }
end

-- ── Director ────────────────────────────────────────────────────────────────
local sent = {}
local fired = {}
local MODULE_ID = 501
local PROJECT = {
  [63] = { deviceName = "Home Controller EA5", roomName = "Rack", driverFileName = "control4_ea5.c4z" },
  [12] = { deviceName = "Kitchen Pendants", roomName = "Kitchen", roomId = 3, driverFileName = "light_v2.c4i" },
  [MODULE_ID] = {
    deviceName = "SmartBuildOS Flight Recorder",
    roomName = "Rack",
    driverFileName = "smartbuildos-flight-recorder.c4z",
  },
}
setmetatable(C4, {
  __index = function(_, key)
    -- Anything the driver probes that this test does not model answers nil
    -- (the driver pcalls every such read).
    return function()
      return nil
    end
  end,
})
function C4:GetDevices()
  return PROJECT
end
function C4:GetDeviceVariables(id)
  if tonumber(id) == 12 then
    return {
      [1001] = { name = "LIGHT_LEVEL", value = "40", readonly = "False" },
      [1002] = { name = "LIGHT_STATE", value = "True", readonly = "True" },
    }
  end
  return {}
end
function C4:GetBindingsByDevice()
  return { bindings = {} }
end
function C4:GetNetworkBindingsByDevice()
  return nil
end
function C4:GetProjectItems()
  return ""
end
function C4:GetProjectHierarchy()
  return {}
end
function C4:GetAllCodeItems()
  return {}
end
function C4:GetSystemType()
  return "XDT_EA5"
end
function C4:GetVersionInfo()
  return { version = "4.2.0.0" }
end
function C4:GetDriverConfigInfo(key)
  if key == "minimum_os_version" then
    return "3.3.1"
  end
  return "20261022.100000"
end
function C4:GetDeviceID()
  return 99
end
function C4:GetDeviceData(_, key)
  if key == "name" then
    return "SmartBuildOS Agent"
  end
  return nil
end
function C4:GetTickCount()
  return clock.now
end
function C4:GetBootID()
  return "boot-7"
end
function C4:SendToDevice(device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
end
function C4:FireEvent(name)
  fired[#fired + 1] = name
end
function C4:UpdateProperty(name, value)
  Properties[name] = value
end
function C4:AllowExecute() end
function C4:HMAC()
  return "00"
end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    Properties[name] = block:match("<default>(.-)</default>") or ""
  end
end
Properties["API URL"] = "https://app.smartbuildos.io"
Properties["Heartbeat Interval"] = "1m"
Properties["Log Level"] = "1 - Error"

-- Paired already: the token is the credential; the server derives everything.
store["device_token"] = "sbc4_0123abcd_secret"
store["system_id"] = "7e14128e-fb05-4645-929f-e1ee9e1ee964"

package.path = "./drivers/smartbuildos/?.lua;" .. package.path
dofile("drivers/smartbuildos/driver.lua")

local function sentOf(command, device)
  local out = {}
  for _, s in ipairs(sent) do
    if s.command == command and (device == nil or s.device == device) then
      out[#out + 1] = s
    end
  end
  return out
end
local function lastSent(command)
  local list = sentOf(command)
  return list[#list]
end
local function requestsTo(path)
  local out = {}
  for _, r in ipairs(requests) do
    if r.url:find("/" .. path .. "$") then
      out[#out + 1] = r
    end
  end
  return out
end
-- ─────────────────────────────────────────────────────────────────────────────
local AI_ID = 601
local V1_ID = 701
PROJECT[AI_ID] = { deviceName = "SmartBuildOS AI Core", roomName = "Rack", driverFileName = "smartbuildos-ai-core.c4z" }
PROJECT[V1_ID] = { deviceName = "Usage Analytics", roomName = "Rack", driverFileName = "smartbuildos-usage-analytics.c4z" }

local FR_MANIFEST = JSON:encode({
  driver = "sbos.flight_recorder",
  version = "20261118.120000",
  protocol = 2,
  capabilities = {
    { id = "events.query", version = 1, kind = "request" },
    { id = "events.subscribe", version = 1, kind = "topic", topics = { "capture.", "observation.", "trace." } },
  },
})

local function register(id, moduleId, over)
  local p = {
    module_id = moduleId,
    instance_id = tostring(id),
    requester = tostring(id),
    driver_version = "1",
    protocol_min = "1",
    protocol_max = "2",
    singleton = "true",
  }
  for k, v in pairs(over or {}) do
    p[k] = v
  end
  EC.SBOS_MODULE_REGISTER(p)
  local list = sentOf("SBOS_MODULE_REGISTERED", id)
  return list[#list] and list[#list].params or {}
end

local function auth(id, moduleId, token, extra)
  local p = { module_id = moduleId, instance_id = tostring(id), token = token }
  for k, v in pairs(extra or {}) do
    p[k] = v
  end
  return p
end

print("[1] the v2 Agent comes up")
OnDriverInit()
OnDriverLateInit("DIT_STARTUP")
do
  local hb = requestsTo("heartbeat")[1]
  local caps = {}
  for _, c in ipairs(hb.data.capabilities) do
    caps[c] = true
  end
  check("heartbeat module_protocol 1..2", hb.data.module_protocol.min == 1 and hb.data.module_protocol.max == 2)
  check("capabilities advertise modules_v1 AND modules_v2", caps.modules_v1 and caps.modules_v2)
  check("module_bus block on the heartbeat", type(hb.data.module_bus) == "table" and hb.data.module_bus.requests == 0)
end

print("[2] registration matrix + tokens")
local fr = register(MODULE_ID, "flight_recorder", { manifest = FR_MANIFEST })
check("v2 module negotiates 2", fr.ok == "true" and fr.protocol == "2", fr.protocol)
check("the reply still carries the Agent's range", fr.agent_protocol_min == "1" and fr.agent_protocol_max == "2")
check("token falls back to the v1 generator when C4:UUID is not a UUID (shim)", #fr.token == 32 and fr.token:match("^%x+$") ~= nil)
local v1 = register(V1_ID, "usage_analytics", { protocol_max = "1", manifest = FR_MANIFEST })
check("v1 module gets protocol 1, not the Agent's max (negotiated survives the agent-state merge)", v1.protocol == "1", v1.protocol)
check("a v1 registration stores no manifest", gModules:find("usage_analytics", tostring(V1_ID)).manifest == nil)
local realUUID = C4.UUID
function C4:UUID(kind)
  if kind == "RANDOM" then
    return "0F8FAD5B-D9CB-469F-A165-70867728950E"
  end
  return nil
end
local ai = register(AI_ID, "ai_core", { manifest = '{"driver":"sbos.ai_core","capabilities":[]}' })
check("token from C4:UUID(\"RANDOM\") when Director has it", ai.token == "0f8fad5bd9cb469fa16570867728950e", ai.token)
C4.UUID = realUUID
check(
  "manifest stored for the v2 module",
  gModules:find("flight_recorder", tostring(MODULE_ID)).manifest.capabilities[1].id == "events.query"
)

print("[3] unauthenticated v2 frames are ignored (no answer at all)")
sent = {}
EC.SBOS_MODULE_DISCOVER(auth(AI_ID, "ai_core", "wrong", { request_id = "d0" }))
EC.SBOS_MODULE_REQUEST(auth(AI_ID, "ai_core", "", {
  request_id = "r0",
  to = "flight_recorder",
  capability = "events.query",
  args = "{}",
  deadline = tostring(os.time() + 10),
}))
EC.SBOS_MODULE_SUBSCRIBE(auth(AI_ID, "ai_core", fr.token, { subscription_id = "s0", topics = '["capture."]' }))
EC.SBOS_MODULE_CLOUD_REQUEST(auth(AI_ID, "ai_core", nil, { request_id = "c0", op = "ask", body = "{}", deadline = tostring(os.time() + 10) }))
check("no frame of any kind sent back", #sent == 0, #sent)
check("nothing posted to the cloud", #requestsTo("modules/rpc") == 0)
check("ignored frames counted", gBus:health().ignored >= 4)

print("[4] request routed with the sender stamped; response relayed")
sent = {}
EC.SBOS_MODULE_REQUEST(auth(AI_ID, "ai_core", ai.token, {
  request_id = "r1",
  idempotency_key = "k1",
  to = "flight_recorder",
  capability = "events.query",
  args = '{"limit":3}',
  deadline = tostring(os.time() + 10),
  from_module_id = "flight_recorder",
  from_instance_id = tostring(MODULE_ID),
}))
local fwd = lastSent("SBOS_MODULE_REQUEST")
check("ack Routed to the requester", lastSent("SBOS_MODULE_REQUEST_ACK").device == AI_ID and lastSent("SBOS_MODULE_REQUEST_ACK").params.state == "Routed")
check(
  "forwarded to the Flight Recorder's device with ITS token and the Agent-stamped sender",
  fwd and fwd.device == MODULE_ID and fwd.params.token == fr.token and fwd.params.from_module_id == "ai_core"
    and fwd.params.from_instance_id == tostring(AI_ID)
)
EC.SBOS_MODULE_RESPONSE(auth(MODULE_ID, "flight_recorder", fr.token, { request_id = "r1", status = "ok", result = '{"events":[]}' }))
local resp = lastSent("SBOS_MODULE_RESPONSE")
check(
  "response relayed to the requester's device",
  resp and resp.device == AI_ID and resp.params.status == "ok" and resp.params.token == ai.token
    and resp.params.from_module_id == "flight_recorder"
)

print("[5] fan-out of envelopes the Agent accepted")
sent = {}
EC.SBOS_MODULE_SUBSCRIBE(auth(AI_ID, "ai_core", ai.token, { subscription_id = "fr", topics = '["capture.","observation."]' }))
check("subscribed", lastSent("SBOS_MODULE_SUBSCRIBED").params.ok == "true")
local function frEnvelope(n, over)
  local e = {
    schema_version = 1,
    event_id = "flight_recorder:" .. MODULE_ID .. ":nb:v2-" .. n,
    event_type = "capture.device",
    module_id = "flight_recorder",
    source_driver_instance_id = tostring(MODULE_ID),
    observed_at = "2026-11-18T00:00:00Z",
    sequence = 9000 + n,
    severity = "info",
    evidence_source = "observed",
    quality = "confirmed",
    payload = { n = n },
  }
  for k, v in pairs(over or {}) do
    e[k] = v
  end
  return e
end
sent = {}
EC.SBOS_MODULE_EVENTS(auth(MODULE_ID, "flight_recorder", fr.token, {
  batch_id = "b1",
  events = JSON:encode({
    frEnvelope(1),
    frEnvelope(2, { event_type = "usage.minutes" }), -- not the recorder's prefix: rejected
    frEnvelope(3, { source_driver_instance_id = "9" }), -- instance mismatch: rejected
  }),
}))
EC.SBOS_MODULE_EVENTS(auth(MODULE_ID, "flight_recorder", fr.token, {
  batch_id = "b2",
  events = JSON:encode({ frEnvelope(1) }), -- resend after a lost ack: duplicate
}))
advance(1500)
local pubs = sentOf("SBOS_MODULE_PUBLISH", AI_ID)
local delivered = {}
for _, p in ipairs(pubs) do
  for _, e in ipairs(JSON:decode(p.params.events)) do
    delivered[#delivered + 1] = e.payload.n
  end
end
check(
  "only the accepted, non-duplicate envelope is published",
  #delivered == 1 and delivered[1] == 1,
  table.concat(delivered, ",")
)
check("published with the subscriber's token", pubs[1] and pubs[1].params.token == ai.token)
check("the envelope carries the Agent-stamped installation id", pubs[1] and JSON:decode(pubs[1].params.events)[1].installation_id == store["system_id"])

print("[6] cloud relay through send()")
requests = {}
responders["modules/rpc"] = function()
  return { ok = true, code = 202, body = { ok = true, result = { accepted = true, job_id = "job-1" } } }
end
sent = {}
EC.SBOS_MODULE_CLOUD_REQUEST(auth(AI_ID, "ai_core", ai.token, {
  request_id = "c1",
  idempotency_key = "ck1",
  op = "ask",
  body = '{"question":"is the den light on"}',
  deadline = tostring(os.time() + 20),
}))
local post = requestsTo("modules/rpc")[1]
check(
  "POST /api/integrations/control4/modules/rpc with the pairing token",
  post ~= nil and post.url == "https://app.smartbuildos.io/api/integrations/control4/modules/rpc"
    and post.headers.Authorization == "Bearer " .. store["device_token"]
)
check(
  "body {module_id, instance_id, op, request_id, idempotency_key, body} (+ send()'s identity)",
  post and post.data.module_id == "ai_core" and post.data.instance_id == tostring(AI_ID) and post.data.op == "ask"
    and post.data.request_id == "c1" and post.data.idempotency_key == "ck1"
    and post.data.body.question == "is the den light on" and post.data.system ~= nil
)
local cr = lastSent("SBOS_MODULE_CLOUD_RESPONSE")
check(
  "CLOUD_RESPONSE ok with the HTTP status and result",
  cr and cr.device == AI_ID and cr.params.status == "ok" and cr.params.http_status == "202"
    and JSON:decode(cr.params.result).job_id == "job-1"
)
responders["modules/rpc"] = function()
  return { ok = false, code = 0, error = "Could not resolve host" }
end
EC.SBOS_MODULE_CLOUD_REQUEST(auth(AI_ID, "ai_core", ai.token, {
  request_id = "c2",
  op = "status",
  body = "{}",
  deadline = tostring(os.time() + 20),
}))
check("transport failure → cloud_unreachable", lastSent("SBOS_MODULE_CLOUD_RESPONSE").params.error_code == "cloud_unreachable")
responders["modules/rpc"] = function()
  return { ok = false, code = 403, body = "forbidden" }
end
EC.SBOS_MODULE_CLOUD_REQUEST(auth(AI_ID, "ai_core", ai.token, {
  request_id = "c3",
  op = "status",
  body = "{}",
  deadline = tostring(os.time() + 20),
}))
check(
  "HTTP 403 → cloud_refused with the status",
  lastSent("SBOS_MODULE_CLOUD_RESPONSE").params.error_code == "cloud_refused"
    and lastSent("SBOS_MODULE_CLOUD_RESPONSE").params.http_status == "403"
)
local before = #requestsTo("modules/rpc")
EC.SBOS_MODULE_CLOUD_REQUEST(auth(AI_ID, "ai_core", ai.token, {
  request_id = "c4",
  op = "proxy",
  body = '{"url":"http://x"}',
  deadline = tostring(os.time() + 20),
}))
check(
  "an op outside MODULE_CLOUD_OPS.ai_core is refused locally",
  lastSent("SBOS_MODULE_CLOUD_RESPONSE").params.error_code == "not_permitted" and #requestsTo("modules/rpc") == before
)
responders["modules/rpc"] = nil

print("[7] heartbeat: bus totals and per-module counters, no tokens")
requests = {}
EC.SEND_HEARTBEAT()
do
  local hb = requestsTo("heartbeat")[1].data
  local aiRow
  for _, m in ipairs(hb.modules) do
    if m.module_id == "ai_core" then
      aiRow = m
    end
  end
  check(
    "module_bus counts requests, published, cloud calls",
    hb.module_bus.requests >= 1 and hb.module_bus.published == 1 and hb.module_bus.cloud_requests == 4
      and hb.module_bus.timeouts == 0 and hb.module_bus.dropped == 0
  )
  check("per-module bus counters on the module row", aiRow and aiRow.bus and aiRow.bus.requests == 1 and aiRow.bus.published == 1)
  check("manifest on the module row", aiRow and aiRow.manifest and aiRow.manifest.driver == "sbos.ai_core")
  check("no token anywhere in the heartbeat", JSON:encode(hb):find(ai.token, 1, true) == nil and JSON:encode(hb):find(fr.token, 1, true) == nil)
end

print("[8] MODULE_COMMANDS.ai_core through the existing gateway")
do
  responders["heartbeat"] = function()
    return {
      ok = true,
      body = {
        ok = true,
        commands = {
          { id = "a1", command = "MODULE_COMMAND", payload = { module_id = "ai_core", command = "deliver_result", request_id = "ai-1", args = { job_id = "job-1" } } },
          { id = "a2", command = "MODULE_COMMAND", payload = { module_id = "ai_core", command = "unlock_door", request_id = "ai-2" } },
        },
      },
    }
  end
  -- ai_core must register the commands it accepts (instance check)
  ai = register(AI_ID, "ai_core", {
    manifest = '{"driver":"sbos.ai_core","capabilities":[]}',
    commands = "apply_config,refresh_status,deliver_result,raise_event,set_learning,run_diagnostic",
  })
  requests = {}
  sent = {}
  EC.SEND_HEARTBEAT()
  responders["heartbeat"] = nil
  local acks = requestsTo("commands")
  acks = acks[#acks] and acks[#acks].data.acks or {}
  check("deliver_result accepted and forwarded to ai_core", acks[1] and acks[1].ok == true and lastSent("SBOS_MODULE_COMMAND").device == AI_ID)
  check("an operation outside MODULE_COMMANDS.ai_core is refused", acks[2] and acks[2].ok == false and acks[2].error:find("unlock_door") ~= nil)
  local vocab = MODULE_COMMANDS.ai_core
  check(
    "MODULE_COMMANDS.ai_core is exactly the six restricted operations",
    vocab.apply_config and vocab.refresh_status and vocab.deliver_result and vocab.raise_event and vocab.set_learning
      and vocab.run_diagnostic and (function()
        local n = 0
        for _ in pairs(vocab) do
          n = n + 1
        end
        return n == 6
      end)()
  )
end

print("[9] Agent restart: hello → re-register (new token) → re-subscribe")
do
  local oldToken = ai.token
  OnDriverDestroyed()
  gModules, gEvents, gBus = nil, nil, nil
  sent = {}
  OnDriverLateInit("DIT_STARTUP")
  check(
    "hello to every registered instance",
    #sentOf("SBOS_MODULE_AGENT_HELLO", AI_ID) == 1 and #sentOf("SBOS_MODULE_AGENT_HELLO", MODULE_ID) == 1
  )
  check("subscriptions died with the Agent", gBus:health().subscriptions == 0)
  ai = register(AI_ID, "ai_core", { manifest = '{"driver":"sbos.ai_core","capabilities":[]}' })
  fr = register(MODULE_ID, "flight_recorder", { manifest = FR_MANIFEST })
  check("re-registration issues a new token", ai.token ~= oldToken)
  sent = {}
  EC.SBOS_MODULE_SUBSCRIBE(auth(AI_ID, "ai_core", oldToken, { subscription_id = "fr", topics = '["capture."]' }))
  check("the pre-restart token no longer authenticates", #sent == 0)
  EC.SBOS_MODULE_SUBSCRIBE(auth(AI_ID, "ai_core", ai.token, { subscription_id = "fr", topics = '["capture."]' }))
  sent = {}
  EC.SBOS_MODULE_EVENTS(auth(MODULE_ID, "flight_recorder", fr.token, { batch_id = "b9", events = JSON:encode({ frEnvelope(50) }) }))
  advance(1500)
  check("fan-out works again after re-subscribe", #sentOf("SBOS_MODULE_PUBLISH", AI_ID) == 1)
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
