--- SmartBuildOS module contract v2 — the Agent's bus (pure; injected I/O).
---
--- Hub-and-spoke: modules never talk to each other directly. Every v2 frame
--- reaches the Agent over SendToDevice → ExecuteCommand, is authenticated by
--- the Agent driver against the registry token (unauthenticated frames never
--- get here), and is handled by this engine:
---
---   discovery        SBOS_MODULE_DISCOVER → SBOS_MODULE_DIRECTORY, and a
---                    debounced SBOS_MODULE_DIRECTORY_CHANGED push
---   pub/sub          SBOS_MODULE_SUBSCRIBE/UNSUBSCRIBE → SUBSCRIBED; fan-out
---                    of envelopes the Agent ACCEPTED as SBOS_MODULE_PUBLISH
---   request/response SBOS_MODULE_REQUEST → REQUEST_ACK (+ forwarded REQUEST)
---                    → SBOS_MODULE_RESPONSE relayed back
---   cloud relay      SBOS_MODULE_CLOUD_REQUEST → POST modules/rpc through the
---                    Agent's own authenticated send() → CLOUD_RESPONSE
---
--- Sender identity: ExecuteCommand carries none, so every forwarded frame's
--- from_module_id / from_instance_id is stamped HERE from the registry entry
--- the token authenticated. Nothing a module claims about itself is copied
--- into a forwarded frame; params are rebuilt field by field.
---
--- Every Agent → module v2 frame carries the RECIPIENT's auth triple
--- (module_id, instance_id, token) so the client can ignore frames that did
--- not come from the Agent that registered it.
---
--- Spec: docs/protocol/MODULE-CONTRACT-V2.md. Vocabulary and limits:
--- sbos.modulepolicy.

local Policy = require("sbos.modulepolicy")
local Modules = require("sbos.modules")
local Envelope = require("sbos.envelope")
JSON = JSON or require("JSON")

local M = {}
M.Policy = Policy
M.TICK_TIMER = "SbosModuleBusTick"
M.PUBLISH_TIMER = "SbosModuleBusPublish"
M.DIRECTORY_TIMER = "SbosModuleBusDirectory"

local L = Policy.LIMITS

local Bus = {}
Bus.__index = Bus

local function instKey(moduleId, instanceId)
  return tostring(moduleId) .. "@" .. tostring(instanceId)
end

local function isV2(entry)
  return entry ~= nil and (tonumber(entry.protocol) or 1) >= Policy.V2
end

local function decode(raw)
  if type(raw) ~= "string" then
    return false, nil
  end
  return pcall(function()
    return JSON:decode(raw)
  end)
end

local function encode(value)
  local ok, out = pcall(function()
    return JSON:encode(value)
  end)
  if ok then
    return out
  end
  return nil
end

--- Token bucket: `rate` = { per_minute, burst }; lazily refilled.
local function take(bucket, rate, now)
  if bucket.tokens == nil then
    bucket.tokens = rate.burst
    bucket.at = now
  end
  local elapsed = now - bucket.at
  if elapsed > 0 then
    bucket.tokens = math.min(rate.burst, bucket.tokens + elapsed * rate.per_minute / 60)
    bucket.at = now
  end
  if bucket.tokens >= 1 then
    bucket.tokens = bucket.tokens - 1
    return true
  end
  return false
end

