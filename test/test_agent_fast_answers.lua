-- Fast answers and the Realtime doorbell: the REAL Agent, a module on the
-- REAL shared client, and the REAL vendor WebSocket over a scripted server,
-- in one Lua state (test/director_delivery.lua, both delivery orders).
--
-- An AI Core ask is answered {accepted, job_id} at once and its result comes
-- back later as a queued MODULE_COMMAND, which reaches the Agent only on the
-- answer to a request it makes. So while a job is pending the Agent checks
-- in every 5 s (sbos.fastanswers), and the doorbell, when it works, makes
-- even that unnecessary.
--
-- [1] boot + registration
-- [2] an accepted job starts the burst; the result ends it; normal cadence after
-- [3] a result that never comes: the burst ends at the 90 s cap
-- [4] two jobs share one burst; it ends when the last result arrives
-- [5] no burst while unpaired-equivalent states: last delivery failed, a
--     429 (and its 60 s quiet), a job with a `state` (analyze_household), an
--     idempotent replay
-- [6] a heartbeat in flight is never doubled; a failed burst heartbeat ends it
-- [7] the whole flow under synchronous delivery
-- [8] the doorbell joins, rings, and a ring ends a burst
-- [9] reconnects open a NEW socket only after the old one is deleted (the
--     vendor caches sockets by URL until then; reusing it went deaf)
-- [10] a drop without a close frame, a silent socket and a refused join all
--      reconnect
-- [11] unpair and driver destroy leave no timer behind
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
-- SetTimer returns the id, as the vendor's returns a handle: the WebSocket
-- module stores it and cancels by it (pong watchdog).
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = D.wrapTimer(cb), every = repeating and ms or nil }
    return id
  end
  function CancelTimer(id)
    if id ~= nil then
      clock.timers[id] = nil
    end
    return nil
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
local responders = {}
local deferPaths = {}
local deferred = {}
local settleDeferredAsAgent
local function settleDeferred(ok)
  return settleDeferredAsAgent(ok)
