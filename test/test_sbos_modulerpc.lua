-- Module contract v2, both halves together: two module-side engines
-- (sbos.modulerpc, "ai_core" and "flight_recorder") talking through the
-- REAL Agent bus (sbos.modulebus + sbos.modules) over an asynchronous fake
-- SendToDevice. Covers the client rules: deadlines, retry only on the
-- retryable codes (2 s then 5 s, same idempotency key), target dedup on
-- request_id, token checks, paging with a cursor, local size refusals,
-- pub/sub delivery, discovery, Agent restart → re-subscribe, cloud relay
-- retries, and degradation against a v1-only Agent.
--
-- Run from the driver root: make test

package.path = "src/?.lua;vendor/?.lua;" .. package.path
require("drivers-common-public.global.lib") -- the vendored JSON's number formatting
JSON = require("JSON")
local Modules = require("sbos.modules")
local ModuleBus = require("sbos.modulebus")
local ModuleRpc = require("sbos.modulerpc")

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

-- ── virtual time + timers ────────────────────────────────────────────────────
local T = { now = 2000000, ms = 0, timers = {} }
local queue = {} -- SendToDevice is asynchronous on a controller
local function pump()
  local guard = 0
  while #queue > 0 do
    guard = guard + 1
    assert(guard < 10000, "message storm")
    local item = table.remove(queue, 1)
    item()
  end
end
local function setTimer(id, ms, fn, repeating)
  T.timers[id] = { at = T.ms + ms, fn = fn, every = repeating and ms or nil }
end
local function cancelTimer(id)
  T.timers[id] = nil
end
local function advance(seconds)
  local target = T.ms + seconds * 1000
  pump()
  while true do
    local bestId, bestAt
    for id, t in pairs(T.timers) do
      if t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and id < bestId)) then
        bestId, bestAt = id, t.at
      end
    end
    if bestId == nil then
      break
    end
    T.now = T.now + math.floor((bestAt - T.ms) / 1000)
    T.ms = bestAt
    local t = T.timers[bestId]
    if t.every then
      t.at = T.ms + t.every
    else
      T.timers[bestId] = nil
    end
    t.fn()
    pump()
  end
  T.now = T.now + math.floor((target - T.ms) / 1000)
  T.ms = target
end
local function now()
  return T.now
end

-- ── the Agent (real registry + bus; dispatch like driver.lua) ────────────────
local agent = {}
local modules = {} -- instance id -> { rpc, id, module_id, token }
local trafficToAgent = {}
local cloudAnswers = {}
local posts = {}
local tokens = 0

