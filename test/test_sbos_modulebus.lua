-- Module contract v2, the Agent half (sbos.modulebus) with the real registry
-- (sbos.modules) and policy (sbos.modulepolicy): manifest + tokens,
-- discovery, pub/sub fan-out, request routing, idempotency, deadlines,
-- rate limits and the cloud relay. Transport, timers and clock are fakes.
--
-- Run from the driver root: make test

package.path = "src/?.lua;vendor/?.lua;" .. package.path
require("drivers-common-public.global.lib") -- the vendored JSON's number formatting
JSON = require("JSON")
local Modules = require("sbos.modules")
local Policy = require("sbos.modulepolicy")
local ModuleBus = require("sbos.modulebus")

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

-- ── harness ───────────────────────────────────────────────────────────────────
local T = { now = 1000000, ms = 0, timers = {} }
local function now()
  return T.now
end
local function setTimer(id, ms, fn, repeating)
  T.timers[id] = { at = T.ms + ms, fn = fn, every = repeating and ms or nil }
end
local function cancelTimer(id)
  T.timers[id] = nil
end
local function advance(seconds)
  local target = T.ms + seconds * 1000
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
  end
  T.now = T.now + math.floor((target - T.ms) / 1000)
  T.ms = target
end

local sent = {}
local posts = {}
local cloudAnswer = nil -- function(body) -> res ; nil = hold the call
local heldPosts = {}
local paired = true
local tokens = 0

