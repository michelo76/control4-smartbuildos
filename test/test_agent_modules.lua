-- The AGENT's shared module services under the shim, with a scripted module:
-- registration + token, hello on start, authenticated frames, event
-- validation/dedup/stamping into the durable queue, upload with structured
-- acks (partial rejection, transport failure, backoff, drain), MODULE_COMMAND
-- through the existing command gateway (vocabulary, duplicate request id,
-- expiry, target), command state events, snapshot upload acks, journal
-- checkpoint on destroy and restore, unpair → modules told.
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

local seq = 0
local function envelope(over)
  seq = seq + 1
  local e = {
    schema_version = 1,
    event_id = "flight_recorder:" .. MODULE_ID .. ":nb:" .. seq,
    event_type = "observation.change",
    module_id = "flight_recorder",
    source_driver_instance_id = tostring(MODULE_ID),
    observed_at = "2026-10-22T00:00:00Z",
    sequence = seq,
    severity = "info",
    evidence_source = "observed",
    quality = "confirmed",
    payload = { value = seq },
  }
  for k, v in pairs(over or {}) do
    e[k] = v
  end
  return e
end
local function registerModule(over)
  local p = {
    module_id = "flight_recorder",
    instance_id = tostring(MODULE_ID),
    requester = tostring(MODULE_ID),
    driver_version = "1",
    protocol_min = "1",
    protocol_max = "1",
    capabilities = "recording,traces",
    entitlements = "SBOS_FLIGHT_RECORDER",
    commands = "apply_config,pause,resume,capture_snapshot,refresh_status",
    event_types = "observation.,trace.",
    singleton = "true",
  }
  for k, v in pairs(over or {}) do
    p[k] = v
  end
  EC.SBOS_MODULE_REGISTER(p)
  local reply = lastSent("SBOS_MODULE_REGISTERED")
  return reply and reply.params or {}
end