local function newAgent(protocolMax)
  -- The old Agent's timers die with it; the modules' own timers do not.
  for id in pairs(T.timers) do
    if id:find("^SbosModuleBus") then
      T.timers[id] = nil
    end
  end
  agent.v1 = protocolMax == 1
  agent.registry = Modules.Registry.new({
    now = now,
    newToken = function()
      tokens = tokens + 1
      return string.format("t%031d", tokens)
    end,
  })
  agent.bus = ModuleBus.new({
    registry = agent.registry,
    now = now,
    send = function(instanceId, command, params)
      local m = modules[tostring(instanceId)]
      if m then
        queue[#queue + 1] = function()
          m.deliver(command, params)
        end
      end
      return true
    end,
    cloudPost = function(body, done)
      posts[#posts + 1] = body
      local answer = table.remove(cloudAnswers, 1)
        or { ok = true, http_status = 200, body = { ok = true, result = {} } }
      queue[#queue + 1] = function()
        done(answer)
      end
    end,
    setTimer = setTimer,
    cancelTimer = cancelTimer,
    agent = function()
      return { version = "test", paired = true, connected = true }
    end,
  })
end

local AGENT_METHODS = {
  SBOS_MODULE_DISCOVER = "discover",
  SBOS_MODULE_SUBSCRIBE = "subscribe",
  SBOS_MODULE_UNSUBSCRIBE = "unsubscribe",
  SBOS_MODULE_REQUEST = "request",
  SBOS_MODULE_RESPONSE = "response",
  SBOS_MODULE_CLOUD_REQUEST = "cloudRequest",
}
local function toAgent(command, params)
  trafficToAgent[#trafficToAgent + 1] = { command = command, params = params }
  queue[#queue + 1] = function()
    if agent.v1 then
      return -- a v1 Agent has no handler for any v2 frame
    end
    local method = AGENT_METHODS[command]
    local entry = agent.registry:authenticate(params)
    if method == nil or entry == nil then
      return
    end
    agent.bus[method](agent.bus, entry, params)
  end
  return true
end

local HANDLERS = {
  SBOS_MODULE_DIRECTORY = "onDirectory",
  SBOS_MODULE_DIRECTORY_CHANGED = "onDirectoryChanged",
  SBOS_MODULE_SUBSCRIBED = "onSubscribed",
  SBOS_MODULE_PUBLISH = "onPublish",
  SBOS_MODULE_REQUEST_ACK = "onRequestAck",
  SBOS_MODULE_REQUEST = "onIncomingRequest",
  SBOS_MODULE_RESPONSE = "onResponse",
  SBOS_MODULE_CLOUD_RESPONSE = "onCloudResponse",
}

local ids = 0
local function newModule(moduleId, instanceId)
  local m = { module_id = moduleId, id = tostring(instanceId), received = {}, changed = {} }
  m.rpc = ModuleRpc.new({
    send = function(command, params)
      params.module_id = moduleId
      params.instance_id = m.id
      params.token = m.token or ""
      return toAgent(command, params)
    end,
    token = function()
      return m.token
    end,
    now = now,
    setTimer = function(id, ms, fn)
      setTimer(m.id .. ":" .. id, ms, fn)
    end,
    cancelTimer = function(id)
      cancelTimer(m.id .. ":" .. id)
    end,
    newId = function()
      ids = ids + 1
      return moduleId .. "-" .. ids
    end,
    onDirectoryChanged = function(version)
      m.changed[#m.changed + 1] = version
    end,
  })
  m.deliver = function(command, params)
    m.received[#m.received + 1] = { command = command, params = params }
    local h = HANDLERS[command]
    if h then
      m.rpc[h](m.rpc, params)
    end
  end
  modules[m.id] = m
  return m
end

local FR_MANIFEST = JSON:encode({
  driver = "sbos.flight_recorder",
  protocol = 2,
  capabilities = {
    { id = "events.query", version = 1, kind = "request" },
    { id = "events.timeline", version = 1, kind = "request" },
    { id = "events.subscribe", version = 1, kind = "topic", topics = { "capture." } },
  },
})

local function register(m, manifest, max)
  -- A v1-only Agent ran this same registry code with PROTOCOL_MAX = 1.
  local saved = Modules.PROTOCOL_MAX
  if agent.v1 then
    Modules.PROTOCOL_MAX = 1
  end
  local ok, reply, entry = agent.registry:register({
    module_id = m.module_id,
    instance_id = m.id,
    protocol_min = "1",
    protocol_max = max or "2",
    singleton = "true",
    manifest = manifest,
  })
  Modules.PROTOCOL_MAX = saved
  assert(ok, reply.reason)
  if not agent.v1 then
    agent.bus:onRegistered(entry)
  end
  m.token = reply.token
  m.rpc:onRegistered(reply.protocol)
  pump()
  return entry
end

local function countTo(command, filter)
  local n = 0
  for _, t in ipairs(trafficToAgent) do
    if t.command == command and (filter == nil or filter(t.params)) then
      n = n + 1
    end
  end
  return n
end

-- ── world ─────────────────────────────────────────────────────────────────────
newAgent(2)
local fr = newModule("flight_recorder", 501)
local ai = newModule("ai_core", 601)
register(fr, FR_MANIFEST)
register(ai, '{"driver":"sbos.ai_core","capabilities":[]}')

local EVENTS = {}
for i = 1, 7 do
  EVENTS[i] = { event_id = "fr:" .. i, n = i }
end
local queryCalls = 0
fr.rpc:onRequest("events.query", function(req, respond)
  queryCalls = queryCalls + 1
  -- two per page; cursor = next index
  local from = tonumber(req.args.cursor) or 1
  local page = {}
  for i = from, math.min(from + 1, #EVENTS) do
    page[#page + 1] = EVENTS[i]
  end
  local nextCursor = (from + 2 <= #EVENTS) and tostring(from + 2) or nil
  respond("ok", { events = page, caller = req.from_module_id }, nil, nextCursor)
end)

local function call(to, capability, args, opts)
  local answer
  ai.rpc:request(to, capability, args, opts, function(a)
    answer = a
  end)
  pump()
  return function()
    return answer
  end
end

print("[1] request round trip, sender stamped, paging with a cursor")
do
  local all, cursor, pages = {}, nil, 0
  repeat
    local got = call("flight_recorder", "events.query", { cursor = cursor })
    local a = got()
    pages = pages + 1
    if a == nil or a.status ~= "ok" then
      break
    end
    for _, e in ipairs(a.result.events) do
      all[#all + 1] = e.n
    end
    cursor = a.cursor
    if pages == 1 then
      check(
        "answer ok with the responder stamped by the Agent",
        a.from_module_id == "flight_recorder" and a.from_instance_id == "501" and a.result.caller == "ai_core"
      )
    end
  until cursor == nil or pages > 10
  check("4 pages of ≤2 walk all 7 events by cursor", pages == 4 and #all == 7 and all[7] == 7, pages)
end

print("[2] retries: only the retryable codes, 2 s then 5 s, same idempotency key")
do
  -- not_permitted: final at once
  trafficToAgent = {}
  local got = call("flight_recorder", "events.delete", {})
  check("not_permitted: one attempt, no retry", got() and got().error_code == "not_permitted" and got().attempts == 1)
  advance(10)
  check("…and nothing re-sent", countTo("SBOS_MODULE_REQUEST") == 1)
  -- capability_not_found: final
  trafficToAgent = {}
  got = call("flight_recorder", "events.timeline", {})
  -- the manifest advertises events.timeline but the driver has no handler
  advance(1)
  check(
    "target without a handler answers capability_not_found, final",
    got() and got().error_code == "capability_not_found" and got().attempts == 1
  )

  -- unknown_target (Flight Recorder not registered at all) is final
  agent.registry:remove("flight_recorder", "501")
  agent.bus:onRemoved({ module_id = "flight_recorder", instance_id = "501" })
  trafficToAgent = {}
  got = call("flight_recorder", "events.query", {})
  advance(10)
  check(
    "unknown_target: final, one attempt",
    got() and got().error_code == "unknown_target" and countTo("SBOS_MODULE_REQUEST") == 1
  )
  -- target_unavailable (registered, but only at protocol 1): retried 2 s then 5 s
  register(fr, nil, "1")
  trafficToAgent = {}
  local t0 = T.now
  got = call("flight_recorder", "events.query", {})
  check("first refusal does not complete the call", got() == nil)
  advance(1)
  check("no retry before 2 s", countTo("SBOS_MODULE_REQUEST") == 1)
  advance(1)
  check("retry 1 at +2 s", countTo("SBOS_MODULE_REQUEST") == 2)
  advance(4)
  check("no retry 2 before +5 s after retry 1", countTo("SBOS_MODULE_REQUEST") == 2)
  advance(1)
  local a = got()
  check(
    "retry 2 at +5 s, then final target_unavailable after 3 attempts",
    countTo("SBOS_MODULE_REQUEST") == 3
      and a
      and a.error_code == "target_unavailable"
      and a.attempts == 3
      and T.now - t0 == 7,
    a and a.error_code
  )
  local keys, rids = {}, {}
  for _, t in ipairs(trafficToAgent) do
    if t.command == "SBOS_MODULE_REQUEST" then
      keys[t.params.idempotency_key] = true
      rids[t.params.request_id] = true
    end
  end
  local nk, nr = 0, 0
  for _ in pairs(keys) do
    nk = nk + 1
  end
  for _ in pairs(rids) do
    nr = nr + 1
  end
  check("same idempotency key on every attempt, a fresh request_id each time", nk == 1 and nr == 3)
  register(fr, FR_MANIFEST)
end

print("[3] deadline_exceeded: the requester's own timer, then retried")
do
  local silent = 0
  fr.rpc:onRequest("events.timeline", function()
    silent = silent + 1 -- never answers
  end)
  trafficToAgent = {}
  local got = call("flight_recorder", "events.timeline", {}, { timeout = 3 })
  advance(3)
  check("deadline_exceeded at the deadline (not final yet: retryable)", got() == nil and silent == 1)
  advance(2)
  check("retried with the same key after the first deadline: re-routed by the Agent", silent == 2)
  advance(3 + 5 + 3)
  local a = got()
  check(
    "final deadline_exceeded after 3 attempts",
    a and a.error_code == "deadline_exceeded" and a.attempts == 3 and silent == 3
  )
  check("timeouts counted", ai.rpc.counters.timeouts == 3)
  fr.rpc:onRequest("events.timeline", nil)
end

print("[4] a retried call that then succeeds; the stored answer is replayed, not re-run")
do
  local n = 0
  fr.rpc:onRequest("events.timeline", function(_, respond)
    n = n + 1
    if n == 1 then
      respond("error", nil, "rate_limited")
    else
      respond("ok", { attempt = n })
    end
  end)
  local got = call("flight_recorder", "events.timeline", {}, { idempotency_key = "same-key" })
  advance(2)
  local a = got()
  check(
    "rate_limited from the target is retried, then ok",
    a and a.status == "ok" and a.attempts == 2 and a.result.attempt == 2
  )
  got = call("flight_recorder", "events.timeline", {}, { idempotency_key = "same-key" })
  advance(1)
  a = got()
  check(
    "a new call with the same key gets the stored answer without running the handler",
    a and a.status == "ok" and a.replayed == true and a.result.attempt == 2 and n == 2
  )
end

print("[5] target dedup on request_id, token checks")
do
  local before = queryCalls
  local frame = {
    module_id = "flight_recorder",
    instance_id = "501",
    token = fr.token,
    request_id = "dup-1",
    idempotency_key = "dup-1",
    from_module_id = "ai_core",
    from_instance_id = "601",
    capability = "events.query",
    args = "{}",
    deadline = tostring(T.now + 10),
  }
  trafficToAgent = {}
  fr.deliver("SBOS_MODULE_REQUEST", frame)
  fr.deliver("SBOS_MODULE_REQUEST", frame)
  check(
    "a duplicated frame re-sends the stored answer and does not re-run the handler",
    queryCalls == before + 1 and countTo("SBOS_MODULE_RESPONSE") == 2 and fr.rpc.counters.served_duplicates == 1
  )
  local forged = {}
  for k, v in pairs(frame) do
    forged[k] = v
  end
  forged.request_id = "forged-1"
  forged.token = "not-the-token"
  fr.deliver("SBOS_MODULE_REQUEST", forged)
  check(
    "a REQUEST without this module's token is ignored",
    queryCalls == before + 1 and fr.rpc.counters.ignored_frames >= 1
  )
  fr.rpc:onRequest("events.timeline", function() end) -- never answers
  local got = call("flight_recorder", "events.timeline", {}, { timeout = 5, retries = 0 })
  local pending = next(ai.rpc.calls)
  check("(a call is pending)", got() == nil and pending ~= nil)
  ai.deliver("SBOS_MODULE_RESPONSE", { token = "forged", request_id = pending, status = "ok", result = '{"fake":1}' })
  ai.deliver(
    "SBOS_MODULE_REQUEST_ACK",
    { token = "forged", request_id = pending, state = "Refused", error_code = "not_permitted" }
  )
  check("a forged RESPONSE / ACK does not complete the caller's request", got() == nil)
  ai.deliver("SBOS_MODULE_RESPONSE", { token = ai.token, request_id = pending, status = "ok", result = '{"real":1}' })
  check("the same frame with the right token does", got() and got().status == "ok" and got().result.real == 1)
end

print("[6] local limits: oversize never leaves the driver")
do
  trafficToAgent = {}
  local got = call("flight_recorder", "events.query", { blob = string.rep("x", 17 * 1024) })
  check(
    "args > 16 KB → payload_too_large locally",
    got() and got().error_code == "payload_too_large" and #trafficToAgent == 0
  )
  local cloudA
  ai.rpc:cloudRequest("ask", { blob = string.rep("x", 17 * 1024) }, {}, function(a)
    cloudA = a
  end)
  check(
    "cloud body > 16 KB → payload_too_large locally",
    cloudA and cloudA.error_code == "payload_too_large" and #trafficToAgent == 0
  )
  got = call("flight_recorder", "Bad Capability", {})
  check("malformed capability → invalid_args locally", got() and got().error_code == "invalid_args")
  fr.rpc:onRequest("events.timeline", function(_, respond)
    respond("ok", { blob = string.rep("y", 25 * 1024) })
  end)
  got = call("flight_recorder", "events.timeline", {})
  advance(1)
  check("result > 24 KB → payload_too_large (target side)", got() and got().error_code == "payload_too_large")
  fr.rpc:onRequest("events.timeline", function()
    error("boom")
  end)
  got = call("flight_recorder", "events.timeline", {})
  advance(1)
  check("a handler that throws → internal_error", got() and got().error_code == "internal_error")
end

print("[7] discovery and directory changes")
do
  local dir, code
  ai.rpc:discover({ capability = "events.query" }, function(d, c)
    dir, code = d, c
  end)
  pump()
  check(
    "discover returns the directory filtered by capability",
    code == "ok"
      and dir
      and #dir.modules == 1
      and dir.modules[1].module_id == "flight_recorder"
      and dir.agent.protocol_max == 2
  )
  ai.changed = {}
  local venue = newModule("venueflow", 701)
  register(venue, '{"capabilities":[]}')
  advance(5)
  check("a registration pushes DIRECTORY_CHANGED (debounced)", #ai.changed == 1)
end

print("[8] pub/sub delivery")
do
  local got, dropped = {}, nil
  local okS = ai.rpc:subscribe("fr-capture", { "capture." }, function(events, d)
    for _, e in ipairs(events) do
      got[#got + 1] = e
    end
    dropped = d
  end)
  pump()
  check("subscribe accepted locally and granted", okS and ai.rpc.subs["fr-capture"].state == "active")
  local okBad, why = ai.rpc:subscribe("x", {}, function() end)
  check("an empty topic list refused locally", okBad == false and why == "invalid_args")
  local entry = agent.registry:find("flight_recorder", "501")
  agent.bus:offer(
    { event_id = "e1", event_type = "capture.device", module_id = "flight_recorder", payload = {} },
    entry
  )
  advance(1)
  check("published envelope delivered to onEvents", #got == 1 and got[1].event_id == "e1" and dropped == 0)
  check("received counted", ai.rpc.counters.published_received == 1)
end

print("[9] Agent restart: in-flight fails target_unavailable; re-register re-subscribes")
do
  fr.rpc:onRequest("events.timeline", function() end) -- never answers
  local got = call("flight_recorder", "events.timeline", {}, { timeout = 4, retries = 0 })
  local oldToken = ai.token
  -- The Agent restarts: a brand-new registry and bus (tokens, routes and
  -- subscriptions are gone), then its hello reaches every module.
  newAgent(2)
  fr.rpc:onAgentHello()
  ai.rpc:onAgentHello()
  advance(4)
  check(
    "the in-flight request fails target_unavailable at its deadline",
    got() and got().error_code == "target_unavailable"
  )
  trafficToAgent = {}
  register(fr, FR_MANIFEST)
  register(ai, '{"capabilities":[]}')
  check("re-registration re-sends the subscription", countTo("SBOS_MODULE_SUBSCRIBE") == 1)
  local seen = 0
  ai.rpc.subs["fr-capture"].onEvents = function(events)
    seen = seen + #events
  end
  agent.bus:offer(
    { event_id = "e2", event_type = "capture.x", module_id = "flight_recorder", payload = {} },
    agent.registry:find("flight_recorder", "501")
  )
  advance(1)
  check("delivery resumes on the new Agent", seen == 1)
  check("the token rotated on re-registration", ai.token ~= oldToken)
  ai.deliver("SBOS_MODULE_PUBLISH", {
    token = oldToken,
    subscription_id = "fr-capture",
    events = '[{"event_id":"stale"}]',
    dropped = "0",
  })
  check("a frame carrying the pre-restart token is ignored", seen == 1)
end

print("[10] cloud relay through the Agent: retry on cloud_unreachable, final on cloud_refused")
do
  posts = {}
  cloudAnswers = {
    { ok = false, reason = "unreachable" },
    { ok = true, http_status = 200, body = { ok = true, result = { accepted = true, job_id = "j9" } } },
  }
  local a
  ai.rpc:cloudRequest("ask", { q = "hi" }, { idempotency_key = "ask-1" }, function(x)
    a = x
  end)
  pump()
  check("first attempt cloud_unreachable is not final", a == nil and #posts == 1)
  advance(2)
  check(
    "retried with the same key, then ok",
    a
      and a.status == "ok"
      and a.result.job_id == "j9"
      and a.attempts == 2
      and #posts == 2
      and posts[1].idempotency_key == "ask-1"
      and posts[2].idempotency_key == "ask-1"
      and posts[1].request_id ~= posts[2].request_id
  )
  cloudAnswers = { { ok = false, http_status = 403 } }
  a = nil
  ai.rpc:cloudRequest("ask", {}, {}, function(x)
    a = x
  end)
  pump()
  advance(10)
  check("cloud_refused is final", a and a.error_code == "cloud_refused" and a.attempts == 1 and a.http_status == 403)
  a = nil
  ai.rpc:cloudRequest("delete_everything", {}, {}, function(x)
    a = x
  end)
  pump()
  check(
    "an op outside MODULE_CLOUD_OPS → not_permitted, final",
    a and a.error_code == "not_permitted" and a.attempts == 1
  )
end

print("[11] a v2 client against a v1-only Agent degrades, never crashes")
do
  newAgent(1)
  local old = newModule("ai_core", 602)
  local okR, entry = pcall(register, old, '{"capabilities":[]}', "2")
  check(
    "registration still succeeds, negotiated to 1 (v1 services)",
    okR and entry.protocol == 1 and old.rpc.protocol == 1
  )
  check("the v1 Agent stored no manifest", entry.manifest == nil)
  local a
  old.rpc:request("flight_recorder", "events.query", {}, {}, function(x)
    a = x
  end)
  check(
    "request → incompatible_protocol, at once, no frame",
    a and a.error_code == "incompatible_protocol" and a.attempts == 1
  )
  local dcode
  old.rpc:discover(nil, function(_, c)
    dcode = c
  end)
  check("discover → incompatible_protocol", dcode == "incompatible_protocol")
  check(
    "subscribe is kept as desired state but not sent",
    old.rpc:subscribe("s", { "capture." }, function() end) == true and old.rpc.subs.s.state == "pending"
  )
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
