-- The REAL Agent and a module built on the REAL shared client
-- (sbos.moduleclient + sbos.license) in one Lua state, exchanging frames
-- through test/director_delivery.lua under BOTH delivery orders:
--
--   async  the module's handler runs after the Agent's has returned
--   sync   the module's handler runs inside the Agent's C4:SendToDevice
--
-- [1] boot + registration (async)
-- [2] MODULE_COMMAND results are recorded under either order: the ledger
--     record exists before the frame leaves, so an early Completed is not
--     dropped and the command never expires as Unverified
-- [3] a send that fails ends the record as Failed, with no expiry timer
-- [4] a cleared status detail (and config_error) reaches the Agent and the
--     heartbeat; Director drops "" params without allowEmptyValues
-- [5] REQUEST_ENTITLEMENTS: the cloud asks for a licence re-check; the
--     module's licence moves NOT_ENTITLED -> licensed without a restart;
--     capability advertised. At most one cloud-requested refresh a minute,
--     and a request that cannot run now is owed, never dropped: [5a] two
--     changes 30 s apart, [5b] five requests, [5c] in flight (success and
--     failure), [5d] the dealer action, [5e] a restart
-- [6] unpaired: like REQUEST_HEARTBEAT, the command never arrives
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
local D = require("director_delivery")

-- ── timers (each fires as the driver that set it) ──────────────────────────
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = D.wrapTimer(cb), every = repeating and ms or nil }
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
    D.drain()
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