--- @param opts table {
---   registry   sbos.modules Registry,
---   now        fun():number (epoch seconds),
---   send       fun(instanceId, command, params):boolean,
---   cloudPost  fun(body:table, done:fun(res)) — res = { ok, http_status, body, reason },
---   setTimer   fun(id, ms, fn, repeating), cancelTimer fun(id),
---   agent      fun():table { version, paired:boolean, connected:boolean },
---   policy     optional { REQUEST_POLICY, TOPIC_POLICY, CLOUD_OPS } (tests),
--- }
function M.new(opts)
  local self = setmetatable({}, Bus)
  self.registry = opts.registry
  self.now = opts.now
  self.sendRaw = opts.send
  self.cloudPost = opts.cloudPost
  self.setTimer = opts.setTimer or function() end
  self.cancelTimer = opts.cancelTimer or function() end
  self.agentInfo = opts.agent or function()
    return {}
  end
  local policy = opts.policy or {}
  self.requestPolicy = policy.REQUEST_POLICY or Policy.REQUEST_POLICY
  self.topicPolicy = policy.TOPIC_POLICY or Policy.TOPIC_POLICY
  self.cloudOps = policy.CLOUD_OPS or Policy.CLOUD_OPS
  self.subs = {} -- "<module>@<instance>|<subscription_id>" -> subscription
  self.routes = {} -- request_id -> route
  self.routeCount = 0
  self.idem = { map = {}, order = {} }
  self.buckets = {} -- module_id -> { request = {}, cloud = {} }
  self.per = {} -- "<module>@<instance>" -> counters
  self.stale = {} -- "<module>@<instance>" -> last observed stale flag
  self.directoryVersion = 0
  self.directoryArmed = false
  self.publishArmed = false
  self.tickArmed = false
  self.totals = {
    requests = 0,
    routed = 0,
    refused = 0,
    responses = 0,
    timeouts = 0,
    replayed = 0,
    published = 0,
    dropped = 0,
    discovers = 0,
    subscribes = 0,
    cloud_requests = 0,
    cloud_ok = 0,
    cloud_failed = 0,
    rate_limited = 0,
    ignored = 0,
  }
  return self
end

function Bus:counter(entry, name, n)
  local key = instKey(entry.module_id, entry.instance_id)
  local c = self.per[key]
  if c == nil then
    c = { requests = 0, refused = 0, served = 0, published = 0, dropped = 0, cloud_requests = 0, rate_limited = 0 }
    self.per[key] = c
  end
  c[name] = (c[name] or 0) + (n or 1)
end

--- Sends to a registered entry, adding the recipient's auth triple.
function Bus:sendTo(entry, command, params)
  params.module_id = entry.module_id
  params.instance_id = tostring(entry.instance_id)
  params.token = entry.token
  return self.sendRaw(entry.instance_id, command, params)
end

function Bus:bucket(moduleId, kind)
  local b = self.buckets[moduleId]
  if b == nil then
    b = { request = {}, cloud = {} }
    self.buckets[moduleId] = b
  end
  return b[kind]
end

function Bus:allow(entry, kind)
  if take(self:bucket(entry.module_id, kind), Policy.RATES[kind], self.now()) then
    return true
  end
  self.totals.rate_limited = self.totals.rate_limited + 1
  self:counter(entry, "rate_limited")
  return false
end

function Bus:armTick()
  if self.tickArmed then
    return
  end
  self.tickArmed = true
  self.setTimer(M.TICK_TIMER, L.tick_seconds * 1000, function()
    self:tick()
  end, true)
end

-- ── idempotency ring ─────────────────────────────────────────────────────────

function Bus:idemGet(key)
  return self.idem.map[key]
end

