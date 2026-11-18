-- Shared harness for the AI Core DRIVER tests (not a test file itself: no
-- test_ prefix). A fake Director + a scripted SmartBuildOS Agent that speaks
-- module contract v1/v2 frames back to the driver through its real
-- sbos.moduleclient / sbos.modulerpc. Everything here is simulation.
--
--   local H = require("aicore_harness")
--   H.load()                       -- dofile the driver (again = a restart)
--   H.pump()                       -- the scripted Agent answers every frame
--   H.advance(ms)                  -- fake time, timers fire, then pump()

local H = {}

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")

-- ── timers / clock ──────────────────────────────────────────────────────────
local clock = { now = 0, timers = {} }
H.clock = clock
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
local realTime = os.time
H.BASE = 1800000000
os.time = function(t)
  if t then
    return realTime(t)
  end
  return H.BASE + math.floor(clock.now / 1000)
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

-- ── persist (survives H.load(), i.e. a restart) ─────────────────────────────
H.persisted = {}
package.preload["lib.persist"] = function()
  local P = {}
  local EMPTY = {}
  function P:get(key, default)
    if default == nil then
      default = EMPTY
    end
    if H.persisted[key] == nil then
      return default
    end
    return H.persisted[key]
  end
  function P:set(key, value)
    -- a deep copy through JSON, as Director persists values, not references
    H.persisted[key] = value == nil and nil or JSON:decode(JSON:encode(value))
  end
  function P:delete(key)
    H.persisted[key] = nil
  end
  function P:reset() end
  return P
end
-- The vendored global PersistSetValue/GetValue (licence trial marker).
local pv = {}
function C4:PersistSetValue(k, v)
  pv[k] = v
end
function C4:PersistGetValue(k)
  return pv[k]
end
function C4:PersistDeleteValue(k)
  pv[k] = nil
end