-- ── persist (one store; the drivers' keys do not collide) ──────────────────
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
local responders = {}
local deferPaths = {} -- path -> true: the request stays in flight
local deferred = {}
--- Ends every deferred request: ok = true answers with the responder,
--- false fails it as an unreachable cloud does.
local function settleDeferred(ok)
  local list = deferred
  deferred = {}
  for _, d in ipairs(list) do
    if ok then
      local answer = responders[d.path](d.data)
      if d.onOk then
        d.onOk({ url = d.url, code = 200, headers = {}, body = JSON:encode(answer.body or {}) })
      end
    elseif d.onErr then
      d.onErr({ url = d.url, code = 0, headers = {}, body = "", error = "unreachable" })
    end
  end
  return #list
end
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
    post = function(_, url, data, headers)
      requests[#requests + 1] = { url = url, data = data, headers = headers, at = clock.now }
      local path = url:match("/api/integrations/control4/(.*)$") or url:match("/api/driver%-cloud/(.*)$") or url
      local r = responders[path]
      if deferPaths[path] then
        -- In flight until the test calls settleDeferred(): the answer is
        -- built THEN, from what is issued at that moment.
        return {
          next = function(_, onOk, onErr)
            deferred[#deferred + 1] = { path = path, url = url, data = data, onOk = onOk, onErr = onErr }
          end,
        }
      end
      local answer = r and r(data) or { ok = true, code = 200, body = { ok = true } }
      return settled(
        true,
        { url = url, code = answer.code or 200, headers = {}, body = JSON:encode(answer.body or {}) }
      )
    end,
  }
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

-- ── Director: the Agent (99) and an AI Core module (701) ───────────────────
local AGENT, MODULE = 99, 701
local PROJECT = {
  [AGENT] = { deviceName = "SmartBuildOS Agent", roomName = "Rack", driverFileName = "smartbuildos.c4z" },
  [MODULE] = { deviceName = "SmartBuildOS AI Core", roomName = "Rack", driverFileName = "smartbuildos-ai-core.c4z" },
}
setmetatable(C4, {
  __index = function()
    return function()
      return nil
    end
  end,
})
function C4:GetDevices()
  return PROJECT
end
function C4:GetDevicesByC4iName(name)
  local out = {}
  for id, d in pairs(PROJECT) do
    if d.driverFileName == name then
      out[id] = d.deviceName
    end
  end
  return out
end
function C4:GetDeviceVariables()
  return {}
end
function C4:GetBindingsByDevice()
  return { bindings = {} }
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
  return { version = "4.3.0.0" }
end
function C4:GetDriverConfigInfo(key)
  if key == "minimum_os_version" then
    return "3.3.1"
  end
  return "20261120.100000"
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
function C4:UpdateProperty(name, value)
  Properties[name] = value
end
function C4:AllowExecute() end
function C4:HMAC()
  return "00"
end
D.install(C4)

local agentProps = {}
do
  local f = assert(io.open("drivers/smartbuildos/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    agentProps[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
  end
end
agentProps["API URL"] = "https://app.smartbuildos.io"
agentProps["Heartbeat Interval"] = "1m"
agentProps["Log Level"] = "1 - Error"
local agent = D.add(AGENT, { Properties = agentProps })
local module = D.add(MODULE, {
  Properties = {
    ["License Status"] = "",
    ["License Source"] = "",
    ["Subscription Tier"] = "",
    ["SmartBuildOS Company"] = "",
  },
})

-- Paired already. No agent secret: Driver Cloud's assertions are served
-- unsigned (the pre-Phase-5 path), which keeps this file about delivery.
store["device_token"] = "sbc4_0123abcd_secret"
store["system_id"] = "7e14128e-fb05-4645-929f-e1ee9e1ee964"

-- The Agent loads as itself: its EC handlers land in the Agent's EC table.
package.path = "./drivers/smartbuildos/?.lua;" .. package.path
D.as(AGENT, function()
  EC = agent.EC
  dofile("drivers/smartbuildos/driver.lua")
  agent.EC = EC
end)

-- ── the module: the shared client, wired the way AI Core wires it ──────────
local client = require("sbos.moduleclient")
local license = require("sbos.license")
local lastError = ""
local commandsSeen = {}
D.as(MODULE, function()
  client.setup({
    module_id = "ai_core",
    driver_version = "20261120.100000",
    capabilities = { "ai_core" },
    entitlements = { "SBOS_AI_CORE" },
    commands = { "deliver_result", "raise_event", "refresh_status" },
    event_types = { "ai." },
    singleton = true,
    status = function()
      return "ready", lastError, {}
    end,
    -- The shape of AI Core's onOperation: Executing, then the terminal
    -- state, both reported from inside the command handler.
    onCommand = function(request)
      commandsSeen[#commandsSeen + 1] = request.request_id
      client.commandResult(request.request_id, "Executing", request.command)
      client.commandResult(request.request_id, "Completed", "delivered")
    end,
  })
  EC.SBOS_ENTITLEMENT = license.onEntitlement
  license.setup({ sku = "SBOS_AI_CORE" })
  client.register()
end)

local function heartbeatWith(commands)
  responders["heartbeat"] = function()
    return { ok = true, body = { ok = true, commands = commands } }
  end
  D.as(AGENT, function()
    EC.SEND_HEARTBEAT()
  end)
  responders["heartbeat"] = nil
  D.drain()
  local acks = requestsTo("commands")
  return acks[#acks] and acks[#acks].data.acks or {}
end
local function commandStates(requestId)
  local states = {}
  for _, it in ipairs(gEvents.items) do
    if it.env.event_type == "agent.command_state" and it.env.payload.request_id == requestId then
      states[#states + 1] = it.env.payload.state
    end
  end
  return table.concat(states, ",")
end

-- What Driver Cloud issues for AI Core (unsigned; see the pairing note).
local issued = "NOT_ENTITLED"
local function assertion()
  return {
    driver_sku = "SBOS_AI_CORE",
    status = issued,
    license_type = issued == "NOT_ENTITLED" and "" or "SUBSCRIPTION_INCLUDED",
    features = issued == "NOT_ENTITLED" and {} or { "BASE" },
    issued_at = "2026-11-20T00:00:00.000Z",
  }
end
responders["entitlements/refresh"] = function()
  return {
    ok = true,
    body = {
      assertions = { assertion() },
      support_id = "SBOS-TEST01",
      checked_at = os.date("!%Y-%m-%dT%H:%M:%S.000Z"),
      revalidate_after_hours = 24,
      offline_cache_days = 7,
    },
  }
end
print("[1] the Agent starts paired; the module registers through the real client")
D.as(AGENT, function()
  OnDriverInit()
  OnDriverLateInit("DIT_STARTUP")
end)
D.drain()
check("module registered", client.isRegistered(), client.describe())
check("the Agent holds it", gModules:find("ai_core", tostring(MODULE)) ~= nil)

for _, mode in ipairs({ "async", "sync" }) do
  print(string.format("[2/%s] MODULE_COMMAND results are recorded however Director orders delivery", mode))
  D.mode = mode
  local requestId = "req-" .. mode
  local acks = heartbeatWith({
    {
      id = "c-" .. mode,
      command = "MODULE_COMMAND",
      payload = {
        module_id = "ai_core",
        command = "deliver_result",
        request_id = requestId,
        expires_at = os.time() + 60,
        args = { job_id = "job-1" },
      },
    },
  })
  check("the ack says accepted", acks[1] ~= nil and acks[1].ok == true, acks[1] and (acks[1].error or acks[1].result))
  check("the module ran it once", commandsSeen[#commandsSeen] == requestId and #commandsSeen >= 1)
  local rec = gModuleCommands[requestId]
  check("the ledger reads Completed", rec ~= nil and rec.state == "Completed", rec and rec.state)
  check("no expiry timer is left", clock.timers["ModuleCommandExpiry:" .. requestId] == nil)
  advance(70000)
  rec = gModuleCommands[requestId]
  check(
    "past the expiry it is still Completed, not Unverified",
    rec ~= nil and rec.state == "Completed",
    rec and rec.state
  )
  local states = commandStates(requestId)
  check(
    "the pipeline carried every state, Accepted first, ending Completed",
    states:match("^Accepted,") ~= nil and states:match(",Completed$") ~= nil and not states:find("Unverified"),
    states
  )
end

print("[2b] a late or duplicate result is still handled as before (sync)")
D.mode = "sync"
D.as(MODULE, function()
  client.commandResult("req-sync", "Failed", "late")
end)
check("terminal stays terminal", gModuleCommands["req-sync"].state == "Completed")
D.as(MODULE, function()
  client.commandResult("req-unknown", "Completed", "for nothing")
end)
check("a result for an unknown request is dropped", gModuleCommands["req-unknown"] == nil)

print("[3] a send that fails ends the record as Failed")
D.mode = "async"
do
  local realSend = D.send
  D.send = function(toId, command, params, allowEmpty)
    if command == "SBOS_MODULE_COMMAND" then
      error("Director refused the frame")
    end
    return realSend(toId, command, params, allowEmpty)
  end
  local acks = heartbeatWith({
    {
      id = "c-fail",
      command = "MODULE_COMMAND",
      payload = { module_id = "ai_core", command = "raise_event", request_id = "req-fail", expires_at = os.time() + 60 },
    },
  })
  D.send = realSend
  check(
    "the ack fails and says why",
    acks[1] ~= nil and acks[1].ok == false and tostring(acks[1].error):find("could not forward") ~= nil,
    acks[1] and (acks[1].error or acks[1].result)
  )
  local rec = gModuleCommands["req-fail"]
  check("the ledger reads Failed", rec ~= nil and rec.state == "Failed", rec and rec.state)
  check("no expiry timer was armed", clock.timers["ModuleCommandExpiry:req-fail"] == nil)
  advance(70000)
  check("it never becomes Unverified", gModuleCommands["req-fail"].state == "Failed")
end

print("[4] a cleared status detail reaches the Agent and the heartbeat")
for _, mode in ipairs({ "async", "sync" }) do
  D.mode = mode
  lastError = "AI provider error: 503"
  D.as(MODULE, function()
    client.sendStatus()
  end)
  D.drain()
  local entry = gModules:find("ai_core", tostring(MODULE))
  check(mode .. ": the error is shown", entry.detail == "AI provider error: 503", entry.detail)
  lastError = ""
  D.as(MODULE, function()
    client.sendStatus()
  end)
  D.drain()
  entry = gModules:find("ai_core", tostring(MODULE))
  check(mode .. ": cleared on the Agent", entry.detail == "", entry.detail)
end
do
  local frame = D.framesOf("SBOS_MODULE_STATUS", AGENT)
  frame = frame[#frame]
  check("the status frame asked for empty values", frame.allowEmpty == true)
  check("and still leaves other empty params out", frame.params.applied_config_version == nil)
  requests = {}
  D.as(AGENT, function()
    EC.SEND_HEARTBEAT()
  end)
  local hb = requestsTo("heartbeat")
  local row = nil
  for _, m in ipairs(hb[#hb] and hb[#hb].data.modules or {}) do
    if m.module_id == "ai_core" then
      row = m
    end
  end
  check("the heartbeat carries the cleared detail", row ~= nil and row.detail == "", row and row.detail)
end
do
  -- config_error has the same shape: "" when a later config applied.
  D.as(MODULE, function()
    client.sendStatus({ config_error = "v3 refused" })
  end)
  D.drain()
  local entry = gModules:find("ai_core", tostring(MODULE))
  check("a config error is shown", entry.config_error == "v3 refused", entry.config_error)
  D.as(MODULE, function()
    client.sendStatus({ applied_config_version = "4", config_error = "" })
  end)
  D.drain()
  entry = gModules:find("ai_core", tostring(MODULE))
  check("and cleared by the next applied config", entry.config_error == "", entry.config_error)
end
do
  -- What Director does WITHOUT the flag: the "" never arrives (the old
  -- client), so the Agent keeps the last text. Kept here as the proof that
  -- the harness models the drop at all.
  lastError = "stale"
  D.as(MODULE, function()
    client.sendStatus()
  end)
  D.drain()
  D.as(MODULE, function()
    C4:SendToDevice(AGENT, "SBOS_MODULE_STATUS", {
      module_id = "ai_core",
      instance_id = tostring(MODULE),
      token = client._state().token,
      status = "ready",
      detail = "",
    })
  end)
  D.drain()
  local entry = gModules:find("ai_core", tostring(MODULE))
  check("without allowEmptyValues the Agent never sees the clear", entry.detail == "stale", entry.detail)
end

print("[5] REQUEST_ENTITLEMENTS: licensed without a restart, one per minute")
D.mode = "sync"
do
  -- The registration's own refresh (a never-seen SKU, 10 s after [1])
  -- fetched what was issued then: nothing licensed.
  check("before: the module is NOT_ENTITLED", license.status() == "NOT_ENTITLED", license.status())
  local before = module.Properties["License Status"]
  check(
    "the capability is advertised",
    (function()
      requests = {}
      D.as(AGENT, function()
        EC.SEND_HEARTBEAT()
      end)
      for _, c in ipairs(requestsTo("heartbeat")[1].data.capabilities) do
        if c == "entitlements_refresh_v1" then
          return true
        end
      end
      return false
    end)()
  )
  -- The platform issues the licence, then asks for a re-check.
  issued = "AUTHORIZED_SUBSCRIPTION"
  local acks = heartbeatWith({ { id = "e1", command = "REQUEST_ENTITLEMENTS" } })
  check(
    "the ack is the short result line",
    acks[1] ~= nil and acks[1].ok == true and acks[1].result == "entitlement refresh started",
    acks[1] and (acks[1].result or acks[1].error)
  )
  check("Driver Cloud was asked once", #requestsTo("entitlements/refresh") == 1, #requestsTo("entitlements/refresh"))
  check("after: the module is licensed", license.status() == "AUTHORIZED_SUBSCRIPTION", license.status())
  check(
    "and its License Status repainted",
    module.Properties["License Status"] ~= before and module.Properties["License Status"] ~= "",
    tostring(before) .. " -> " .. tostring(module.Properties["License Status"])
  )
end

local function fetches()
  return requestsTo("entitlements/refresh")
end
local function ask(id)
  local acks = heartbeatWith({ { id = id, command = "REQUEST_ENTITLEMENTS" } })
  return acks[1] and acks[1].ok == true and acks[1].result or (acks[1] and acks[1].error)
end

print("[5a] two licence changes 30 s apart: two fetches, the second at the 60 s mark")
do
  advance(61000) -- clear of [5]'s window
  requests = {}
  issued = "AUTHORIZED_SUBSCRIPTION"
  local t0 = clock.now
  check("the first request runs at once", ask("a1") == "entitlement refresh started")
  advance(30000)
  -- The platform commits a second change and asks again; the Agent may have
  -- read the licences before it committed, so this one must be honoured.
  issued = "AUTHORIZED_PERPETUAL"
  check("the second is scheduled, not skipped", ask("a2") == "entitlement refresh scheduled")
  check("nothing fetched for it yet", #fetches() == 1, #fetches())
  advance(29000)
  check("still one fetch at 59 s", #fetches() == 1, #fetches())
  advance(2000)
  local f = fetches()
  check("two fetches in total", #f == 2, #f)
  check(
    "the second at the 60 s mark",
    f[2] ~= nil and f[2].at - t0 >= 60000 and f[2].at - t0 < 61000,
    f[2] and (f[2].at - t0)
  )
  check("the module holds the SECOND change", license.status() == "AUTHORIZED_PERPETUAL", license.status())
  advance(180000)
  check("and nothing more is fetched", #fetches() == 2, #fetches())
end

print("[5b] five requests inside the window: one trailing fetch")
do
  advance(61000)
  requests = {}
  check("the first runs", ask("b0") == "entitlement refresh started")
  local all = true
  for i = 1, 5 do
    advance(5000)
    all = all and ask("b" .. i) == "entitlement refresh scheduled"
  end
  check("all five answered scheduled", all)
  advance(60000)
  check("exactly one trailing fetch", #fetches() == 2, #fetches())
  advance(180000)
  check("and no more", #fetches() == 2, #fetches())
end

print("[5c] a request while a refresh is in flight: one trailing fetch after it ends")
for _, outcome in ipairs({ "succeeds", "fails" }) do
  advance(61000)
  requests = {}
  deferPaths["entitlements/refresh"] = true
  -- A dealer refresh that started BEFORE the request: it is in flight.
  D.as(AGENT, function()
    EC.REFRESH_ENTITLEMENTS()
  end)
  check(outcome .. ": the dealer refresh is in flight", #deferred == 1 and #fetches() == 1, #deferred)
  check(outcome .. ": the request is scheduled", ask("c-" .. outcome) == "entitlement refresh scheduled")
  -- Pressed again while the first is still running, the dealer action starts
  -- nothing, so it cannot answer the owed request.
  D.as(AGENT, function()
    EC.REFRESH_ENTITLEMENTS()
  end)
  advance(5000)
  check(outcome .. ": nothing more while in flight", #fetches() == 1, #fetches())
  deferPaths["entitlements/refresh"] = nil
  -- The HTTP answer runs in the Agent, as on a controller.
  D.as(AGENT, settleDeferred, outcome == "succeeds")
  check(outcome .. ": no trailing fetch inside the finishing callback", #fetches() == 1, #fetches())
  advance(2000)
  check(outcome .. ": then exactly one trailing fetch", #fetches() == 2, #fetches())
  advance(180000)
  check(outcome .. ": and no more", #fetches() == 2, #fetches())
end

print("[5d] a dealer refresh started after the request settles the debt")
do
  advance(61000)
  requests = {}
  check("the first runs", ask("d0") == "entitlement refresh started")
  advance(10000)
  check("the second is owed", ask("d1") == "entitlement refresh scheduled")
  advance(5000)
  D.as(AGENT, function()
    EC.REFRESH_ENTITLEMENTS()
  end)
  check("the dealer action runs at once (unthrottled)", #fetches() == 2, #fetches())
  advance(180000)
  check("it answered the owed request: no trailing fetch", #fetches() == 2, #fetches())
end

print("[5e] a restart drops the debt")
do
  advance(61000)
  requests = {}
  check("the first runs", ask("e0") == "entitlement refresh started")
  advance(10000)
  check("the second is owed", ask("e1b") == "entitlement refresh scheduled")
  -- Director reloads the driver: its timers go, the file runs again.
  clock.timers = {}
  D.as(AGENT, function()
    dofile("drivers/smartbuildos/driver.lua")
    agent.EC = EC
    OnDriverInit()
    OnDriverLateInit("DIT_STARTUP")
  end)
  D.drain()
  advance(180000)
  check("no owed fetch after the restart (the cache is fresh, so init fetches nothing)", #fetches() == 1, #fetches())
  check("a new request runs at once", ask("e2b") == "entitlement refresh started" and #fetches() == 2)
end

print("[6] unpaired: the command never arrives, as for REQUEST_HEARTBEAT")
D.as(AGENT, function()
  EC.UNPAIR()
end)
D.drain()
requests = {}
local acks = heartbeatWith({
  { id = "u1", command = "REQUEST_HEARTBEAT" },
  { id = "u2", command = "REQUEST_ENTITLEMENTS" },
})
check("no heartbeat, so no command and no ack", #acks == 0 and #requestsTo("commands") == 0, #acks)
check("and no refresh", #requestsTo("entitlements/refresh") == 0)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