print("[1] the Agent comes up paired; module services initialise; nothing registered yet")
OnDriverInit()
OnDriverLateInit("DIT_STARTUP")
check("online", Properties["Driver Status"] == "Online", Properties["Driver Status"])
check(
  "event pipeline on the heartbeat",
  (function()
    local hb = requestsTo("heartbeat")[1]
    return hb ~= nil
      and type(hb.data.event_pipeline) == "table"
      and hb.data.event_pipeline.depth == 0
      and hb.data.modules == nil
      and hb.data.module_protocol.max == 1
  end)()
)
check(
  "capabilities advertise modules_v1 + flight_recorder_v1",
  (function()
    local caps = requestsTo("heartbeat")[1].data.capabilities
    local a, b = false, false
    for _, c in ipairs(caps) do
      if c == "modules_v1" then
        a = true
      end
      if c == "flight_recorder_v1" then
        b = true
      end
    end
    return a and b
  end)()
)
check("no hello (nothing registered)", #sentOf("SBOS_MODULE_AGENT_HELLO") == 0)

print("[2] registration: token to the claimed id, agent state in the reply, config resend")
store["sbos_driver_config_fwd_sbos_flight_recorder"] = '3|{"version":3,"sources":[]}'
local reply = registerModule()
check("ok + token + protocol", reply.ok == "true" and #reply.token == 32 and reply.protocol == "1", reply.reason)
check("reply went to the claimed device", lastSent("SBOS_MODULE_REGISTERED").device == MODULE_ID)
check(
  "agent state in the reply",
  reply.paired == "true" and reply.installation_id == store["system_id"] and reply.boot_id == "boot-7"
)
check(
  "last forwarded config re-sent to the new module",
  (function()
    local c = lastSent("SBOS_DRIVER_CONFIG")
    return c ~= nil and c.device == MODULE_ID and c.params.settings_version == "3"
  end)()
)
check(
  "registry persisted without exposing tokens on the heartbeat",
  (function()
    sent = {}
    EC.SEND_HEARTBEAT()
    local hb = requestsTo("heartbeat")
    local m = hb[#hb].data.modules
    return store["sbos_modules_v1"] ~= nil
      and m ~= nil
      and #m == 1
      and m[1].module_id == "flight_recorder"
      and m[1].token == nil
      and m[1].display_status == "ready"
  end)()
)
local TOKEN = reply.token
check(
  "second instance refused as duplicate",
  registerModule({ instance_id = "502", requester = "502" }).reason == "duplicate_instance"
)
check(
  "incompatible protocol refused with the Agent's range",
  (function()
    local r = registerModule({
      instance_id = "503",
      requester = "503",
      protocol_min = "4",
      protocol_max = "5",
      singleton = "false",
    })
    return r.ok == "false" and r.reason == "incompatible_protocol" and r.agent_protocol_max == "1"
  end)()
)

print("[3] authenticated frames only")
sent = {}
EC.SBOS_MODULE_EVENTS({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = "nope",
  batch_id = "b0",
  events = JSON:encode({ envelope() }),
})
check("bad token: no ack, nothing queued", #sentOf("SBOS_MODULE_EVENTS_ACK") == 0 and gEvents:depth() == 0)
EC.SBOS_MODULE_STATUS({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = "nope",
  status = "hacked",
})
check("bad token: status ignored", gModules:list()[1].status ~= "hacked")
EC.SBOS_MODULE_STATUS({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = TOKEN,
  status = "recording",
  applied_config_version = "3",
  counters = JSON:encode({ listeners = 2 }),
})
check(
  "good token: status recorded",
  gModules:list()[1].status == "recording"
    and gModules:list()[1].applied_config_version == "3"
    and gModules:list()[1].counters.listeners == 2
)

print("[4] events: validated, owned, deduplicated, stamped, acknowledged")
sent = {}
local good1, good2 = envelope(), envelope()
local foreign = envelope({ event_type = "health.cpu" })
local wrongInstance = envelope({ source_driver_instance_id = "777" })
local malformed = { nope = true }
EC.SBOS_MODULE_EVENTS({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = TOKEN,
  batch_id = "b1",
  events = JSON:encode({ good1, good2, foreign, wrongInstance, malformed }),
})
local ack = lastSent("SBOS_MODULE_EVENTS_ACK")
check(
  "ack counts",
  ack.params.batch_id == "b1" and ack.params.accepted == "2" and ack.params.rejected == "3",
  ack.params.accepted .. "/" .. ack.params.rejected .. " " .. tostring(ack.params.reason)
)
check(
  "queue holds two, stamped with installation + boot",
  gEvents:depth() == 2
    and gEvents.items[1].env.installation_id == store["system_id"]
    and gEvents.items[1].env.boot_id == "boot-7"
)
check("ack carries queue brief", JSON:decode(ack.params.queue).depth == 2)
EC.SBOS_MODULE_EVENTS({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = TOKEN,
  batch_id = "b1",
  events = JSON:encode({ good1, good2 }),
})
check(
  "resend after a lost ack: accepted as duplicates, not queued twice",
  lastSent("SBOS_MODULE_EVENTS_ACK").params.duplicates == "2" and gEvents:depth() == 2
)
check("fast flush armed", clock.timers["SmartBuildOSEventsFast"] ~= nil)

print("[5] upload: structured ack with partial rejection; transport failure backs off; drain")
requests = {}
responders["events"] = function(data)
  local accepted, rejected = {}, {}
  for i, e in ipairs(data.events) do
    if i == 1 then
      rejected[#rejected + 1] = { event_id = e.event_id, reason = "payload_too_large", permanent = true }
    else
      accepted[#accepted + 1] = e.event_id
    end
  end
  return { ok = true, body = { ok = true, accepted = accepted, rejected = rejected } }
end
-- The first delivery after start put the queue in its staggered-recovery
-- window (0..30 s); the regular 30 s tick picks it up after that.
advance(45000)
local up = requestsTo("events")[1]
check(
  "batch uploaded with the pipeline health",
  up ~= nil and #up.data.events == 2 and up.data.kind == "events" and type(up.data.pipeline) == "table"
)
check("authenticated like every send", up.headers["Authorization"] == "Bearer " .. store["device_token"])
check(
  "accepted removed, permanent rejection dropped + counted, queue empty",
  gEvents:depth() == 0
    and gEvents.stats.acked == 1
    and gEvents.stats.rejected_permanent == 1
    and gEvents.stats.dropped_ranges[1].reason == "rejected:payload_too_large"
)
responders["events"] = function()
  return { ok = false, code = 0, error = "unreachable" }
end
sent = {}
requests = {}
EC.SBOS_MODULE_EVENTS({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = TOKEN,
  batch_id = "b2",
  events = JSON:encode({ envelope(), envelope(), envelope() }),
})
advance(6000)
check(
  "failed upload: events back in the queue, backoff set, failure counted",
  gEvents:depth() == 3 and gEvents.backoffUntil > os.time() and gEvents.stats.upload_failures == 1
)
local tries = #requestsTo("events")
advance(5000)
check("no retry inside the backoff", #requestsTo("events") == tries)
responders["events"] = function(data)
  local accepted = {}
  for _, e in ipairs(data.events) do
    accepted[#accepted + 1] = e.event_id
  end
  return { ok = true, body = { accepted = accepted, rejected = {} } }
end
advance(120000)
check("drained after the backoff", gEvents:depth() == 0 and gEvents.failures == 0)
responders["events"] = function()
  return { ok = true, body = { ok = true } }
end
EC.SBOS_MODULE_EVENTS({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = TOKEN,
  batch_id = "b3",
  events = JSON:encode({ envelope() }),
})
advance(6000)
check("a 2xx without a verdict is NOT an acceptance", gEvents:depth() == 1 and gEvents.stats.last_error ~= nil)
responders["events"] = function(data)
  local accepted = {}
  for _, e in ipairs(data.events) do
    accepted[#accepted + 1] = e.event_id
  end
  return { ok = true, body = { accepted = accepted, rejected = {} } }
end
advance(120000)
check("then delivered", gEvents:depth() == 0)

print("[6] MODULE_COMMAND through the existing gateway")
sent = {}
requests = {}
local function heartbeatWith(commands)
  responders["heartbeat"] = function()
    return { ok = true, body = { ok = true, commands = commands } }
  end
  EC.SEND_HEARTBEAT()
  responders["heartbeat"] = nil
  local acks = requestsTo("commands")
  return acks[#acks] and acks[#acks].data.acks or {}
end
local acks = heartbeatWith({
  {
    id = "c1",
    command = "MODULE_COMMAND",
    payload = { module_id = "flight_recorder", command = "pause", request_id = "req-1", args = { reason = "tech" } },
  },
  {
    id = "c2",
    command = "MODULE_COMMAND",
    payload = { module_id = "flight_recorder", command = "pause", request_id = "req-1" },
  },
  {
    id = "c3",
    command = "MODULE_COMMAND",
    payload = { module_id = "flight_recorder", command = "run_lua", request_id = "req-2" },
  },
  {
    id = "c4",
    command = "MODULE_COMMAND",
    payload = { module_id = "guardian", command = "pause", request_id = "req-3" },
  },
  {
    id = "c5",
    command = "MODULE_COMMAND",
    payload = { module_id = "flight_recorder", command = "resume", request_id = "req-4", expires_at = os.time() - 10 },
  },
})
check("five acks", #acks == 5, #acks)
check(
  "c1 accepted and forwarded with the token",
  acks[1].ok == true
    and acks[1].result:find("accepted") ~= nil
    and lastSent("SBOS_MODULE_COMMAND") ~= nil
    and lastSent("SBOS_MODULE_COMMAND").params.token == TOKEN
    and lastSent("SBOS_MODULE_COMMAND").params.command == "pause"
    and JSON:decode(lastSent("SBOS_MODULE_COMMAND").params.args).reason == "tech"
)
check("c2 duplicate request id refused", acks[2].ok == false and acks[2].error:find("duplicate") ~= nil)
check("c3 unknown operation refused by name", acks[3].ok == false and acks[3].error:find("run_lua") ~= nil)
check("c4 unregistered module refused", acks[4].ok == false and acks[4].error:find("guardian") ~= nil)
check("c5 expired refused", acks[5].ok == false and acks[5].error:find("expired") ~= nil)
check("only one frame reached the module", #sentOf("SBOS_MODULE_COMMAND") == 1)
check(
  "command states ride the pipeline",
  (function()
    local states = {}
    for _, it in ipairs(gEvents.items) do
      if it.env.event_type == "agent.command_state" then
        states[#states + 1] = it.env.payload.request_id .. ":" .. it.env.payload.state
      end
    end
    return table.concat(states, ",") == "req-1:Accepted,req-4:Expired", table.concat(states, ",")
  end)()
)
EC.SBOS_MODULE_COMMAND_RESULT({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = "bad",
  request_id = "req-1",
  state = "Completed",
})
check("result with a bad token ignored", gModuleCommands["req-1"].state == "Accepted")
EC.SBOS_MODULE_COMMAND_RESULT({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = TOKEN,
  request_id = "req-1",
  state = "Executing",
  detail = "pausing",
})
EC.SBOS_MODULE_COMMAND_RESULT({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = TOKEN,
  request_id = "req-1",
  state = "Completed",
  detail = "paused",
})
EC.SBOS_MODULE_COMMAND_RESULT({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = TOKEN,
  request_id = "req-1",
  state = "Failed",
  detail = "late",
})
check("Executing → Completed, terminal stays terminal", gModuleCommands["req-1"].state == "Completed")
check("expiry timer cleared", clock.timers["ModuleCommandExpiry:req-1"] == nil)
local acks2 = heartbeatWith({
  {
    id = "c6",
    command = "MODULE_COMMAND",
    payload = {
      module_id = "flight_recorder",
      command = "refresh_status",
      request_id = "req-5",
      expires_at = os.time() + 60,
    },
  },
})
check("c6 accepted", acks2[1].ok == true)
advance(70000)
check("no result before expiry → Unverified", gModuleCommands["req-5"].state == "Unverified")

print("[7] snapshot upload: bounded, redacted, acknowledged either way")
sent = {}
requests = {}
responders["snapshots"] = function(data)
  return { ok = true, body = { ok = true, snapshot_id = "snap-row-1" } }
end
EC.SBOS_MODULE_SNAPSHOT({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = TOKEN,
  job_id = "job-1",
  request_id = "req-5",
  status = "completed",
  document = JSON:encode({ kind = "flight_recorder_snapshot", agent = { token = "SECRET" } }),
})
local snapReq = requestsTo("snapshots")[1]
check(
  "uploaded on its own path with the module identity",
  snapReq ~= nil and snapReq.data.module_id == "flight_recorder" and snapReq.data.job_id == "job-1"
)
check("re-redacted on the way out", snapReq.data.document.agent.token == "[redacted]")
check(
  "ack ok with the row id",
  lastSent("SBOS_MODULE_SNAPSHOT_ACK").params.ok == "true"
    and lastSent("SBOS_MODULE_SNAPSHOT_ACK").params.snapshot_id == "snap-row-1"
)
responders["snapshots"] = function()
  return { ok = false, code = 503, error = "down" }
end
EC.SBOS_MODULE_SNAPSHOT({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = TOKEN,
  job_id = "job-2",
  document = "{}",
})
check(
  "failure acked as not ok",
  lastSent("SBOS_MODULE_SNAPSHOT_ACK").params.ok == "false"
    and lastSent("SBOS_MODULE_SNAPSHOT_ACK").params.job_id == "job-2"
)
EC.SBOS_MODULE_SNAPSHOT({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = TOKEN,
  job_id = "job-3",
  document = string.rep("x", 300 * 1024),
})
check(
  "oversized refused without an upload",
  lastSent("SBOS_MODULE_SNAPSHOT_ACK").params.reason:find("256 KB") ~= nil and #requestsTo("snapshots") == 2
)

print("[8] DISCOVER_VARIABLES is bounded and partial")
requests = {}
local acks3 = heartbeatWith({
  { id = "c7", command = "DISCOVER_VARIABLES", payload = { device_ids = { 12, 63 } } },
  { id = "c8", command = "DISCOVER_VARIABLES", payload = { device_ids = {} } },
})
local cat = requestsTo("telemetry")[1]
check(
  "partial catalogue for the named devices",
  cat ~= nil
    and cat.data.kind == "catalogue"
    and cat.data.partial == true
    and #cat.data.observables == 2
    and cat.data.observables[1].kind == "device"
)
check("empty list refused", acks3[2].ok == false)

print("[9] agent events reach live modules; journal checkpoints on destroy and restores")
sent = {}
ProjectChangeFlush()
gProjectChanges.pending["OnItemAdded"] = true
ProjectChangeFlush()
check(
  "project_changed offered to the module",
  lastSent("SBOS_MODULE_AGENT_EVENT") ~= nil and lastSent("SBOS_MODULE_AGENT_EVENT").params.name == "project_changed"
)
EC.SBOS_MODULE_EVENTS({
  module_id = "flight_recorder",
  instance_id = tostring(MODULE_ID),
  token = TOKEN,
  batch_id = "b9",
  events = JSON:encode({ envelope(), envelope() }),
})
responders["events"] = function()
  return { ok = false, code = 0, error = "unreachable" }
end
OnDriverDestroyed()
check(
  "journal written with the queued events",
  type(store["sbos_event_journal_v1"]) == "table" and #store["sbos_event_journal_v1"].items == 2
)
local saved = store["sbos_event_journal_v1"]
gModules = nil
gEvents = nil
ModulesInit()
check("restored on the next start with the same depth", gEvents:depth() == 2 and gModules:count() == 1)
store["sbos_event_journal_v1"] = { v = 1, items = { "garbage" } }
gModules = nil
gEvents = nil
ModulesInit()
check("corrupt journal → empty + flagged", gEvents:depth() == 0 and gEvents.stats.journal_recovered == true)
store["sbos_event_journal_v1"] = saved

print("[10] hello on start; unpair tells the modules")
sent = {}
gModules = nil
gEvents = nil
OnDriverLateInit("DIT_STARTUP")
check("hello sent to the registered module", #sentOf("SBOS_MODULE_AGENT_HELLO", MODULE_ID) >= 1)
sent = {}
EC.UNPAIR()
check(
  "agent state broadcast says unpaired",
  (function()
    local s = lastSent("SBOS_MODULE_AGENT_STATE")
    return s ~= nil and s.params.paired == "false"
  end)()
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