function Bus:idemPut(key, rec)
  if self.idem.map[key] == nil then
    self.idem.order[#self.idem.order + 1] = key
    while #self.idem.order > L.idempotency_ring do
      local old = table.remove(self.idem.order, 1)
      self.idem.map[old] = nil
    end
  end
  self.idem.map[key] = rec
end

function Bus:idemDrop(key, requestId)
  local rec = self.idem.map[key]
  if rec ~= nil and rec.state == "inflight" and rec.request_id == requestId then
    self.idem.map[key] = nil
    for i, k in ipairs(self.idem.order) do
      if k == key then
        table.remove(self.idem.order, i)
        break
      end
    end
  end
end

function Bus:addRoute(route)
  self.routes[route.request_id] = route
  self.routeCount = self.routeCount + 1
  self:armTick()
end

function Bus:dropRoute(requestId)
  if self.routes[requestId] ~= nil then
    self.routes[requestId] = nil
    self.routeCount = self.routeCount - 1
  end
end

-- ── lifecycle hooks (called by the Agent driver) ─────────────────────────────

--- A (re)registration: a new token is a new session, so the instance's old
--- subscriptions are dropped (the client re-subscribes after REGISTERED).
function Bus:onRegistered(entry)
  self:dropSubscriptions(entry)
  self.stale[instKey(entry.module_id, entry.instance_id)] = false
  self:directoryChanged()
  if isV2(entry) then
    self:armTick()
  end
end

--- Unregistration (or removal): subscriptions dropped; requests routed TO
--- it are answered target_unavailable now instead of at their deadline.
function Bus:onRemoved(entry)
  self:dropSubscriptions(entry)
  local key = instKey(entry.module_id, entry.instance_id)
  self.stale[key] = nil
  for id, route in pairs(self.routes) do
    if
      route.kind == "request"
      and route.to_module == entry.module_id
      and route.to_instance == tostring(entry.instance_id)
    then
      self:dropRoute(id)
      self:idemDrop(route.key, id)
      local requester = self.registry:find(route.from_module, route.from_instance)
      if requester ~= nil then
        self:sendTo(requester, "SBOS_MODULE_RESPONSE", {
          request_id = id,
          status = "error",
          error_code = "target_unavailable",
          result = "null",
          cursor = "",
          from_module_id = entry.module_id,
          from_instance_id = tostring(entry.instance_id),
        })
      end
    elseif route.from_module == entry.module_id and route.from_instance == tostring(entry.instance_id) then
      self:dropRoute(id)
      self:idemDrop(route.key, id)
    end
  end
  self:directoryChanged()
end

function Bus:dropSubscriptions(entry)
  local prefix = instKey(entry.module_id, entry.instance_id) .. "|"
  for k in pairs(self.subs) do
    if k:sub(1, #prefix) == prefix then
      self.subs[k] = nil
    end
  end
end

--- Debounced push of SBOS_MODULE_DIRECTORY_CHANGED to every live v2 module.
function Bus:directoryChanged()
  self.directoryVersion = self.directoryVersion + 1
  if self.directoryArmed then
    return
  end
  self.directoryArmed = true
  self.setTimer(M.DIRECTORY_TIMER, L.directory_debounce_seconds * 1000, function()
    self.directoryArmed = false
    for _, e in ipairs(self.registry:list()) do
      if isV2(e) and not self.registry:isStale(e) then
        self:sendTo(e, "SBOS_MODULE_DIRECTORY_CHANGED", { directory_version = tostring(self.directoryVersion) })
      end
    end
  end)
end

--- Periodic work: routing state past deadline + grace, stale transitions
--- (they change the directory), and any publish buffer left behind.
function Bus:tick()
  local now = self.now()
  for id, route in pairs(self.routes) do
    if now > route.deadline + L.route_grace_seconds then
      self:dropRoute(id)
      self:idemDrop(route.key, id)
      if route.kind == "request" then
        self.totals.timeouts = self.totals.timeouts + 1
      end
    end
  end
  local changed = false
  for _, e in ipairs(self.registry:list()) do
    local key = instKey(e.module_id, e.instance_id)
    local stale = self.registry:isStale(e)
    if self.stale[key] ~= stale then
      if self.stale[key] ~= nil or stale then
        changed = true
      end
      self.stale[key] = stale
    end
  end
  if changed then
    self:directoryChanged()
  end
  self:flushPublish()
end

-- ── discovery ────────────────────────────────────────────────────────────────

function Bus:directoryRow(e)
  local manifest = type(e.manifest) == "table" and e.manifest or {}
  return {
    module_id = e.module_id,
    instance_id = tostring(e.instance_id),
    driver = manifest.driver or "",
    driver_version = e.driver_version or "",
    protocol = tonumber(e.protocol) or 1,
    status = e.status or "",
    stale = self.registry:isStale(e),
    capabilities = manifest.capabilities or {},
  }
end

function Bus:discover(entry, p)
  self.totals.discovers = self.totals.discovers + 1
  local requestId = tostring(p.request_id or ""):sub(1, L.id)
  local agent = self.agentInfo() or {}
  local reply = {
    request_id = requestId,
    directory_version = tostring(self.directoryVersion),
    agent = encode({
      version = tostring(agent.version or ""),
      protocol_min = Policy.PROTOCOL_MIN,
      protocol_max = Policy.PROTOCOL_MAX,
      paired = agent.paired == true,
      connected = agent.connected == true,
    }) or "{}",
    modules = "[]",
    truncated = "false",
    error_code = "ok",
  }
  local function answer(code)
    reply.error_code = code
    self:sendTo(entry, "SBOS_MODULE_DIRECTORY", reply)
  end
  if not Policy.validId(requestId) then
    return answer("invalid_frame")
  end
  if not isV2(entry) then
    return answer("incompatible_protocol")
  end
  if not self:allow(entry, "request") then
    return answer("rate_limited")
  end
  local filter = {}
  if p.filter ~= nil and p.filter ~= "" then
    local ok, f = decode(p.filter)
    if not ok or type(f) ~= "table" then
      return answer("invalid_args")
    end
    filter = f
  end
  local rows = {}
  for _, e in ipairs(self.registry:list()) do
    local keep = (filter.module_id == nil or filter.module_id == e.module_id)
      and (filter.capability == nil or Modules.findCapability(e, filter.capability) ~= nil)
    if keep then
      rows[#rows + 1] = self:directoryRow(e)
    end
  end
  local encoded = encode(rows) or "[]"
  while #encoded > L.directory_bytes and #rows > 0 do
    table.remove(rows)
    reply.truncated = "true"
    encoded = encode(rows) or "[]"
  end
  reply.modules = encoded
  return answer("ok")
end

-- ── pub/sub ──────────────────────────────────────────────────────────────────

function Bus:subscribe(entry, p)
  self.totals.subscribes = self.totals.subscribes + 1
  local sid = tostring(p.subscription_id or ""):sub(1, L.subscription_id)
  local function answer(ok, reason, granted, refused)
    self:sendTo(entry, "SBOS_MODULE_SUBSCRIBED", {
      subscription_id = sid,
      ok = ok and "true" or "false",
      reason = reason,
      granted = encode(granted or {}) or "[]",
      refused = encode(refused or {}) or "[]",
    })
  end
  if not Policy.validId(sid, L.subscription_id) then
    return answer(false, "invalid_frame")
  end
  if not isV2(entry) then
    return answer(false, "incompatible_protocol")
  end
  local ok, topics = decode(p.topics)
  if not ok or type(topics) ~= "table" or #topics == 0 or #topics > L.topics then
    return answer(false, "invalid_args")
  end
  for _, t in ipairs(topics) do
    if not Policy.validTopic(t) then
      return answer(false, "invalid_args")
    end
  end
  local base = instKey(entry.module_id, entry.instance_id) .. "|"
  local key = base .. sid
  local count = 0
  for k in pairs(self.subs) do
    if k:sub(1, #base) == base and k ~= key then
      count = count + 1
    end
  end
  if count >= L.subscriptions_per_instance then
    return answer(false, "invalid_args")
  end
  local granted, refused = {}, {}
  for _, t in ipairs(topics) do
    if Policy.topicAllowed(self.topicPolicy, entry.module_id, t) then
      granted[#granted + 1] = t
    else
      refused[#refused + 1] = t
    end
  end
  if #granted == 0 then
    self.subs[key] = nil
    return answer(false, "not_permitted", granted, refused)
  end
  self.subs[key] = {
    key = key,
    module_id = entry.module_id,
    instance_id = tostring(entry.instance_id),
    subscription_id = sid,
    topics = granted,
    buffer = {},
    dropped = 0,
    dropped_total = 0,
    published = 0,
  }
  self:armTick()
  return answer(true, #refused > 0 and "not_permitted" or "ok", granted, refused)
end

function Bus:unsubscribe(entry, p)
  local sid = tostring(p.subscription_id or "")
  self.subs[instKey(entry.module_id, entry.instance_id) .. "|" .. sid] = nil
end

--- Fan-out source: an envelope the Agent has just ACCEPTED into its durable
--- queue (validated, owned prefix, not a duplicate). Best-effort,
--- at-most-once; never echoed to the instance that emitted it.
function Bus:offer(env, source)
  local eventType = type(env) == "table" and env.event_type or nil
  if type(eventType) ~= "string" then
    return
  end
  local sourceKey = source and instKey(source.module_id, source.instance_id) or ""
  local any = false
  for _, sub in pairs(self.subs) do
    if instKey(sub.module_id, sub.instance_id) ~= sourceKey then
      for _, t in ipairs(sub.topics) do
        if eventType:sub(1, #t) == t then
          sub.buffer[#sub.buffer + 1] = env
          while #sub.buffer > L.subscriber_buffer do
            table.remove(sub.buffer, 1)
            sub.dropped = sub.dropped + 1
            sub.dropped_total = sub.dropped_total + 1
            self.totals.dropped = self.totals.dropped + 1
            self:counter(sub, "dropped")
          end
          any = true
          break
        end
      end
    end
  end
  if any and not self.publishArmed then
    self.publishArmed = true
    self.setTimer(M.PUBLISH_TIMER, L.publish_delay_ms, function()
      self.publishArmed = false
      self:flushPublish()
    end)
  end
end

function Bus:flushPublish()
  for key, sub in pairs(self.subs) do
    if #sub.buffer > 0 then
      local target = self.registry:find(sub.module_id, sub.instance_id)
      if target == nil then
        self.subs[key] = nil
      else
        while #sub.buffer > 0 do
          local events, bytes = {}, 0
          while #sub.buffer > 0 and #events < L.publish_batch do
            local size = Envelope.approxSize(sub.buffer[1])
            if #events > 0 and bytes + size > L.publish_frame_bytes then
              break
            end
            bytes = bytes + size
            events[#events + 1] = table.remove(sub.buffer, 1)
          end
          self:sendTo(target, "SBOS_MODULE_PUBLISH", {
            subscription_id = sub.subscription_id,
            events = encode(events) or "[]",
            dropped = tostring(sub.dropped),
          })
          sub.dropped = 0
          sub.published = sub.published + #events
          self.totals.published = self.totals.published + #events
          self:counter(sub, "published", #events)
        end
      end
    end
  end
end

-- ── request / response ───────────────────────────────────────────────────────

--- Validates the parts every routed call shares. Returns deadline or nil, code.
function Bus:deadlineOf(p)
  local deadline = tonumber(p.deadline)
  if deadline == nil then
    return nil, "invalid_frame"
  end
  local now = self.now()
  if deadline <= now then
    return nil, "deadline_exceeded"
  end
  if deadline > now + L.deadline_max_seconds then
    return nil, "invalid_args"
  end
  return math.floor(deadline)
end

function Bus:request(entry, p)
  self.totals.requests = self.totals.requests + 1
  self:counter(entry, "requests")
  local requestId = tostring(p.request_id or ""):sub(1, L.id)
  local function refuse(code)
    self.totals.refused = self.totals.refused + 1
    self:counter(entry, "refused")
    self:sendTo(entry, "SBOS_MODULE_REQUEST_ACK", { request_id = requestId, state = "Refused", error_code = code })
  end
  if not Policy.validId(requestId) then
    return refuse("invalid_frame")
  end
  if not isV2(entry) then
    return refuse("incompatible_protocol")
  end
  if not self:allow(entry, "request") then
    return refuse("rate_limited")
  end
  local to = tostring(p.to or "")
  local capability = tostring(p.capability or "")
  local key = tostring(p.idempotency_key or requestId)
  if not Modules.validModuleId(to) or not Policy.validCapability(capability) or not Policy.validId(key) then
    return refuse("invalid_frame")
  end
  local rawArgs = p.args == nil and "{}" or tostring(p.args)
  if #rawArgs > L.args_bytes then
    return refuse("payload_too_large")
  end
  local okA, args = decode(rawArgs)
  if not okA or type(args) ~= "table" then
    return refuse("invalid_args")
  end
  local deadline, why = self:deadlineOf(p)
  if deadline == nil then
    return refuse(why)
  end
  if self.routes[requestId] ~= nil then
    return refuse("duplicate_request")
  end
  local rule = self.requestPolicy[capability]
  if rule == nil or not (rule.requesters or {})[entry.module_id] then
    return refuse("not_permitted")
  end
  local idemKey = "req|" .. entry.module_id .. "|" .. key
  local rec = self:idemGet(idemKey)
  if rec ~= nil and rec.state == "done" then
    -- The stored terminal answer, without routing again.
    self.totals.replayed = self.totals.replayed + 1
    self:sendTo(
      entry,
      "SBOS_MODULE_REQUEST_ACK",
      { request_id = requestId, state = "Routed", error_code = "duplicate_request" }
    )
    local a = rec.answer
    self:sendTo(entry, "SBOS_MODULE_RESPONSE", {
      request_id = requestId,
      status = a.status,
      error_code = a.error_code,
      result = a.result,
      cursor = a.cursor,
      from_module_id = a.from_module_id,
      from_instance_id = a.from_instance_id,
      replayed = "true",
    })
    return
  end
  if rec ~= nil and rec.state == "inflight" then
    if self.now() <= rec.deadline then
      return refuse("duplicate_request")
    end
    -- The earlier attempt is past its deadline: abandoned, not answered.
    self:dropRoute(rec.request_id)
    self:idemDrop(idemKey, rec.request_id)
    self.totals.timeouts = self.totals.timeouts + 1
  end
  local known, live = false, {}
  for _, e in ipairs(self.registry:list()) do
    if e.module_id == to then
      if p.to_instance == nil or p.to_instance == "" or tostring(e.instance_id) == tostring(p.to_instance) then
        known = true
        if isV2(e) and not self.registry:isStale(e) then
          live[#live + 1] = e
        end
      end
    end
  end
  if not known then
    return refuse("unknown_target")
  end
  if rule.provider ~= nil and rule.provider ~= to then
    return refuse("capability_not_found")
  end
  local target = live[1]
  if target == nil then
    return refuse("target_unavailable")
  end
  if Modules.findCapability(target, capability, "request") == nil then
    return refuse("capability_not_found")
  end
  if self.routeCount >= L.routes then
    return refuse("rate_limited")
  end
  self:addRoute({
    kind = "request",
    request_id = requestId,
    key = idemKey,
    from_module = entry.module_id,
    from_instance = tostring(entry.instance_id),
    to_module = target.module_id,
    to_instance = tostring(target.instance_id),
    deadline = deadline,
  })
  self:idemPut(idemKey, { state = "inflight", request_id = requestId, deadline = deadline })
  self.totals.routed = self.totals.routed + 1
  self:sendTo(entry, "SBOS_MODULE_REQUEST_ACK", { request_id = requestId, state = "Routed", error_code = "ok" })
  self:sendTo(target, "SBOS_MODULE_REQUEST", {
    request_id = requestId,
    idempotency_key = key,
    from_module_id = entry.module_id,
    from_instance_id = tostring(entry.instance_id),
    capability = capability,
    args = rawArgs,
    deadline = tostring(deadline),
  })
end

function Bus:response(entry, p)
  local requestId = tostring(p.request_id or "")
  local route = self.routes[requestId]
  if
    route == nil
    or route.kind ~= "request"
    or route.to_module ~= entry.module_id
    or route.to_instance ~= tostring(entry.instance_id)
  then
    -- Only the instance a request was routed to may answer it.
    self.totals.ignored = self.totals.ignored + 1
    return
  end
  local status = p.status == "ok" and "ok" or "error"
  local code = status == "ok" and "ok" or Policy.code(p.error_code)
  if status == "error" and code == "ok" then
    code = "internal_error"
  end
  local result = p.result == nil and "null" or tostring(p.result)
  local cursor = p.cursor == nil and "" or tostring(p.cursor)
  if #result > L.result_bytes then
    status, code, result = "error", "payload_too_large", "null"
  elseif not decode(result) then
    status, code, result = "error", "invalid_frame", "null"
  elseif #cursor > L.cursor then
    status, code, result, cursor = "error", "invalid_frame", "null", ""
  end
  local answer = {
    status = status,
    error_code = code,
    result = result,
    cursor = cursor,
    from_module_id = entry.module_id,
    from_instance_id = tostring(entry.instance_id),
  }
  self:dropRoute(requestId)
  local rec = self:idemGet(route.key)
  if rec ~= nil and rec.request_id == requestId then
    if Policy.RETRYABLE[code] then
      self:idemDrop(route.key, requestId)
    else
      self:idemPut(route.key, { state = "done", answer = answer })
    end
  end
  self.totals.responses = self.totals.responses + 1
  self:counter(entry, "served")
  local requester = self.registry:find(route.from_module, route.from_instance)
  if requester == nil then
    return
  end
  local out = { request_id = requestId }
  for k, v in pairs(answer) do
    out[k] = v
  end
  self:sendTo(requester, "SBOS_MODULE_RESPONSE", out)
end

-- ── cloud relay ──────────────────────────────────────────────────────────────

--- Codes a cloud answer may carry through as-is; anything else is cloud_refused.
local CLOUD_PASSTHROUGH = {
  not_permitted = true,
  invalid_args = true,
  unsupported = true,
  payload_too_large = true,
  rate_limited = true,
  agent_not_paired = true,
}

--- Maps the platform's answer to { status, http_status, error_code, result }.
function M.cloudAnswer(res)
  res = type(res) == "table" and res or {}
  local http = tonumber(res.http_status)
  if res.ok then
    local body = res.body
    if type(body) == "table" and body.ok == false then
      local code = CLOUD_PASSTHROUGH[body.error_code] and body.error_code or "cloud_refused"
      return { status = "error", http_status = http, error_code = code, result = encode(body.result) or "null" }
    end
    local result = body
    if type(body) == "table" and body.result ~= nil then
      result = body.result
    end
    local encoded = encode(result) or "null"
    if #encoded > L.cloud_result_bytes then
      return { status = "error", http_status = http, error_code = "payload_too_large", result = "null" }
    end
    return { status = "ok", http_status = http, error_code = "ok", result = encoded }
  end
  if http == 429 then
    return { status = "error", http_status = http, error_code = "rate_limited", result = "null" }
  end
  if http ~= nil and http >= 400 and http < 500 then
    return { status = "error", http_status = http, error_code = "cloud_refused", result = "null" }
  end
  return { status = "error", http_status = http, error_code = "cloud_unreachable", result = "null" }
end

function Bus:cloudRequest(entry, p)
  self.totals.cloud_requests = self.totals.cloud_requests + 1
  self:counter(entry, "cloud_requests")
  local requestId = tostring(p.request_id or ""):sub(1, L.id)
  local function answer(a)
    self:sendTo(entry, "SBOS_MODULE_CLOUD_RESPONSE", {
      request_id = requestId,
      status = a.status,
      http_status = a.http_status ~= nil and tostring(a.http_status) or "",
      error_code = a.error_code,
      result = a.result or "null",
    })
  end
  local function refuse(code)
    self.totals.refused = self.totals.refused + 1
    self:counter(entry, "refused")
    answer({ status = "error", error_code = code, result = "null" })
  end
  if not Policy.validId(requestId) then
    return refuse("invalid_frame")
  end
  if not isV2(entry) then
    return refuse("incompatible_protocol")
  end
  if not self:allow(entry, "cloud") then
    return refuse("rate_limited")
  end
  local op = tostring(p.op or "")
  local key = tostring(p.idempotency_key or requestId)
  if not Policy.validOp(op) or not Policy.validId(key) then
    return refuse("invalid_frame")
  end
  local ops = self.cloudOps[entry.module_id]
  if ops == nil or not ops[op] then
    return refuse("not_permitted")
  end
  local rawBody = p.body == nil and "{}" or tostring(p.body)
  if #rawBody > L.cloud_body_bytes then
    return refuse("payload_too_large")
  end
  local okB, body = decode(rawBody)
  if not okB or type(body) ~= "table" then
    return refuse("invalid_args")
  end
  local deadline, why = self:deadlineOf(p)
  if deadline == nil then
    return refuse(why)
  end
  if self.routes[requestId] ~= nil then
    return refuse("duplicate_request")
  end
  if self.agentInfo().paired ~= true then
    return refuse("agent_not_paired")
  end
  local idemKey = "cloud|" .. entry.module_id .. "|" .. key
  local rec = self:idemGet(idemKey)
  if rec ~= nil and rec.state == "done" then
    self.totals.replayed = self.totals.replayed + 1
    return answer(rec.answer)
  end
  if rec ~= nil and rec.state == "inflight" and self.now() <= rec.deadline then
    return refuse("duplicate_request")
  end
  if self.routeCount >= L.routes then
    return refuse("rate_limited")
  end
  self:addRoute({
    kind = "cloud",
    request_id = requestId,
    key = idemKey,
    from_module = entry.module_id,
    from_instance = tostring(entry.instance_id),
    deadline = deadline,
  })
  self:idemPut(idemKey, { state = "inflight", request_id = requestId, deadline = deadline })
  local moduleId, instanceId = entry.module_id, tostring(entry.instance_id)
  self.cloudPost({
    module_id = moduleId,
    instance_id = instanceId,
    op = op,
    request_id = requestId,
    idempotency_key = key,
    body = body,
  }, function(res)
    local a = M.cloudAnswer(res)
    self:dropRoute(requestId)
    local held = self:idemGet(idemKey)
    if held ~= nil and held.request_id == requestId then
      if Policy.RETRYABLE[a.error_code] then
        self:idemDrop(idemKey, requestId)
      else
        self:idemPut(idemKey, { state = "done", answer = a })
      end
    end
    if a.status == "ok" then
      self.totals.cloud_ok = self.totals.cloud_ok + 1
    else
      self.totals.cloud_failed = self.totals.cloud_failed + 1
    end
    -- The requester may have re-registered since (new token): look it up.
    local requester = self.registry:find(moduleId, instanceId)
    if requester ~= nil then
      self:sendTo(requester, "SBOS_MODULE_CLOUD_RESPONSE", {
        request_id = requestId,
        status = a.status,
        http_status = a.http_status ~= nil and tostring(a.http_status) or "",
        error_code = a.error_code,
        result = a.result or "null",
      })
    end
  end)
end

-- ── health ───────────────────────────────────────────────────────────────────

--- The heartbeat's `module_bus` block (Agent totals).
function Bus:health()
  local subs = 0
  local buffered = 0
  for _, s in pairs(self.subs) do
    subs = subs + 1
    buffered = buffered + #s.buffer
  end
  local out = {}
  for k, v in pairs(self.totals) do
    out[k] = v
  end
  out.inflight = self.routeCount
  out.subscriptions = subs
  out.buffered = buffered
  out.directory_version = self.directoryVersion
  return out
end

--- What the Agent measured for one instance (heartbeat modules[].bus).
function Bus:moduleCounters(moduleId, instanceId)
  return self.per[instKey(moduleId, instanceId)]
end

function Bus:stop()
  self.cancelTimer(M.TICK_TIMER)
  self.cancelTimer(M.PUBLISH_TIMER)
  self.cancelTimer(M.DIRECTORY_TIMER)
  self.tickArmed = false
  self.publishArmed = false
  self.directoryArmed = false
end

M.Bus = Bus
return M