-- ── fake Director ───────────────────────────────────────────────────────────
H.AGENT_ID = 50
H.SELF_ID = 12345
H.agentPresent = false
H.sent = {}
H.fired = {}
H.vars = {}
H.props = {}
H.sysRegs = {}
H.sysUnregs = 0
H.listeners = {}
H.equipment = {} -- any call that could act on a device lands here
H.devices = {
  [12] = { deviceName = "Kitchen Pendants", driverFileName = "light_v2.c4i", roomId = 3, roomName = "Kitchen" },
  [20] = { deviceName = "Garage Door", driverFileName = "contact.c4i", roomId = 7, roomName = "Garage" },
  [30] = { deviceName = "Front Lock", driverFileName = "lock.c4i", roomId = 1, roomName = "Entry" },
  [40] = { deviceName = "Spare Room Lamp", driverFileName = "light_v2.c4i", roomId = 9, roomName = "Spare Room" },
}
H.deviceVariables = {
  [12] = { ["1000"] = { name = "LIGHT_STATE", value = "1" }, ["1001"] = { name = "BRIGHTNESS_PERCENT", value = "75" } },
  [30] = { ["1000"] = { name = "LockStatus", value = "locked" }, ["1099"] = { name = "USER_CODE", value = "1234" } },
}
C4.GetDevices = function()
  local d = {}
  for k, v in pairs(H.devices) do
    d[k] = v
  end
  if H.agentPresent then
    d[H.AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" }
  end
  return d
end
C4.GetDevicesByC4iName = function()
  return nil
end
C4.GetProjectItems = function()
  return ""
end
C4.GetDeviceID = function()
  return H.SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "AI Core"
  end
  return "20261118.000000"
end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end
local uuidN = 0
C4.UUID = function()
  uuidN = uuidN + 1
  return string.format("%08x-0000-4000-8000-%012x", uuidN, uuidN)
end
C4.SendToDevice = function(_, device, command, params)
  H.sent[#H.sent + 1] = { device = device, command = command, params = params }
end
C4.FireEventByID = function(_, id)
  H.fired[#H.fired + 1] = id
end
C4.FireEvent = function() end
C4.SetVariable = function(_, name, value)
  H.vars[name] = value
end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.UpdateProperty = function(_, name, value)
  H.props[name] = value
  Properties[name] = value
end
C4.RegisterSystemEvent = function(_, id, dev)
  H.sysRegs[id] = dev
end
C4.UnregisterSystemEvent = function(_, id)
  H.sysRegs[id] = nil
  H.sysUnregs = H.sysUnregs + 1
end
C4.GetDeviceVariables = function(_, id)
  return H.deviceVariables[tonumber(id)]
end
C4.RegisterVariableListener = function(_, d, v)
  H.listeners[d .. ":" .. v] = true
end
C4.UnregisterVariableListener = function(_, d, v)
  H.listeners[d .. ":" .. v] = nil
end
-- Equipment-acting APIs: none must ever be called by AI Core.
for _, name in ipairs({ "SetDeviceVariable", "SendToProxy", "SendUIRequest", "RegisterDeviceEvent", "Bind" }) do
  C4[name] = function(_, ...)
    H.equipment[#H.equipment + 1] = { api = name, args = { ... } }
  end
end

-- ── loading ─────────────────────────────────────────────────────────────────
local function xmlProperties()
  local f = assert(io.open("drivers/smartbuildos-ai-core/driver.xml"))
  local xml = f:read("*a")
  f:close()
  local props = {}
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    props[name] = block:match("<default>(.-)</default>") or ""
  end
  return props, xml
end

--- Loads (or reloads = controller restart) the driver: fresh module state,
--- same persisted values. Runs OnDriverInit + OnDriverLateInit.
function H.load(reason)
  if OnDriverDestroyed ~= nil and H.loaded then
    OnDriverDestroyed()
  end
  for name in pairs(package.loaded) do
    if name:find("^sbos%.") or name:find("^aicore%.") then
      package.loaded[name] = nil
    end
  end
  clock.timers = {}
  Properties = xmlProperties()
  H.props = {}
  dofile("drivers/smartbuildos-ai-core/driver.lua")
  H.loaded = true
  OnDriverInit()
  OnDriverLateInit(reason or "DIT_ADDING")
end

function H.prop(name)
  return H.props[name] or Properties[name]
end

-- ── the scripted Agent ──────────────────────────────────────────────────────
H.agent = {
  auto = true, -- answer frames
  reachable = true, -- false: frames are lost both ways
  protocol = 2, -- 1 = a v1-only Agent
  paired = true,
  connected = true,
  token = "tok-1",
  fr = { present = true, protocol = 2, instance_id = "9001", stale = false },
  cloud = nil, -- function(op, body, params) → { status, http_status, error_code, result | raw_result }
  frAnswer = nil, -- function(capability, args) → status, result, code
  processed = 0,
  cloudCalls = {},
  frRequests = {},
  subscriptions = {},
  registrations = 0,
  directoryVersion = 1,
}

local function auth(extra)
  local p = { module_id = "ai_core", instance_id = tostring(H.SELF_ID), token = H.agent.token }
  for k, v in pairs(extra or {}) do
    p[k] = v
  end
  return p
end
H.auth = auth

function H.register(protocol, extra)
  local a = H.agent
  a.registrations = a.registrations + 1
  a.token = "tok-" .. a.registrations
  local reply = {
    module_id = "ai_core",
    instance_id = tostring(H.SELF_ID),
    ok = "true",
    token = a.token,
    protocol = tostring(protocol or a.protocol),
    paired = a.paired and "true" or "false",
    connected = a.connected and "true" or "false",
    installation_id = "sys-1",
    boot_id = "boot-1",
    agent_version = "20261118.1",
  }
  if (protocol or a.protocol) >= 2 then
    reply.agent_protocol_min = "1"
    reply.agent_protocol_max = "2"
  end
  for k, v in pairs(extra or {}) do
    reply[k] = v
  end
  EC.SBOS_MODULE_REGISTERED(reply)
end

local function directory(filter)
  local mods = {
    {
      module_id = "ai_core",
      instance_id = tostring(H.SELF_ID),
      driver = "sbos.ai_core",
      protocol = 2,
      status = "ready",
      stale = false,
      capabilities = {},
    },
  }
  local fr = H.agent.fr
  if fr.present then
    mods[#mods + 1] = {
      module_id = "flight_recorder",
      instance_id = fr.instance_id,
      driver = "sbos.flight_recorder",
      protocol = fr.protocol,
      status = "ready",
      stale = fr.stale,
      capabilities = fr.protocol >= 2
          and {
            { id = "events.query", version = 1, kind = "request" },
            { id = "events.timeline", version = 1, kind = "request" },
            { id = "events.device_history", version = 1, kind = "request" },
            { id = "events.room_activity", version = 1, kind = "request" },
            { id = "events.subscribe", version = 1, kind = "topic", topics = { "capture.", "observation.", "trace." } },
          }
        or {},
    }
  end
  local out = {}
  for _, m in ipairs(mods) do
    if filter == nil or filter.module_id == nil or filter.module_id == m.module_id then
      out[#out + 1] = m
    end
  end
  return out
end

local function answer(frame)
  local a = H.agent
  local p = frame.params
  local c = frame.command
  if c == "SBOS_MODULE_REGISTER" then
    if a.protocol < 2 then
      H.register(1)
    else
      H.register(2)
    end
  elseif c == "SBOS_MODULE_DISCOVER" then
    if a.protocol < 2 then
      return
    end
    local filter = (p.filter ~= nil and p.filter ~= "") and JSON:decode(p.filter) or nil
    EC.SBOS_MODULE_DIRECTORY(auth({
      request_id = p.request_id,
      error_code = "ok",
      directory_version = tostring(a.directoryVersion),
      agent = JSON:encode({
        version = "20261118.1",
        protocol_min = 1,
        protocol_max = 2,
        paired = a.paired,
        connected = a.connected,
      }),
      modules = JSON:encode(directory(filter)),
      truncated = "false",
    }))
  elseif c == "SBOS_MODULE_SUBSCRIBE" then
    a.subscriptions[p.subscription_id] = JSON:decode(p.topics)
    EC.SBOS_MODULE_SUBSCRIBED(auth({
      subscription_id = p.subscription_id,
      ok = "true",
      reason = "ok",
      granted = p.topics,
      refused = "[]",
    }))
  elseif c == "SBOS_MODULE_UNSUBSCRIBE" then
    a.subscriptions[p.subscription_id] = nil
  elseif c == "SBOS_MODULE_CLOUD_REQUEST" then
    local body = JSON:decode(p.body)
    a.cloudCalls[#a.cloudCalls + 1] =
      { op = p.op, body = body, idempotency_key = p.idempotency_key, request_id = p.request_id }
    local r = a.cloud and a.cloud(p.op, body, p)
      or {
        status = "ok",
        http_status = "200",
        error_code = "ok",
        result = { accepted = true, job_id = "job-" .. #a.cloudCalls },
      }
    if r == false then
      return -- no answer at all
    end
    EC.SBOS_MODULE_CLOUD_RESPONSE(auth({
      request_id = p.request_id,
      status = r.status,
      http_status = r.http_status or "",
      error_code = r.error_code or (r.status == "ok" and "ok" or "internal_error"),
      -- raw_result: the JSON text as the platform wrote it (e.g. a literal null)
      result = r.raw_result or JSON:encode(r.result or {}),
    }))
  elseif c == "SBOS_MODULE_REQUEST" then
    local args = JSON:decode(p.args)
    a.frRequests[#a.frRequests + 1] = { to = p.to, capability = p.capability, args = args }
    EC.SBOS_MODULE_REQUEST_ACK(auth({ request_id = p.request_id, state = "Routed", error_code = "ok" }))
    local status, result, code = "ok", { events = {}, count = 0 }, "ok"
    if a.frAnswer then
      status, result, code = a.frAnswer(p.capability, args)
    end
    EC.SBOS_MODULE_RESPONSE(auth({
      request_id = p.request_id,
      status = status,
      error_code = code or "ok",
      result = JSON:encode(result or {}),
      cursor = "",
      from_module_id = "flight_recorder",
      from_instance_id = a.fr.instance_id,
    }))
  elseif c == "SBOS_MODULE_EVENTS" then
    local events = JSON:decode(p.events)
    EC.SBOS_MODULE_EVENTS_ACK({ batch_id = p.batch_id, accepted = tostring(#events) })
  end
end

--- The Agent answers every frame not yet seen (until nothing new arrives).
function H.pump()
  local a = H.agent
  local guard = 0
  while a.processed < #H.sent and guard < 10000 do
    guard = guard + 1
    a.processed = a.processed + 1
    local frame = H.sent[a.processed]
    if a.auto and a.reachable and frame.device == H.AGENT_ID then
      answer(frame)
    end
  end
end

function H.advance(ms)
  local target = clock.now + ms
  while true do
    H.pump()
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
  H.pump()
end

-- ── inspection ──────────────────────────────────────────────────────────────
function H.sentOf(command)
  local out = {}
  for _, s in ipairs(H.sent) do
    if s.command == command then
      out[#out + 1] = s
    end
  end
  return out
end

function H.lastSent(command)
  local l = H.sentOf(command)
  return l[#l]
end

--- Every envelope the driver handed the Agent, in order.
function H.envelopes(eventType)
  local out = {}
  for _, s in ipairs(H.sent) do
    if s.command == "SBOS_MODULE_EVENTS" then
      for _, e in ipairs(JSON:decode(s.params.events)) do
        if eventType == nil or e.event_type == eventType then
          out[#out + 1] = e
        end
      end
    end
  end
  return out
end

function H.fired_(id)
  for _, f in ipairs(H.fired) do
    if f == id then
      return true
    end
  end
  return false
end

function H.firedCount(id)
  local n = 0
  for _, f in ipairs(H.fired) do
    if f == id then
      n = n + 1
    end
  end
  return n
end

--- A restricted operation from the platform, through the Agent.
local opSeq = 0
function H.operation(command, args, token)
  opSeq = opSeq + 1
  local id = "op-" .. opSeq
  EC.SBOS_MODULE_COMMAND({
    module_id = "ai_core",
    instance_id = tostring(H.SELF_ID),
    token = token or H.agent.token,
    request_id = id,
    command = command,
    args = JSON:encode(args or {}),
    issued_at = tostring(os.time()),
    expires_at = tostring(os.time() + 600),
  })
  H.pump()
  local states = {}
  for _, s in ipairs(H.sentOf("SBOS_MODULE_COMMAND_RESULT")) do
    if s.params.request_id == id then
      states[#states + 1] = { state = s.params.state, detail = s.params.detail }
    end
  end
  return states, id
end

function H.finalState(states)
  local last = states[#states]
  return last and last.state, last and last.detail
end

function H.publish(events, dropped, token)
  EC.SBOS_MODULE_PUBLISH(auth({
    subscription_id = "fr",
    events = JSON:encode(events),
    dropped = tostring(dropped or 0),
    token = token or H.agent.token,
  }))
end

function H.config(settings, version)
  EC.SBOS_DRIVER_CONFIG({
    sku = "SBOS_AI_CORE",
    settings = JSON:encode(settings),
    settings_version = tostring(version),
    requester = tostring(H.AGENT_ID),
  })
  H.pump()
  return H.lastSent("SBOS_DRIVER_CONFIG_ACK")
end

function H.entitlement(fields)
  local p = { sku = "SBOS_AI_CORE", registered = "true", checked_at = "now" }
  for k, v in pairs(fields) do
    p[k] = v
  end
  EC.SBOS_ENTITLEMENT(p)
  H.pump()
end

return H