local function fresh()
  sent, posts, heldPosts = {}, {}, {}
  T.timers = {}
  local registry = Modules.Registry.new({
    now = now,
    newToken = function()
      tokens = tokens + 1
      return string.format("tok%028d", tokens)
    end,
  })
  local bus = ModuleBus.new({
    registry = registry,
    now = now,
    send = function(id, command, params)
      sent[#sent + 1] = { to = tostring(id), command = command, params = params }
      return true
    end,
    cloudPost = function(body, done)
      posts[#posts + 1] = body
      if cloudAnswer then
        done(cloudAnswer(body))
      else
        heldPosts[#heldPosts + 1] = done
      end
    end,
    setTimer = setTimer,
    cancelTimer = cancelTimer,
    agent = function()
      return { version = "20261118.120000", paired = paired, connected = true }
    end,
  })
  return registry, bus
end

local function of(command, to)
  local out = {}
  for _, s in ipairs(sent) do
    if s.command == command and (to == nil or s.to == tostring(to)) then
      out[#out + 1] = s
    end
  end
  return out
end
local function last(command, to)
  local list = of(command, to)
  return list[#list]
end

local FR_MANIFEST = JSON:encode({
  driver = "sbos.flight_recorder",
  version = "20261118.120000",
  protocol = 2,
  capabilities = {
    { id = "events.query", version = 1, kind = "request" },
    { id = "events.timeline", version = 1, kind = "request" },
    { id = "events.subscribe", version = 1, kind = "topic", topics = { "capture.", "observation.", "trace." } },
  },
})
local AI_MANIFEST = JSON:encode({ driver = "sbos.ai_core", version = "1", protocol = 2, capabilities = {} })

local function register(registry, bus, p)
  local params = {
    module_id = p.module_id,
    instance_id = p.instance_id,
    driver_version = "1",
    protocol_min = p.min or "1",
    protocol_max = p.max or "2",
    singleton = "true",
    manifest = p.manifest,
  }
  local ok, reply, entry = registry:register(params)
  if ok then
    bus:onRegistered(entry)
  end
  return ok, reply, entry
end

local function setup()
  local registry, bus = fresh()
  local _, _, fr = register(registry, bus, { module_id = "flight_recorder", instance_id = "501", manifest = FR_MANIFEST })
  local _, _, ai = register(registry, bus, { module_id = "ai_core", instance_id = "601", manifest = AI_MANIFEST })
  sent = {}
  return registry, bus, fr, ai
end

local reqSeq = 0
local function req(bus, from, over)
  reqSeq = reqSeq + 1
  local p = {
    request_id = "r-" .. reqSeq,
    idempotency_key = "k-" .. reqSeq,
    to = "flight_recorder",
    capability = "events.query",
    args = '{"limit":5}',
    deadline = tostring(T.now + 10),
  }
  for k, v in pairs(over or {}) do
    p[k] = v
  end
  bus:request(from, p)
  return p
end

-- ─────────────────────────────────────────────────────────────────────────────
print("[1] vocabulary: closed error codes, retryable set, policy for ai_core")
do
  local expected = {
    "ok",
    "invalid_frame",
    "incompatible_protocol",
    "unknown_target",
    "target_unavailable",
    "capability_not_found",
    "not_permitted",
    "invalid_args",
    "payload_too_large",
    "deadline_exceeded",
    "duplicate_request",
    "rate_limited",
    "agent_not_paired",
    "cloud_unreachable",
    "cloud_refused",
    "unsupported",
    "internal_error",
  }
  local n = 0
  for _ in pairs(Policy.ERRORS) do
    n = n + 1
  end
  local all = true
  for _, c in ipairs(expected) do
    all = all and Policy.ERRORS[c] == true
  end
  check("exactly the 17 codes of ARCHITECTURE §4.4", all and n == 17, n)
  check("an unknown code normalises to internal_error", Policy.code("boom") == "internal_error")
  local r = Policy.RETRYABLE
  check(
    "retryable = deadline_exceeded, target_unavailable, rate_limited, cloud_unreachable only",
    r.deadline_exceeded and r.target_unavailable and r.rate_limited and r.cloud_unreachable
      and not r.not_permitted and not r.invalid_args and not r.capability_not_found and not r.cloud_refused
  )
  check("retry delays 2 s then 5 s", Policy.RETRY_DELAYS[1] == 2 and Policy.RETRY_DELAYS[2] == 5 and #Policy.RETRY_DELAYS == 2)
  check("protocol 1..2", Policy.PROTOCOL_MIN == 1 and Policy.PROTOCOL_MAX == 2 and Modules.PROTOCOL_MAX == 2)
  local ops = Policy.CLOUD_OPS.ai_core
  check(
    "MODULE_CLOUD_OPS.ai_core is the closed list of ARCHITECTURE §5",
    ops.ask and ops.analyze_room and ops.analyze_system and ops.learn_preference and ops.suggest_scene
      and ops.generate_report and ops.start_diagnostic and ops.send_notification and ops.set_context
      and ops.status and ops.test_provider and not ops.proxy
  )
  check(
    "ai_core may call Flight Recorder's events.* capabilities",
    Policy.REQUEST_POLICY["events.query"].requesters.ai_core
      and Policy.REQUEST_POLICY["events.timeline"].requesters.ai_core
      and Policy.REQUEST_POLICY["events.device_history"].requesters.ai_core
      and Policy.REQUEST_POLICY["events.room_activity"].requesters.ai_core
      and Policy.REQUEST_POLICY["events.query"].provider == "flight_recorder"
  )
  check(
    "ai_core may subscribe to capture. / observation. / trace.",
    Policy.topicAllowed(Policy.TOPIC_POLICY, "ai_core", "capture.")
      and Policy.topicAllowed(Policy.TOPIC_POLICY, "ai_core", "observation.change")
      and Policy.topicAllowed(Policy.TOPIC_POLICY, "ai_core", "trace.")
      and not Policy.topicAllowed(Policy.TOPIC_POLICY, "ai_core", "usage.")
      and not Policy.topicAllowed(Policy.TOPIC_POLICY, "usage_analytics", "capture.")
  )
end

print("[2] registration: v1/v2 matrix, manifest stored, tokens")
do
  local registry, bus = fresh()
  local ok1, r1, e1 = register(registry, bus, { module_id = "usage_analytics", instance_id = "701", max = "1", manifest = FR_MANIFEST })
  check("v1 module (1..1) negotiates 1 with the v2 Agent", ok1 and r1.protocol == "1")
  check("a v1 registration stores no manifest even if one is sent", e1.manifest == nil)
  local ok2, r2, e2 = register(registry, bus, { module_id = "flight_recorder", instance_id = "501", manifest = FR_MANIFEST })
  check("v2 module (1..2) negotiates 2", ok2 and r2.protocol == "2")
  check(
    "manifest stored, bounded and typed",
    e2.manifest ~= nil
      and e2.manifest.driver == "sbos.flight_recorder"
      and #e2.manifest.capabilities == 3
      and Modules.findCapability(e2, "events.query", "request") ~= nil
      and Modules.findCapability(e2, "events.subscribe", "topic").topics[2] == "observation."
  )
  local ok3, r3 = register(registry, bus, { module_id = "ai_core", instance_id = "601", min = "2", max = "2", manifest = "{" })
  check("v2-only module (2..2) registers, bad manifest reported, not fatal", ok3 and r3.manifest_error == "invalid_manifest")
  local ok4, r4 = registry:register({ module_id = "home_state", instance_id = "801", protocol_min = "3", protocol_max = "3" })
  check(
    "v3-only module refused with the Agent's range",
    not ok4 and r4.reason == "incompatible_protocol" and r4.agent_protocol_max == "2"
  )
  local big = JSON:encode({ capabilities = { { id = "x.y", topics = { string.rep("a", 3000) } } } })
  check("manifest over 2 KB refused", select(2, Modules.parseManifest(big)) == "manifest_too_large")
  check(
    "a topic capability without topics refused",
    select(2, Modules.parseManifest('{"capabilities":[{"id":"events.subscribe","kind":"topic"}]}')) == "invalid_capability"
  )
  check(
    "an unknown capability kind refused",
    select(2, Modules.parseManifest('{"capabilities":[{"id":"events.query","kind":"shell"}]}')) == "invalid_capability"
  )
  local uuidC4 = {
    UUID = function(_, kind)
      return kind == "RANDOM" and "6F9619FF-8B86-D011-B42D-00CF4FC964FF" or nil
    end,
  }
  check(
    "token from C4:UUID(\"RANDOM\"): 32 lowercase hex",
    Modules.token(uuidC4, function()
      return "fallback"
    end) == "6f9619ff8b86d011b42d00cf4fc964ff"
  )
  check(
    "token falls back to the v1 generator when UUID is absent or not a UUID",
    Modules.token({
      UUID = function()
        return "RANDOM-1-2"
      end,
    }, function()
      return "fallback"
    end) == "fallback" and Modules.token(nil, function()
      return "fallback"
    end) == "fallback"
  )
end

print("[3] discovery: directory, filter, register/unregister/stale, debounced change push")
do
  local registry, bus, fr, ai = setup()
  bus:discover(ai, { request_id = "d1" })
  local d = last("SBOS_MODULE_DIRECTORY", 601)
  local mods = d and JSON:decode(d.params.modules) or {}
  local agent = d and JSON:decode(d.params.agent) or {}
  check("answer goes to the requester with its token", d ~= nil and d.params.token == ai.token and d.params.error_code == "ok")
  check(
    "directory lists both modules with manifests, never tokens",
    #mods == 2 and mods[1].module_id == "ai_core" and mods[2].module_id == "flight_recorder"
      and #mods[2].capabilities == 3 and mods[2].token == nil and d.params.modules:find(fr.token, 1, true) == nil
  )
  check(
    "agent block: version, protocol range, paired, connected",
    agent.protocol_min == 1 and agent.protocol_max == 2 and agent.paired == true and agent.version == "20261118.120000"
  )
  bus:discover(ai, { request_id = "d2", filter = '{"capability":"events.timeline"}' })
  mods = JSON:decode(last("SBOS_MODULE_DIRECTORY").params.modules)
  check("filter by capability", #mods == 1 and mods[1].module_id == "flight_recorder")
  bus:discover(ai, { request_id = "d3", filter = "{nope" })
  check("bad filter → invalid_args", last("SBOS_MODULE_DIRECTORY").params.error_code == "invalid_args")

  -- debounced change push
  sent = {}
  register(registry, bus, { module_id = "usage_analytics", instance_id = "701", max = "1" })
  register(registry, bus, { module_id = "venueflow", instance_id = "702", max = "2" })
  check("nothing pushed before the debounce", #of("SBOS_MODULE_DIRECTORY_CHANGED") == 0)
  advance(5)
  local pushes = of("SBOS_MODULE_DIRECTORY_CHANGED")
  check(
    "one push per live v2 module after 5 s (v1 modules get none)",
    #pushes == 3 and #of("SBOS_MODULE_DIRECTORY_CHANGED", 701) == 0,
    #pushes
  )
  check("push carries the recipient's token", last("SBOS_MODULE_DIRECTORY_CHANGED", 601).params.token == ai.token)
  bus:discover(ai, { request_id = "d4" })
  check("registration reflected", #JSON:decode(last("SBOS_MODULE_DIRECTORY").params.modules) == 4)

  -- unregister
  registry:remove("venueflow", "702")
  bus:onRemoved({ module_id = "venueflow", instance_id = "702" })
  sent = {}
  advance(5)
  check("unregister pushes a change", #of("SBOS_MODULE_DIRECTORY_CHANGED", 601) == 1)
  bus:discover(ai, { request_id = "d5" })
  check("unregistration reflected", #JSON:decode(last("SBOS_MODULE_DIRECTORY").params.modules) == 3)

  -- stale: flight recorder stops talking; ai_core keeps touching
  sent = {}
  for _ = 1, 16 do
    registry:touch(ai, {})
    advance(60)
  end
  check(
    "a module going stale pushes a change",
    #of("SBOS_MODULE_DIRECTORY_CHANGED", 601) >= 1,
    #of("SBOS_MODULE_DIRECTORY_CHANGED", 601)
  )
  registry:touch(ai, {})
  bus:discover(ai, { request_id = "d6" })
  local stale = nil
  for _, m in ipairs(JSON:decode(last("SBOS_MODULE_DIRECTORY").params.modules)) do
    if m.module_id == "flight_recorder" then
      stale = m.stale
    end
  end
  check("stale reflected in the directory", stale == true)

  local _, _, v1 = register(registry, bus, { module_id = "usage_analytics", instance_id = "701", max = "1" })
  bus:discover(v1, { request_id = "d7" })
  check("a v1-negotiated module gets incompatible_protocol", last("SBOS_MODULE_DIRECTORY", 701).params.error_code == "incompatible_protocol")
end

print("[4] pub/sub: policy, fan-out of accepted envelopes, bounded buffer")
do
  local registry, bus, fr, ai = setup()
  local function env(n, t)
    return {
      event_id = "flight_recorder:501:nb:" .. n,
      event_type = t or "capture.device",
      module_id = "flight_recorder",
      source_driver_instance_id = "501",
      payload = { n = n },
    }
  end
  bus:subscribe(ai, { subscription_id = "s1", topics = '["capture.","observation.change","usage."]' })
  local s = last("SBOS_MODULE_SUBSCRIBED", 601)
  local granted = JSON:decode(s.params.granted)
  local refused = JSON:decode(s.params.refused)
  check("partial grant: allowed topics granted, others refused", s.params.ok == "true" and #granted == 2 and refused[1] == "usage.")
  check("partial grant reason is not_permitted", s.params.reason == "not_permitted")
  local _, _, usage = register(registry, bus, { module_id = "usage_analytics", instance_id = "701", manifest = AI_MANIFEST })
  bus:subscribe(usage, { subscription_id = "u1", topics = '["capture."]' })
  check(
    "subscription refused by policy",
    last("SBOS_MODULE_SUBSCRIBED", 701).params.ok == "false" and last("SBOS_MODULE_SUBSCRIBED", 701).params.reason == "not_permitted"
  )
  local many = {}
  for i = 1, 17 do
    many[i] = "capture." .. i
  end
  bus:subscribe(ai, { subscription_id = "s2", topics = JSON:encode(many) })
  check("more than 16 topics → invalid_args", last("SBOS_MODULE_SUBSCRIBED", 601).params.reason == "invalid_args")
  bus:subscribe(ai, { subscription_id = "s3", topics = '["Capture;drop"]' })
  check("malformed topic → invalid_args", last("SBOS_MODULE_SUBSCRIBED", 601).params.reason == "invalid_args")

  sent = {}
  bus:offer(env(1), fr)
  bus:offer(env(2, "observation.change"), fr)
  bus:offer(env(3, "observation.initial"), fr) -- not subscribed (only observation.change)
  bus:offer(env(4, "trace.step"), fr) -- not subscribed
  check("nothing sent before the publish delay", #of("SBOS_MODULE_PUBLISH") == 0)
  advance(1)
  local pub = last("SBOS_MODULE_PUBLISH", 601)
  local events = pub and JSON:decode(pub.params.events) or {}
  check(
    "fan-out of matching envelopes only, to the subscriber, with its token",
    pub ~= nil and #events == 2 and events[1].payload.n == 1 and events[2].payload.n == 2
      and pub.params.token == ai.token and pub.params.subscription_id == "s1" and pub.params.dropped == "0"
  )
  check("never echoed to the emitting instance", #of("SBOS_MODULE_PUBLISH", 501) == 0)

  sent = {}
  for i = 1, 230 do
    bus:offer(env(100 + i), fr)
  end
  advance(1)
  local frames = of("SBOS_MODULE_PUBLISH", 601)
  local total, biggest = 0, 0
  for _, f in ipairs(frames) do
    local n = #JSON:decode(f.params.events)
    total = total + n
    biggest = math.max(biggest, n)
  end
  check("buffer bounded at 200 (drop-oldest)", total == 200, total)
  check("frames carry at most 25 envelopes", biggest == 25 and #frames == 8, #frames)
  check(
    "the drop count travels on the next frame and is counted",
    frames[1].params.dropped == "30" and frames[2].params.dropped == "0" and bus:health().dropped == 30
  )
  check("oldest dropped: first delivered is #31", JSON:decode(frames[1].params.events)[1].payload.n == 131)
  check("published counter", bus:health().published == 202 and bus:moduleCounters("ai_core", "601").published == 202)

  bus:unsubscribe(ai, { subscription_id = "s1" })
  sent = {}
  bus:offer(env(999), fr)
  advance(1)
  check("unsubscribe stops delivery", #of("SBOS_MODULE_PUBLISH") == 0)

  bus:subscribe(ai, { subscription_id = "s1", topics = '["capture."]' })
  register(registry, bus, { module_id = "ai_core", instance_id = "601", manifest = AI_MANIFEST })
  sent = {}
  bus:offer(env(1000), fr)
  advance(1)
  check("re-registration drops the old session's subscriptions", #of("SBOS_MODULE_PUBLISH") == 0)
end

print("[5] request/response: routed, stamped, answered")
do
  local _, bus, fr, ai = setup()
  local p = req(bus, ai, { from_module_id = "flight_recorder", from_instance_id = "501", token = "forged" })
  local ack = last("SBOS_MODULE_REQUEST_ACK", 601)
  local fwd = last("SBOS_MODULE_REQUEST", 501)
  check("ack Routed to the requester", ack and ack.params.state == "Routed" and ack.params.error_code == "ok")
  check(
    "forwarded to the target with ITS token",
    fwd and fwd.params.token == fr.token and fwd.params.module_id == "flight_recorder" and fwd.params.instance_id == "501"
  )
  check(
    "sender stamped by the Agent: forged from_* in the frame is not forwarded",
    fwd.params.from_module_id == "ai_core" and fwd.params.from_instance_id == "601",
    fwd.params.from_module_id
  )
  check(
    "request fields carried verbatim",
    fwd.params.request_id == p.request_id and fwd.params.idempotency_key == p.idempotency_key
      and fwd.params.capability == "events.query" and fwd.params.args == '{"limit":5}' and fwd.params.deadline == p.deadline
  )
  bus:response(ai, { request_id = p.request_id, status = "ok", result = '{"fake":true}' })
  check("a response from an instance the request was NOT routed to is ignored", #of("SBOS_MODULE_RESPONSE") == 0)
  bus:response(fr, { request_id = p.request_id, status = "ok", result = '{"events":[1,2]}', cursor = "c2", from_module_id = "usage_analytics" })
  local resp = last("SBOS_MODULE_RESPONSE", 601)
  check(
    "response relayed to the requester with the responder stamped",
    resp and resp.params.status == "ok" and resp.params.result == '{"events":[1,2]}' and resp.params.cursor == "c2"
      and resp.params.from_module_id == "flight_recorder" and resp.params.from_instance_id == "501"
      and resp.params.token == ai.token
  )
  bus:response(fr, { request_id = p.request_id, status = "ok", result = "{}" })
  check("a second answer for the same request is ignored", #of("SBOS_MODULE_RESPONSE") == 1)
  check("routing state released", bus:health().inflight == 0)

  -- duplicate idempotency key: stored answer, not re-routed
  sent = {}
  req(bus, ai, { request_id = "r-again", idempotency_key = p.idempotency_key })
  check("duplicate key is not re-routed", #of("SBOS_MODULE_REQUEST", 501) == 0)
  local replay = last("SBOS_MODULE_RESPONSE", 601)
  check(
    "duplicate key returns the stored answer under the new request id",
    replay and replay.params.request_id == "r-again" and replay.params.result == '{"events":[1,2]}'
      and replay.params.replayed == "true" and last("SBOS_MODULE_REQUEST_ACK").params.error_code == "duplicate_request"
  )
  check("replay counted", bus:health().replayed == 1)

  -- in-flight duplicate
  sent = {}
  local q = req(bus, ai)
  req(bus, ai, { request_id = "r-dup", idempotency_key = q.idempotency_key })
  check(
    "a concurrent duplicate is refused duplicate_request",
    last("SBOS_MODULE_REQUEST_ACK").params.request_id == "r-dup"
      and last("SBOS_MODULE_REQUEST_ACK").params.error_code == "duplicate_request"
      and #of("SBOS_MODULE_REQUEST", 501) == 1
  )
  req(bus, ai, { request_id = q.request_id, idempotency_key = "other" })
  check("a reused request_id is refused duplicate_request", last("SBOS_MODULE_REQUEST_ACK").params.error_code == "duplicate_request")

  -- an error answer from the target that is retryable is not stored
  bus:response(fr, { request_id = q.request_id, status = "error", error_code = "rate_limited" })
  sent = {}
  req(bus, ai, { request_id = "r-retry", idempotency_key = q.idempotency_key })
  check("a retryable target error is not replayed: the retry is routed", #of("SBOS_MODULE_REQUEST", 501) == 1)
  bus:response(fr, { request_id = "r-retry", status = "error", error_code = "not_a_code" })
  check("an unknown error code is normalised", last("SBOS_MODULE_RESPONSE", 601).params.error_code == "internal_error")

  -- result too large
  local big = req(bus, ai)
  bus:response(fr, { request_id = big.request_id, status = "ok", result = JSON:encode({ s = string.rep("x", 25 * 1024) }) })
  check("result over 24 KB → payload_too_large", last("SBOS_MODULE_RESPONSE", 601).params.error_code == "payload_too_large")
end

print("[6] request refusals")
do
  local registry, bus, _, ai = setup()
  local function refusal(over, who)
    sent = {}
    req(bus, who or ai, over)
    local a = last("SBOS_MODULE_REQUEST_ACK")
    return a and a.params.state == "Refused" and a.params.error_code, #of("SBOS_MODULE_REQUEST", 501)
  end
  local _, _, usage = register(registry, bus, { module_id = "usage_analytics", instance_id = "701", manifest = AI_MANIFEST })
  local code, forwarded = refusal({}, usage)
  check("refused by policy (requester not listed)", code == "not_permitted" and forwarded == 0, code)
  check("unlisted capability → not_permitted", refusal({ capability = "events.delete" }) == "not_permitted")
  check("unknown target", refusal({ to = "guardian" }) == "unknown_target")
  check("unknown target instance", refusal({ to_instance = "999" }) == "unknown_target")
  check("wrong provider for the capability → capability_not_found", refusal({ to = "usage_analytics" }) == "capability_not_found")
  check("capability not in the target's manifest", refusal({ capability = "events.device_history" }) == "capability_not_found")
  check("oversize args (> 16 KB)", refusal({ args = JSON:encode({ s = string.rep("y", 17 * 1024) }) }) == "payload_too_large")
  check("args not a JSON object", refusal({ args = "[[" }) == "invalid_args")
  check("deadline already passed", refusal({ deadline = tostring(T.now - 1) }) == "deadline_exceeded")
  check("deadline beyond now + 60", refusal({ deadline = tostring(T.now + 61) }) == "invalid_args")
  check("missing deadline", refusal({ deadline = "" }) == "invalid_frame")
  check("malformed request id", refusal({ request_id = "bad id!" }) == "invalid_frame")
  -- target absent: registered but stale
  for _ = 1, 16 do
    registry:touch(ai, {})
    advance(60)
  end
  registry:touch(ai, {})
  check("target registered but stale → target_unavailable", refusal({}) == "target_unavailable")
  register(registry, bus, { module_id = "flight_recorder", instance_id = "501", max = "1" })
  check("target registered at protocol 1 → target_unavailable", refusal({}) == "target_unavailable")
  local _, _, v1ai = register(registry, bus, { module_id = "ai_core", instance_id = "601", max = "1" })
  check("requester at protocol 1 → incompatible_protocol", refusal({}, v1ai) == "incompatible_protocol")
  check("refusals counted", bus:health().refused >= 13 and bus:moduleCounters("ai_core", "601").refused >= 12)
end

print("[7] deadlines and routing-state cleanup")
do
  local _, bus, fr, ai = setup()
  local p = req(bus, ai, { deadline = tostring(T.now + 3) })
  check("routed", bus:health().inflight == 1)
  advance(5)
  check("still held until deadline + 5 s", bus:health().inflight == 1)
  advance(5)
  check("dropped after deadline + 5 s, counted as a timeout", bus:health().inflight == 0 and bus:health().timeouts == 1)
  sent = {}
  bus:response(fr, { request_id = p.request_id, status = "ok", result = "{}" })
  check("a late answer after cleanup is not relayed", #of("SBOS_MODULE_RESPONSE") == 0)
  -- retry with the same key after the first attempt's deadline: abandoned, re-routed
  local q = req(bus, ai, { deadline = tostring(T.now + 2) })
  advance(4) -- past its deadline, inside the grace
  sent = {}
  req(bus, ai, { request_id = "r-retry2", idempotency_key = q.idempotency_key })
  check("a retry after the deadline (same key) is routed again", #of("SBOS_MODULE_REQUEST", 501) == 1)
  -- target unregisters: in-flight answered at once
  local r = req(bus, ai)
  sent = {}
  bus:onRemoved(fr)
  local answered = {}
  for _, f in ipairs(of("SBOS_MODULE_RESPONSE", 601)) do
    answered[f.params.request_id] = f.params.error_code
  end
  check(
    "target unregistering fails ALL its in-flight requests with target_unavailable",
    answered[r.request_id] == "target_unavailable" and answered["r-retry2"] == "target_unavailable"
      and bus:health().inflight == 0
  )
end

print("[8] rate limits: 30 requests/min, burst 10, per module")
do
  local _, bus, _, ai = setup()
  local codes = {}
  for i = 1, 12 do
    sent = {}
    req(bus, ai, { idempotency_key = "rl-" .. i })
    codes[i] = last("SBOS_MODULE_REQUEST_ACK").params.error_code
  end
  check("burst of 10 accepted", codes[10] == "ok", codes[10])
  check("the 11th is rate_limited", codes[11] == "rate_limited" and codes[12] == "rate_limited")
  advance(2) -- 30/min = one token every 2 s
  sent = {}
  req(bus, ai, { idempotency_key = "rl-after" })
  check("refilled at 30/min", last("SBOS_MODULE_REQUEST_ACK").params.error_code == "ok")
  check("rate limiting counted", bus:health().rate_limited == 2 and bus:moduleCounters("ai_core", "601").rate_limited == 2)
end

print("[9] cloud relay")
do
  local registry, bus, _, ai = setup()
  local function cloud(over, who)
    reqSeq = reqSeq + 1
    local p = {
      request_id = "c-" .. reqSeq,
      idempotency_key = "ck-" .. reqSeq,
      op = "ask",
      body = '{"question":"why is the den cold"}',
      deadline = tostring(T.now + 20),
    }
    for k, v in pairs(over or {}) do
      p[k] = v
    end
    sent = {}
    bus:cloudRequest(who or ai, p)
    return last("SBOS_MODULE_CLOUD_RESPONSE"), p
  end
  cloudAnswer = function()
    return { ok = true, http_status = 200, body = { ok = true, result = { accepted = true, job_id = "j1" } } }
  end
  local a, p = cloud({ module_id = "flight_recorder", instance_id = "501" })
  local post = posts[#posts]
  check(
    "success: CLOUD_RESPONSE ok with the result",
    a and a.params.status == "ok" and a.params.http_status == "200" and JSON:decode(a.params.result).job_id == "j1"
      and a.params.token == ai.token
  )
  local keys = {}
  for k in pairs(post) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  check(
    "POST body is exactly {module_id, instance_id, op, request_id, idempotency_key, body}",
    table.concat(keys, ",") == "body,idempotency_key,instance_id,module_id,op,request_id"
      and post.module_id == "ai_core" and post.instance_id == "601" and post.op == "ask"
      and post.request_id == p.request_id and post.idempotency_key == p.idempotency_key
      and post.body.question == "why is the den cold",
    table.concat(keys, ",")
  )
  local n = #posts
  local again = cloud({ idempotency_key = p.idempotency_key })
  check("duplicate key: stored answer, no second POST", #posts == n and again.params.status == "ok")
  local refusedOp = cloud({ op = "run_lua" })
  check("op outside MODULE_CLOUD_OPS → not_permitted, nothing posted", refusedOp.params.error_code == "not_permitted" and #posts == n)
  local _, _, usage = register(registry, bus, { module_id = "usage_analytics", instance_id = "701", manifest = AI_MANIFEST })
  check("a module with no cloud ops → not_permitted", cloud({}, usage).params.error_code == "not_permitted" and #posts == n)
  check("body over 16 KB → payload_too_large", cloud({ body = JSON:encode({ s = string.rep("z", 17 * 1024) }) }).params.error_code == "payload_too_large")
  check("body not a JSON object → invalid_args", cloud({ body = "nope" }).params.error_code == "invalid_args")

  cloudAnswer = function()
    return { ok = false, reason = "timeout" }
  end
  local u, up = cloud()
  check("transport failure → cloud_unreachable", u.params.error_code == "cloud_unreachable" and u.params.http_status == "")
  n = #posts
  cloud({ idempotency_key = up.idempotency_key })
  check("cloud_unreachable is not stored: the retry posts again", #posts == n + 1)
  cloudAnswer = function()
    return { ok = false, http_status = 503, reason = "HTTP 503" }
  end
  check("HTTP 5xx → cloud_unreachable", cloud().params.error_code == "cloud_unreachable")
  cloudAnswer = function()
    return { ok = false, http_status = 403, reason = "HTTP 403" }
  end
  check("HTTP 4xx → cloud_refused", cloud().params.error_code == "cloud_refused")
  cloudAnswer = function()
    return { ok = false, http_status = 429 }
  end
  check("HTTP 429 → rate_limited", cloud().params.error_code == "rate_limited")
  advance(30) -- refill the cloud bucket (20/min, burst 10) spent above
  cloudAnswer = function()
    return { ok = true, http_status = 200, body = { ok = false, error_code = "not_permitted" } }
  end
  check("200 {ok:false, error_code} → that closed-vocabulary code", cloud().params.error_code == "not_permitted")
  cloudAnswer = function()
    return { ok = true, http_status = 200, body = { ok = false, error_code = "something_else" } }
  end
  check("200 {ok:false} with an unknown code → cloud_refused", cloud().params.error_code == "cloud_refused")
  paired = false
  n = #posts
  check("Agent not paired → agent_not_paired, nothing posted", cloud().params.error_code == "agent_not_paired" and #posts == n)
  paired = true

  -- cloud rate limit: 20/min burst 10 (fresh bus so the bucket is full)
  local _, bus2, _, ai2 = setup()
  bus = bus2
  local codes = {}
  cloudAnswer = function()
    return { ok = true, http_status = 200, body = {} }
  end
  for i = 1, 11 do
    codes[i] = cloud({ idempotency_key = "crl-" .. i }, ai2).params.error_code
  end
  check("cloud burst 10 then rate_limited", codes[10] == "ok" and codes[11] == "rate_limited", codes[11])
  advance(3) -- 20/min = one token every 3 s
  check("cloud bucket refills at 20/min", cloud({ idempotency_key = "crl-x" }, ai2).params.error_code == "ok")

  -- an answer that arrives after the requester re-registered still reaches it
  cloudAnswer = nil
  advance(30)
  cloud({ idempotency_key = "held" }, ai2)
  local done = heldPosts[#heldPosts]
  local registry2 = bus.registry
  local _, _, ai3 = register(registry2, bus, { module_id = "ai_core", instance_id = "601", manifest = AI_MANIFEST })
  sent = {}
  done({ ok = true, http_status = 202, body = { accepted = true } })
  local late = last("SBOS_MODULE_CLOUD_RESPONSE", 601)
  check("a held cloud answer is delivered with the CURRENT token", late and late.params.token == ai3.token and late.params.http_status == "202")
  check("cloud counters", bus:health().cloud_requests >= 12 and bus:health().cloud_ok >= 11)
  cloudAnswer = nil
end

print("[10] health block")
do
  local _, bus = setup()
  local h = bus:health()
  check(
    "bus counters: requests, refused, timeouts, published, dropped (+ cloud, inflight, subscriptions)",
    h.requests == 0 and h.refused == 0 and h.timeouts == 0 and h.published == 0 and h.dropped == 0
      and h.cloud_requests == 0 and h.inflight == 0 and h.subscriptions == 0 and h.directory_version >= 2
  )
  bus:stop()
  check("stop cancels the bus timers", T.timers[ModuleBus.TICK_TIMER] == nil and T.timers[ModuleBus.DIRECTORY_TIMER] == nil)
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