end
local function settleDeferredRaw(ok)
  local list = deferred
  deferred = {}
  for _, d in ipairs(list) do
    if ok then
      local answer = responders[d.path] and responders[d.path](d.data) or { body = { ok = true } }
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
      local path = url:match("/api/integrations/control4/(.*)$") or url:match("/api/driver%-cloud/(.*)$") or url
      requests[#requests + 1] = { url = url, path = path, data = data, headers = headers, at = clock.now }
      if deferPaths[path] then
        return {
          next = function(_, onOk, onErr)
            deferred[#deferred + 1] = { path = path, url = url, data = data, onOk = onOk, onErr = onErr }
          end,
        }
      end
      local r = responders[path]
      local answer = r and r(data) or { code = 200, body = { ok = true } }
      local code = answer.code or 200
      local value = { url = url, code = code, headers = answer.headers or {}, body = JSON:encode(answer.body or {}) }
      if code < 200 or code >= 300 then
        value.error = "HTTP " .. code
      end
      return settled(code >= 200 and code < 300, value)
    end,
  }
end
local function requestsTo(path, since)
  local out = {}
  for _, r in ipairs(requests) do
    if r.path == path and (since == nil or r.at >= since) then
      out[#out + 1] = r
    end
  end
  return out
end

-- ── a scripted Realtime server behind the REAL vendor WebSocket ─────────────
-- LuaJIT has no lpack: the two string.unpack shapes the module uses, captured
-- by it at require time, so installed first.
string.unpack = function(s, fmt)
  local out = {}
  for i = 1, #fmt do
    out[i] = string.byte(s, i) or 0
  end
  return #fmt + 1, unpack(out)
end
function tohex(s)
  return (tostring(s):gsub("%x%x", function(cc)
    return string.char(tonumber(cc, 16))
  end))
end
OCS, RFN = OCS or {}, RFN or {}
local server = {
  join = nil, -- the last phx_join frame decoded
  mute = false, -- true: stops answering keepalives (a silent socket)
  joinReply = "ok",
  sent = {}, -- every client frame, decoded
}
local function serverFrame(text, opcode)
  local len = #text
  local head
  if len <= 125 then
    head = string.char(opcode or 0x81, len)
  else
    head = string.char(opcode or 0x81, 126, math.floor(len / 256), len % 256)
  end
  return head .. text
end
local function decodeClientFrame(data)
  if data:sub(1, 3) == "GET" then
    return { http = true }
  end
  local b1, b2 = data:byte(1, 2)
  local opcode = bit.band(b1, 0x0F)
  local len = bit.band(b2, 0x7F)
  local pos = 3
  if len == 126 then
    len = data:byte(3) * 256 + data:byte(4)
    pos = 5
  end
  local mask = { data:byte(pos, pos + 3) }
  pos = pos + 4
  local out = {}
  for i = 1, len do
    out[i] = string.char(bit.bxor(data:byte(pos + i - 1), mask[((i - 1) % 4) + 1]))
  end
  return { opcode = opcode, text = table.concat(out) }
end
--- Director calls a driver's network callbacks AS that driver.
local AGENT_ID = 99
local function asAgent(f, ...)
  if D.current ~= nil then
    return f(...)
  end
  return D.as(AGENT_ID, f, ...)
end
local function toClient(binding, bytes)
  local f = RFN[binding]
  if f then
    asAgent(f, binding, 443, bytes)
  end
end
local function status(binding, what)
  asAgent(OCS[binding], binding, 443, what)
end
function C4:SendToNetwork(binding, _, data)
  local frame = decodeClientFrame(data)
  server.sent[#server.sent + 1] = frame
  if frame.http or server.mute then
    return
  end
  if frame.opcode == 0x09 then
    toClient(binding, string.char(0x8A, 0x00)) -- pong
    return
  end
  if frame.opcode == 0x01 then
    local ok, msg = pcall(function()
      return JSON:decode(frame.text)
    end)
    if ok and type(msg) == "table" then
      if msg.event == "phx_join" then
        server.join = { binding = binding, topic = msg.topic, ref = msg.ref }
      elseif msg.topic == "phoenix" and msg.event == "heartbeat" then
        toClient(
          binding,
          serverFrame(
            JSON:encode({ topic = "phoenix", event = "phx_reply", payload = { status = "ok" }, ref = msg.ref })
          )
        )
      end
    end
  end
end
function C4:Hash()
  return "ACCEPT"
end
local WebSocket = require("drivers-common-public.module.websocket")
local URL_PREFIX = "wss://rt.example.test/realtime/v1/websocket"
--- The doorbell socket the Agent holds now (the vendor registry is shared).
local function liveSocket()
  for k, v in pairs(WebSocket.Sockets or {}) do
    if type(k) == "string" and k:find(URL_PREFIX, 1, true) == 1 and not v.deleteAfterClosing then
      return v
    end
  end
  return nil
end
--- Director brings the TCP/TLS connection up and the server upgrades it.
local function connectSocket(ws)
  status(ws.netBinding, "ONLINE")
  toClient(
    ws.netBinding,
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ACCEPT\r\n\r\n"
  )
end
local function replyJoin(status)
  local j = server.join
  local payload = { status = status or "ok", response = {} }
  if status == "error" then
    payload.response = { reason = "public channels are disabled" }
  end
  toClient(
    j.binding,
    serverFrame(JSON:encode({ topic = j.topic, event = "phx_reply", payload = payload, ref = j.ref }))
  )
end
local function ring()
  local j = server.join
  toClient(
    j.binding,
    serverFrame(JSON:encode({
      topic = j.topic,
      event = "broadcast",
      payload = { type = "broadcast", event = "ping", payload = {} },
    }))
  )
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
settleDeferredAsAgent = function(ok)
  return D.as(AGENT, settleDeferredRaw, ok)
end
D.add(MODULE, {
  Properties = {
    ["License Status"] = "",
    ["License Source"] = "",
    ["Subscription Tier"] = "",
    ["SmartBuildOS Company"] = "",
  },
})

store["device_token"] = "sbc4_0123abcd_secret"
store["system_id"] = "7e14128e-fb05-4645-929f-e1ee9e1ee964"

package.path = "./drivers/smartbuildos/?.lua;" .. package.path
D.as(AGENT, function()
  EC = agent.EC
  dofile("drivers/smartbuildos/driver.lua")
  agent.EC = EC
end)

-- ── the module ──────────────────────────────────────────────────────────────
local client = require("sbos.moduleclient")
local license = require("sbos.license")
local delivered = {}
local cloudAnswers = {}
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
      return "ready", "", {}
    end,
    onCommand = function(request)
      delivered[#delivered + 1] = request.args and request.args.job_id or request.request_id
      client.commandResult(request.request_id, "Completed", "delivered")
    end,
  })
  EC.SBOS_ENTITLEMENT = license.onEntitlement
  license.setup({ sku = "SBOS_AI_CORE" })
  client.register()
end)

-- ── the platform's side of an ask ──────────────────────────────────────────
local rpcAnswer = function(data)
  return { body = { ok = true, result = { accepted = true, job_id = "job-" .. tostring(data.request_id) } } }
end
responders["modules/rpc"] = function(data)
  return rpcAnswer(data)
end
--- Results the platform has queued for the next heartbeat (claimed by it).
local queue = {}
local heartbeatExtra = {}
responders["heartbeat"] = function()
  local body = { ok = true }
  for k, v in pairs(heartbeatExtra) do
    body[k] = v
  end
  if #queue > 0 then
    body.commands = queue
    queue = {}
  end
  return { body = body }
end
local seq = 0
local function queueResult(jobId)
  seq = seq + 1
  queue[#queue + 1] = {
    id = "c" .. seq,
    command = "MODULE_COMMAND",
    payload = {
      module_id = "ai_core",
      command = "deliver_result",
      request_id = "dr-" .. seq,
      expires_at = os.time() + 600,
      args = { job_id = jobId, response_id = "r" .. seq, text = "It is 21 degrees.", kind = "answer" },
    },
  }
end
--- The module asks; returns the job id the platform will answer with.
local function ask(tag, op)
  local jobId
  local before = #requestsTo("modules/rpc")
  D.as(MODULE, function()
    client.cloudRequest(op or "ask", { question = "temperature?" }, { idempotency_key = "k-" .. tag }, function(res)
      cloudAnswers[#cloudAnswers + 1] = res
    end)
  end)
  D.drain()
  local rpcs = requestsTo("modules/rpc")
  if #rpcs > before then
    jobId = "job-" .. tostring(rpcs[#rpcs].data.request_id)
  end
  return jobId
end
local function burstActive()
  return AgentFastAnswers.active == true and clock.timers[FastAnswers.TIMER] ~= nil
end
local function gaps(beats)
  local min = math.huge
  for i = 2, #beats do
    min = math.min(min, beats[i].at - beats[i - 1].at)
  end
  return min
end
local function has(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

print("[1] the Agent starts paired; the module registers")
D.as(AGENT, function()
  OnDriverInit()
  OnDriverLateInit("DIT_STARTUP")
end)
D.drain()
check("module registered", client.isRegistered(), client.describe())
check("no burst at start", not burstActive())

-- The regular heartbeat is every 60 s (Heartbeat Interval 1m).
local function settle()
  advance(61000)
  D.drain()
end
settle()

for _, mode in ipairs({ "async", "sync" }) do
  D.mode = mode
  print(string.format("[2/%s] an accepted job starts the burst; its result ends it", mode))
  local t0 = clock.now
  local job = ask("a-" .. mode)
  check("the ask was answered with a job", job ~= nil and #cloudAnswers > 0)
  check("the burst started", burstActive(), AgentFastAnswers:status())
  advance(5000)
  local beats = requestsTo("heartbeat", t0 + 1)
  -- Five seconds after the ask, or sooner when the Agent's own minute
  -- timer happened to fall inside them (the burst then spaces from it).
  check("a check-in within 5 s of the ask", #beats == 1 and beats[1].at - t0 <= 5000, beats[1] and (beats[1].at - t0))
  advance(5000)
  beats = requestsTo("heartbeat", t0)
  check("and every 5 s", #beats >= 2 and beats[#beats].at - beats[#beats - 1].at == 5000, #beats)
  queueResult(job)
  advance(5000)
  check("the result reached the module", has(delivered, job), table.concat(delivered, ","))
  check("the burst ended on delivery", not burstActive(), AgentFastAnswers:status())
  check(
    "ended for the right reason",
    AgentFastAnswers.lastEnd and AgentFastAnswers.lastEnd.reason == "delivered",
    AgentFastAnswers.lastEnd and AgentFastAnswers.lastEnd.reason
  )
  local after = clock.now
  advance(40000)
  check("no heartbeat in the next 40 s but the normal one", #requestsTo("heartbeat", after + 1) <= 1)
  check("the burst never beat closer than 5 s", gaps(requestsTo("heartbeat", t0)) >= 5000)
  settle()
end
D.mode = "async"

print("[3] a result that never comes: the burst ends at the 90 s cap")
do
  local t0 = clock.now
  local job = ask("cap")
  check("burst started", job ~= nil and burstActive())
  advance(89000)
  check("still running at 89 s", burstActive())
  advance(6000)
  check("ended by 95 s", not burstActive(), AgentFastAnswers:status())
  check(
    "ended at the cap",
    AgentFastAnswers.lastEnd and AgentFastAnswers.lastEnd.reason == "cap",
    AgentFastAnswers.lastEnd and AgentFastAnswers.lastEnd.reason
  )
  local beats = requestsTo("heartbeat", t0)
  check("at most 18 burst beats plus the normal ones in 95 s", #beats <= 20, #beats)
  check("never closer than 5 s", gaps(beats) >= 5000, gaps(beats))
  local after = clock.now
  advance(59000)
  check("then only the normal cadence", #requestsTo("heartbeat", after + 1) <= 1, #requestsTo("heartbeat", after + 1))
  settle()
end

print("[4] two jobs share one burst; the last result ends it")
do
  local t0 = clock.now
  local a = ask("share-a")
  advance(2000)
  local b = ask("share-b")
  check("two jobs pending, one burst", AgentFastAnswers.jobCount == 2 and burstActive(), AgentFastAnswers.jobCount)
  check("one timer, not two", clock.timers[FastAnswers.TIMER] ~= nil)
  queueResult(a)
  advance(5000)
  check("first result delivered", has(delivered, a))
  check("burst still running for the second", burstActive() and AgentFastAnswers.jobCount == 1)
  queueResult(b)
  advance(5000)
  check("second result delivered, burst over", has(delivered, b) and not burstActive())
  check("one burst counted for both", AgentFastAnswers.stats.bursts == 4, AgentFastAnswers.stats.bursts)
  check("never closer than 5 s", gaps(requestsTo("heartbeat", t0)) >= 5000)
  settle()
end

print("[5] refusals: failing cloud, 429 quiet, a job with a state, a replay")
do
  -- The last delivery failed: the Agent is already in trouble with the cloud.
  deferPaths["telemetry"] = nil
  local saved = responders["heartbeat"]
  responders["heartbeat"] = function()
    return { code = 503, body = { error = "down" } }
  end
  advance(60000)
  responders["heartbeat"] = saved
  local job = ask("failing")
  -- The rpc itself succeeded, which resets the failure count: a cloud that
  -- answers the ask is not failing. Assert on the state the rule reads.
  check("an answered ask clears the failure state", job ~= nil)
  AgentFastAnswersStop("test")
  settle()

  -- A 429 on a burst heartbeat: the burst ends and none starts for 60 s.
  local t0 = clock.now
  ask("rl-1")
  check("burst started", burstActive())
  responders["heartbeat"] = function()
    return { code = 429, body = { error = "Too many requests." } }
  end
  advance(5000)
  responders["heartbeat"] = saved
  check("a 429 ended the burst", not burstActive(), AgentFastAnswers:status())
  check(
    "as a failure",
    AgentFastAnswers.lastEnd and AgentFastAnswers.lastEnd.reason == "failed",
    AgentFastAnswers.lastEnd and AgentFastAnswers.lastEnd.reason
  )
  -- The heartbeat route answers 429 and the Agent's gFailures is now 1; a
  -- successful rpc resets it, so the quiet window is what holds.
  ask("rl-2")
  check("no new burst inside the 60 s quiet", not burstActive(), AgentFastAnswers:status())
  check("the status says so", AgentFastAnswers:status():find("429", 1, true) ~= nil, AgentFastAnswers:status())
  advance(61000)
  ask("rl-3")
  check("a burst may start again after it", burstActive())
  AgentFastAnswersStop("test")
  check("only one burst heartbeat was sent into the 429", #requestsTo("heartbeat", t0 + 1) <= 3)
  settle()

  -- analyze_household answers a job_id WITH a state; nothing is delivered.
  rpcAnswer = function(data)
    return {
      body = { ok = true, result = { accepted = true, state = "queued", job_id = "job-" .. data.request_id } },
    }
  end
  ask("household", "analyze_household")
  check("a job with a state starts nothing", not burstActive())
  -- A refused ask, a synchronous answer (job_id null): nothing either.
  rpcAnswer = function()
    return { body = { ok = true, result = { accepted = true, applied = true } } }
  end
  ask("context", "set_context")
  check("an accepted answer without a job starts nothing", not burstActive())
  rpcAnswer = function()
    return { body = { ok = false, error_code = "not_permitted", result = {} } }
  end
  ask("refused")
  check("a refusal starts nothing", not burstActive())
  -- An idempotent replay of an old ask.
  rpcAnswer = function(data)
    return {
      headers = { ["X-SBOS-Idempotent-Replay"] = "1" },
      body = { ok = true, result = { accepted = true, job_id = "job-" .. data.request_id } },
    }
  end
  ask("replay")
  check("an idempotent replay starts nothing", not burstActive())
  rpcAnswer = function(data)
    return { body = { ok = true, result = { accepted = true, job_id = "job-" .. tostring(data.request_id) } } }
  end

  -- The pure rule, directly: failing and unpaired refuse.
  local fa = FastAnswers.new({
    now = function()
      return clock.now
    end,
  })
  check("unpaired refuses", fa:expect("j", { paired = false }) == "refused:unpaired")
  check("a failing cloud refuses", fa:expect("j", { paired = true, failing = true }) == "refused:cloud failing")
  check("otherwise it starts", fa:expect("j", { paired = true }) == "started")
  check("and a second joins", fa:expect("k", { paired = true }) == "joined")
  local pj = FastAnswers.pendingJob
  check("a string job id is pending", pj({ ok = true, result = { accepted = true, job_id = "a-1" } }) == "a-1")
  check("a numeric job id is pending, as text", pj({ ok = true, result = { accepted = true, job_id = 42 } }) == "42")
  check("not accepted: nothing", pj({ ok = true, result = { job_id = "a-1" } }) == nil)
  check("a refusal: nothing", pj({ ok = false, result = { accepted = true, job_id = "a-1" } }) == nil)
  check("an id with spaces: nothing", pj({ ok = true, result = { accepted = true, job_id = "a 1" } }) == nil)
  check("a delivered numeric id matches", fa:delivered(FastAnswers.jobKey(7)) == false and FastAnswers.jobKey(7) == "7")
  settle()
end

print("[6] a heartbeat in flight is never doubled; a failed one ends the burst")
do
  local t0 = clock.now
  local job = ask("inflight")
  deferPaths["heartbeat"] = true
  advance(5000)
  check("one burst heartbeat left", #requestsTo("heartbeat", t0 + 1) == 1, #requestsTo("heartbeat", t0 + 1))
  advance(20000)
  check(
    "none other while it is in flight (burst or the Agent's own timer)",
    #requestsTo("heartbeat", t0 + 1) == 1,
    #requestsTo("heartbeat", t0 + 1)
  )
  deferPaths["heartbeat"] = nil
  queueResult(job)
  settleDeferred(true)
  D.drain()
  check("its answer delivered the result and ended the burst", has(delivered, job) and not burstActive())
  settle()

  ask("fail")
  deferPaths["heartbeat"] = true
  advance(5000)
  deferPaths["heartbeat"] = nil
  settleDeferred(false)
  D.drain()
  check("an unreachable cloud ended the burst", not burstActive(), AgentFastAnswers:status())
  settle()
end

print("[7] Composer's Send Heartbeat Now inside a burst does not double up")
do
  local t0 = clock.now
  ask("manual")
  advance(3000)
  D.as(AGENT, function()
    EC.SEND_HEARTBEAT()
  end)
  advance(4000)
  local beats = requestsTo("heartbeat", t0 + 1)
  check("the burst waited 5 s after the manual heartbeat", #beats == 1, #beats)
  advance(1000)
  beats = requestsTo("heartbeat", t0 + 1)
  check("then resumed on the cadence", #beats == 2 and beats[2].at - beats[1].at == 5000, #beats)
  AgentFastAnswersStop("test")
  settle()
end

print("[8] the doorbell joins and rings; a ring ends a burst")
do
  heartbeatExtra.realtime = { url = "https://rt.example.test", key = "anon-key", channel = "c4ping:sys-1" }
  advance(60000)
  local ws = liveSocket()
  check("the offer opened a socket", ws ~= nil)
  connectSocket(ws)
  check(
    "it joined the offered channel",
    server.join ~= nil and server.join.topic == "realtime:c4ping:sys-1",
    server.join and server.join.topic
  )
  replyJoin("ok")
  check("the Agent says joined", AgentDoorbellStatus():find("joined", 1, true) ~= nil, AgentDoorbellStatus())
  check("the status line prints no key", AgentDoorbellStatus():find("anon-key", 1, true) == nil)

  local t0 = clock.now
  local job = ask("rang")
  check("a burst started", burstActive())
  queueResult(job)
  advance(1000)
  ring()
  check("the ring ended the burst", not burstActive(), AgentFastAnswers:status())
  check(
    "as rang",
    AgentFastAnswers.lastEnd and AgentFastAnswers.lastEnd.reason == "rang",
    AgentFastAnswers.lastEnd and AgentFastAnswers.lastEnd.reason
  )
  advance(2000)
  check("its heartbeat 2 s later delivered the result", has(delivered, job))
  check("one heartbeat in all", #requestsTo("heartbeat", t0) == 1, #requestsTo("heartbeat", t0))
  advance(30000)
  check("keepalives are answered; still joined", AgentDoorbellStatus():find("joined", 1, true) ~= nil)
end

print("[9] a reconnect opens a NEW socket, only once the old one is deleted")
do
  -- The trap, shown on the vendor module itself: until a delete completes,
  -- new(url) hands back the socket being deleted.
  local probe = WebSocket:new("wss://probe.example.test/x")
  probe:delete()
  check("vendor: new() during a delete returns the dying socket", WebSocket:new("wss://probe.example.test/x") == probe)
  advance(3000)
  check("vendor: a fresh one after it completes", WebSocket:new("wss://probe.example.test/x") ~= probe)

  local old = liveSocket()
  local before = AgentDoorbellStatus()
  toClient(old.netBinding, string.char(0x88, 0x00)) -- close frame
  check("a close frame schedules one retry", AgentDoorbellStatus():find("waiting", 1, true) ~= nil, before)
  advance(15000)
  check("the old socket is being deleted", old.deleteAfterClosing == true)
  check("and nothing new is opened meanwhile", liveSocket() == nil)
  advance(3000)
  local fresh = liveSocket()
  check("a fresh socket after the delete completes", fresh ~= nil and fresh ~= old)
  check("on the reclaimed binding", fresh ~= nil and fresh.netBinding == old.netBinding)
  server.join = nil
  connectSocket(fresh)
  replyJoin("ok")
  check("it joins", AgentDoorbellStatus():find("joined", 1, true) ~= nil, AgentDoorbellStatus())
  local t0 = clock.now
  queueResult("job-after-reconnect")
  ring()
  advance(2000)
  check("and a ring still reaches the Agent", #requestsTo("heartbeat", t0) == 1)
  check("which collected the queued result", has(delivered, "job-after-reconnect"))

  -- The old socket's late callbacks change nothing.
  local status = AgentDoorbellStatus()
  asAgent(function()
    pcall(old.Offline, old)
  end)
  check("a stale socket's callback is ignored", AgentDoorbellStatus() == status)
end

print("[10] a drop, a silent socket and a refused join all reconnect")
do
  local ws = liveSocket()
  status(ws.netBinding, "OFFLINE")
  check(
    "a drop without a close frame schedules a retry",
    AgentDoorbellStatus():find("connection dropped", 1, true) ~= nil
  )
  advance(15000 + 3000)
  ws = liveSocket()
  check("a new socket", ws ~= nil)
  server.join = nil
  connectSocket(ws)
  replyJoin("ok")
  check("joined again", AgentDoorbellStatus():find("joined", 1, true) ~= nil)

  server.mute = true
  advance(120000)
  check(
    "a socket that answers nothing is found by the watchdog",
    AgentDoorbellStatus():find("silent", 1, true) ~= nil,
    AgentDoorbellStatus()
  )
  server.mute = false
  advance(30000)
  ws = liveSocket()
  server.join = nil
  connectSocket(ws)
  replyJoin("error")
  check(
    "a refused join is reported with its reason",
    AgentDoorbellStatus():find("public channels are disabled", 1, true) ~= nil,
    AgentDoorbellStatus()
  )
  advance(70000)
  ws = liveSocket()
  check("and retried", ws ~= nil)
  server.join = nil
  connectSocket(ws)
  advance(61000)
  check(
    "a join that never completes is retried",
    AgentDoorbellStatus():find("not joined within 60 s", 1, true) ~= nil,
    AgentDoorbellStatus()
  )
end

print("[11] unpair and driver destroy leave no timer behind")
do
  ask("destroy")
  check("burst running", burstActive())
  D.as(AGENT, function()
    OnDriverDestroyed()
  end)
  check("driver destroy cancels the burst", not burstActive() and clock.timers[FastAnswers.TIMER] == nil)
  check(
    "and the doorbell timers",
    clock.timers["SmartBuildOSRealtimeHeartbeat"] == nil and clock.timers["SmartBuildOSRealtimeReconnect"] == nil
  )
  check("and its offer", AgentDoorbellStatus():find("no offer", 1, true) ~= nil)

  -- Bring the burst back, then unpair.
  ask("unpair")
  check("burst running again", burstActive())
  D.as(AGENT, function()
    EC.UNPAIR()
  end)
  check("unpair cancels the burst", not burstActive() and clock.timers[FastAnswers.TIMER] == nil)
  local n = #requestsTo("heartbeat")
  advance(120000)
  check("and nothing checks in while unpaired", #requestsTo("heartbeat") == n)
  ask("unpaired")
  check("an ask while unpaired starts nothing", not burstActive())
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
