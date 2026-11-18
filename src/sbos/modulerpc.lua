--- SmartBuildOS module contract v2 — the module-side bus client (pure;
--- injected I/O). sbos.moduleclient owns registration and the token and
--- exposes this engine as client.discover / subscribe / request /
--- onRequest / respond / cloudRequest.
---
--- Rules it implements (docs/protocol/MODULE-CONTRACT-V2.md):
---   * Nothing is sent unless the negotiated protocol is >= 2. Against a
---     v1-only Agent every call completes with `incompatible_protocol` and the
---     driver reports `agent_update_required` (v1 services keep working).
---   * Limits are checked HERE first (args 16 KB, cloud body 16 KB, result
---     24 KB, deadline <= 60 s): an oversize call never leaves the driver.
---   * The requester arms a timer at the deadline: no answer →
---     `deadline_exceeded` (or `target_unavailable` when the Agent restarted
---     meanwhile, because its routing state died with it).
---   * Retries: only deadline_exceeded / target_unavailable / rate_limited /
---     cloud_unreachable; at most 2, after 2 s then 5 s, with the SAME
---     idempotency key and a fresh request_id per attempt.
---   * A target dedups on (Agent-stamped sender, request_id): a duplicated
---     frame from the SAME sender gets the stored answer again and the
---     handler is not re-run. A colliding request_id from another sender is
---     a new request — it never receives, and cannot probe for, an answer
---     given to someone else.
---   * Every Agent → module frame must carry this module's token; anything
---     else is ignored.
---   * Subscriptions are desired state: re-sent after every successful v2
---     registration (the Agent forgets them on restart and re-registration).

local Policy = require("sbos.modulepolicy")
JSON = JSON or require("JSON")

local M = {}
M.Policy = Policy
M.DISCOVER_TIMEOUT_SECONDS = 10
M.DEFAULT_TIMEOUT_SECONDS = 10

local L = Policy.LIMITS

local Rpc = {}
Rpc.__index = Rpc

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

local idCounter = 0
--- A request / subscription id: a v4 UUID from Director when available,
--- else time + counter + math.random (unique per driver, which is all the
--- Agent's per-module idempotency ring needs).
function M.newId(c4)
  if c4 ~= nil then
    local ok, uuid = pcall(function()
      return c4:UUID("RANDOM")
    end)
    if ok and type(uuid) == "string" and Policy.validId(uuid) then
      return uuid:lower()
    end
  end
  idCounter = idCounter + 1
  return string.format("%x-%x-%08x", os.time(), idCounter, math.random(0, 0x7fffffff))
end

--- @param io table {
---   send        fun(command, params):boolean  (moduleclient adds auth)
---   token       fun():string|nil              (this module's current token)
---   now         fun():number                  (epoch seconds)
---   setTimer    fun(id, ms, fn), cancelTimer fun(id),
---   newId       fun():string,
---   onDirectoryChanged fun(version)|nil,
--- }
function M.new(io)
  local self = setmetatable({}, Rpc)
  self.io = io
  self.protocol = nil -- negotiated; nil until registered
  self.registered = false
  self.calls = {} -- request_id (attempt) -> call
  self.discovers = {} -- request_id -> cb
  self.subs = {} -- subscription_id -> { topics, onEvents, onResult, state, granted }
  self.handlers = {} -- capability -> fun(req, respond)
  -- servedKey(sender, request_id) -> stored RESPONSE params | "pending";
  -- pendingById: request_id -> the one servedKey still awaiting its answer
  -- (what the public respond(request_id) resolves).
  self.served = { map = {}, order = {}, pendingById = {} }
  self.counters = {
    requests = 0,
    responses_ok = 0,
    errors = 0,
    timeouts = 0,
    retries = 0,
    served = 0,
    served_duplicates = 0,
    superseded = 0,
    published_received = 0,
    dropped_reported = 0,
    cloud_requests = 0,
    ignored_frames = 0,
  }
  return self
end

function Rpc:available()
  return self.registered and (self.protocol or 0) >= Policy.V2
end

--- Why a call cannot go out now: incompatible_protocol against a v1 Agent,
--- target_unavailable while unregistered (retryable: registration retries).
function Rpc:unavailableCode()
  if self.registered then
    return "incompatible_protocol"
  end
  return "target_unavailable"
end

--- A frame from "the Agent" is believed only when it carries our token.
function Rpc:authentic(p)
  local token = self.io.token()
  if token == nil or token == "" or type(p) ~= "table" or p.token ~= token then
    self.counters.ignored_frames = self.counters.ignored_frames + 1
    return false
  end
  return true
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

function Rpc:onRegistered(protocol)
  self.registered = true
  self.protocol = tonumber(protocol)
  if self:available() then
    for id in pairs(self.subs) do
      self:sendSubscribe(id)
    end
  end
end

function Rpc:onUnregistered()
  self.registered = false
  self.protocol = nil
end

--- The Agent restarted: its tokens, routes and subscriptions are gone.
function Rpc:onAgentHello()
  self.registered = false
  self.protocol = nil
  for _, call in pairs(self.calls) do
    call.restarted = true
  end
  for _, s in pairs(self.subs) do
    s.state = "pending"
  end
end

function Rpc:stop()
  for id in pairs(self.calls) do
    self.io.cancelTimer("SbosRpc:" .. id)
  end
  for id in pairs(self.discovers) do
    self.io.cancelTimer("SbosRpcDiscover:" .. id)
  end
  self.calls = {}
  self.discovers = {}
end

-- ── discovery ────────────────────────────────────────────────────────────────

--- cb(directory|nil, error_code). directory = { version, agent, modules, truncated }.
function Rpc:discover(filter, cb)
  cb = cb or function() end
  if not self:available() then
    cb(nil, self:unavailableCode())
    return false
  end
  local id = self.io.newId()
  self.discovers[id] = cb
  self.io.setTimer("SbosRpcDiscover:" .. id, M.DISCOVER_TIMEOUT_SECONDS * 1000, function()
    local pending = self.discovers[id]
    if pending ~= nil then
      self.discovers[id] = nil
      pending(nil, "deadline_exceeded")
    end
  end)
  return self.io.send("SBOS_MODULE_DISCOVER", {
    request_id = id,
    filter = filter ~= nil and (encode(filter) or "{}") or "",
  })
end

function Rpc:onDirectory(p)
  if not self:authentic(p) then
    return
  end
  local id = tostring(p.request_id or "")
  local cb = self.discovers[id]
  if cb == nil then
    return
  end
  self.discovers[id] = nil
  self.io.cancelTimer("SbosRpcDiscover:" .. id)
  local code = Policy.code(p.error_code)
  if code ~= "ok" then
    cb(nil, code)
    return
  end
  local okM, modules = decode(p.modules)
  local okA, agent = decode(p.agent)
  cb({
    version = tonumber(p.directory_version),
    agent = okA and agent or {},
    modules = okM and type(modules) == "table" and modules or {},
    truncated = p.truncated == "true",
  }, "ok")
end

function Rpc:onDirectoryChanged(p)
  if not self:authentic(p) then
    return
  end
  if self.io.onDirectoryChanged then
    pcall(self.io.onDirectoryChanged, tonumber(p.directory_version))
  end
end

-- ── pub/sub ──────────────────────────────────────────────────────────────────

--- Declares a subscription (desired state, re-sent after every v2
--- registration). onEvents(events, dropped, subscription_id);
--- onResult(ok, reason, granted, refused). Returns false, code when invalid.
function Rpc:subscribe(id, topics, onEvents, onResult)
  if not Policy.validId(id, L.subscription_id) then
    return false, "invalid_frame"
  end
  if type(topics) ~= "table" or #topics == 0 or #topics > L.topics then
    return false, "invalid_args"
  end
  for _, t in ipairs(topics) do
    if not Policy.validTopic(t) then
      return false, "invalid_args"
    end
  end
  self.subs[id] = { topics = topics, onEvents = onEvents, onResult = onResult, state = "pending" }
  if self:available() then
    self:sendSubscribe(id)
  end
  return true
end

function Rpc:sendSubscribe(id)
  local s = self.subs[id]
  if s == nil then
    return false
  end
  s.state = "requested"
  return self.io.send("SBOS_MODULE_SUBSCRIBE", { subscription_id = id, topics = encode(s.topics) or "[]" })
end

function Rpc:unsubscribe(id)
  self.subs[id] = nil
  if self:available() then
    self.io.send("SBOS_MODULE_UNSUBSCRIBE", { subscription_id = id })
  end
end

function Rpc:onSubscribed(p)
  if not self:authentic(p) then
    return
  end
  local s = self.subs[tostring(p.subscription_id or "")]
  if s == nil then
    return
  end
  local okG, granted = decode(p.granted)
  local okR, refused = decode(p.refused)
  s.state = p.ok == "true" and "active" or "refused"
  s.granted = okG and granted or {}
  s.reason = Policy.code(p.reason)
  if s.onResult then
    pcall(s.onResult, p.ok == "true", s.reason, s.granted, okR and refused or {})
  end
end

function Rpc:onPublish(p)
  if not self:authentic(p) then
    return
  end
  local id = tostring(p.subscription_id or "")
  local s = self.subs[id]
  if s == nil then
    return
  end
  local ok, events = decode(p.events)
  if not ok or type(events) ~= "table" then
    return
  end
  local dropped = tonumber(p.dropped) or 0
  self.counters.published_received = self.counters.published_received + #events
  self.counters.dropped_reported = self.counters.dropped_reported + dropped
  if s.onEvents then
    pcall(s.onEvents, events, dropped, id)
  end
end

-- ── request / response (requester side) ─────────────────────────────────────

local function clampTimeout(t)
  t = math.floor(tonumber(t) or M.DEFAULT_TIMEOUT_SECONDS)
  if t < 1 then
    return 1
  end
  if t > L.deadline_max_seconds then
    return L.deadline_max_seconds
  end
  return t
end

--- Finishes one attempt: retry when the code allows it, else the callback.
function Rpc:complete(call, answer)
  if call.done then
    return
  end
  if call.request_id ~= nil then
    self.calls[call.request_id] = nil
    self.io.cancelTimer("SbosRpc:" .. call.request_id)
  end
  local code = answer.error_code or "ok"
  if answer.status ~= "ok" and Policy.RETRYABLE[code] and call.attempt <= call.retries then
    local delay = Policy.RETRY_DELAYS[call.attempt] or Policy.RETRY_DELAYS[#Policy.RETRY_DELAYS]
    call.attempt = call.attempt + 1
    self.counters.retries = self.counters.retries + 1
    self.io.setTimer("SbosRpcRetry:" .. call.key, delay * 1000, function()
      self:attempt(call)
    end)
    return
  end
  call.done = true
  if answer.status == "ok" then
    self.counters.responses_ok = self.counters.responses_ok + 1
  else
    self.counters.errors = self.counters.errors + 1
  end
  answer.attempts = call.attempt
  answer.idempotency_key = call.key
  if call.cb then
    pcall(call.cb, answer)
  end
end

function Rpc:fail(call, code)
  self:complete(call, { status = "error", error_code = code, request_id = call.request_id })
end

function Rpc:attempt(call)
  call.request_id = self.io.newId()
  if not self:available() then
    self:fail(call, self:unavailableCode())
    return
  end
  call.deadline = self.io.now() + call.timeout
  call.restarted = false
  self.calls[call.request_id] = call
  local id = call.request_id
  self.io.setTimer("SbosRpc:" .. id, call.timeout * 1000, function()
    local pending = self.calls[id]
    if pending ~= nil then
      self.counters.timeouts = self.counters.timeouts + 1
      self:fail(pending, pending.restarted and "target_unavailable" or "deadline_exceeded")
    end
  end)
  if call.kind == "cloud" then
    self.io.send("SBOS_MODULE_CLOUD_REQUEST", {
      request_id = id,
      idempotency_key = call.key,
      op = call.op,
      body = call.raw,
      deadline = tostring(call.deadline),
    })
  else
    self.io.send("SBOS_MODULE_REQUEST", {
      request_id = id,
      idempotency_key = call.key,
      to = call.to,
      to_instance = call.to_instance,
      capability = call.capability,
      args = call.raw,
      deadline = tostring(call.deadline),
    })
  end
end

--- Asks another module for `capability`. cb(answer) with answer =
--- { status = "ok"|"error", error_code, result (decoded), cursor,
---   from_module_id, from_instance_id, attempts, idempotency_key, replayed }.
--- opts: { timeout (s, 1..60, default 10), to_instance, idempotency_key,
---         retries (0..2, default 2) }.
function Rpc:request(to, capability, args, opts, cb)
  opts = opts or {}
  local call = {
    kind = "request",
    to = tostring(to or ""),
    to_instance = opts.to_instance ~= nil and tostring(opts.to_instance) or nil,
    capability = tostring(capability or ""),
    key = opts.idempotency_key or self.io.newId(),
    timeout = clampTimeout(opts.timeout),
    retries = math.max(0, math.min(#Policy.RETRY_DELAYS, tonumber(opts.retries) or #Policy.RETRY_DELAYS)),
    attempt = 1,
    cb = cb,
  }
  self.counters.requests = self.counters.requests + 1
  call.raw = encode(args or {}) or ""
  if call.raw == "" or not Policy.validCapability(call.capability) or not Policy.validId(call.key) then
    self:fail(call, "invalid_args")
    return call.key
  end
  if #call.raw > L.args_bytes then
    self:fail(call, "payload_too_large")
    return call.key
  end
  self:attempt(call)
  return call.key
end

--- The SmartBuildOS cloud, through the Agent (closed op vocabulary per
--- module). cb(answer) with answer.http_status added.
function Rpc:cloudRequest(op, body, opts, cb)
  opts = opts or {}
  local call = {
    kind = "cloud",
    op = tostring(op or ""),
    key = opts.idempotency_key or self.io.newId(),
    timeout = clampTimeout(opts.timeout or 30),
    retries = math.max(0, math.min(#Policy.RETRY_DELAYS, tonumber(opts.retries) or #Policy.RETRY_DELAYS)),
    attempt = 1,
    cb = cb,
  }
  self.counters.cloud_requests = self.counters.cloud_requests + 1
  call.raw = encode(body or {}) or ""
  if call.raw == "" or not Policy.validOp(call.op) or not Policy.validId(call.key) then
    self:fail(call, "invalid_args")
    return call.key
  end
  if #call.raw > L.cloud_body_bytes then
    self:fail(call, "payload_too_large")
    return call.key
  end
  self:attempt(call)
  return call.key
end

function Rpc:onRequestAck(p)
  if not self:authentic(p) then
    return
  end
  local call = self.calls[tostring(p.request_id or "")]
  if call == nil then
    return
  end
  if p.state == "Refused" then
    self:fail(call, Policy.code(p.error_code))
  end
end

function Rpc:onResponse(p)
  if not self:authentic(p) then
    return
  end
  local call = self.calls[tostring(p.request_id or "")]
  if call == nil or call.kind ~= "request" then
    return
  end
  local okR, result = decode(p.result)
  local status = p.status == "ok" and "ok" or "error"
  self:complete(call, {
    status = status,
    error_code = status == "ok" and "ok" or Policy.code(p.error_code),
    result = okR and result or nil,
    cursor = (p.cursor ~= nil and p.cursor ~= "") and p.cursor or nil,
    from_module_id = p.from_module_id,
    from_instance_id = p.from_instance_id,
    request_id = call.request_id,
    replayed = p.replayed == "true",
  })
end

function Rpc:onCloudResponse(p)
  if not self:authentic(p) then
    return
  end
  local call = self.calls[tostring(p.request_id or "")]
  if call == nil or call.kind ~= "cloud" then
    return
  end
  local okR, result = decode(p.result)
  local status = p.status == "ok" and "ok" or "error"
  self:complete(call, {
    status = status,
    error_code = status == "ok" and "ok" or Policy.code(p.error_code),
    http_status = tonumber(p.http_status),
    result = okR and result or nil,
    request_id = call.request_id,
  })
end

-- ── request / response (target side) ────────────────────────────────────────

--- handler(req, respond): req = { request_id, idempotency_key,
--- from_module_id, from_instance_id, capability, args, deadline };
--- respond(status, result, error_code, cursor) — exactly once, now or later.
function Rpc:onRequest(capability, handler)
  self.handlers[capability] = handler
end

--- The dedup key: the Agent-stamped sender together with the request id.
local function servedKey(fromModule, fromInstance, requestId)
  return tostring(fromModule or "") .. "@" .. tostring(fromInstance or "") .. "|" .. tostring(requestId)
end
M.servedKey = servedKey

function Rpc:servedPut(key, value)
  if self.served.map[key] == nil then
    self.served.order[#self.served.order + 1] = key
    while #self.served.order > L.target_dedup_ring do
      local old = table.remove(self.served.order, 1)
      self.served.map[old] = nil
      local oldId = old:match("|([^|]*)$")
      if oldId ~= nil and self.served.pendingById[oldId] == old then
        self.served.pendingById[oldId] = nil
      end
    end
  end
  self.served.map[key] = value
end

--- Answers the request stored under `key` (request id `requestId`).
function Rpc:respondKey(key, requestId, status, result, errorCode, cursor)
  if self.served.map[key] ~= "pending" then
    return false
  end
  status = status == "ok" and "ok" or "error"
  local code = status == "ok" and "ok" or Policy.code(errorCode)
  if status == "error" and code == "ok" then
    code = "internal_error"
  end
  local raw = encode(result == nil and {} or result)
  if raw == nil then
    status, code, raw = "error", "internal_error", "null"
  elseif #raw > L.result_bytes then
    status, code, raw = "error", "payload_too_large", "null"
  end
  cursor = cursor ~= nil and tostring(cursor) or ""
  if #cursor > L.cursor then
    status, code, raw, cursor = "error", "invalid_args", "null", ""
  end
  local params = { request_id = requestId, status = status, error_code = code, result = raw, cursor = cursor }
  self:servedPut(key, params)
  local superseded = self.served.pendingById[requestId] ~= key
  if not superseded then
    self.served.pendingById[requestId] = nil
  end
  self.counters.served = self.counters.served + 1
  if superseded then
    -- A later request from ANOTHER sender reused this request_id, so the
    -- Agent's route for it now leads to that sender (it only accepts a
    -- colliding id once the earlier route is gone). Sending this answer
    -- would deliver it to the wrong module: it is stored, not sent.
    self.counters.superseded = self.counters.superseded + 1
    return true
  end
  self.io.send("SBOS_MODULE_RESPONSE", params)
  return true
end

--- Sends the answer to a request this module received. Returns false when
--- the request is unknown or already answered.
function Rpc:respond(requestId, status, result, errorCode, cursor)
  local key = self.served.pendingById[requestId]
  if key == nil then
    return false
  end
  return self:respondKey(key, requestId, status, result, errorCode, cursor)
end

function Rpc:onIncomingRequest(p)
  if not self:authentic(p) then
    return
  end
  local id = tostring(p.request_id or "")
  if not Policy.validId(id) then
    return
  end
  local key = servedKey(p.from_module_id, p.from_instance_id, id)
  local held = self.served.map[key]
  if held ~= nil then
    -- A duplicated frame: the stored answer again, the handler not re-run.
    self.counters.served_duplicates = self.counters.served_duplicates + 1
    if type(held) == "table" then
      self.io.send("SBOS_MODULE_RESPONSE", held)
    end
    return
  end
  local deadline = tonumber(p.deadline)
  if deadline ~= nil and self.io.now() > deadline then
    return -- the requester has already given up
  end
  self:servedPut(key, "pending")
  self.served.pendingById[id] = key
  local capability = tostring(p.capability or "")
  local handler = self.handlers[capability]
  if handler == nil then
    self:respondKey(key, id, "error", nil, "capability_not_found")
    return
  end
  local okA, args = decode(p.args or "{}")
  if not okA or type(args) ~= "table" then
    self:respondKey(key, id, "error", nil, "invalid_args")
    return
  end
  local req = {
    request_id = id,
    idempotency_key = p.idempotency_key,
    from_module_id = p.from_module_id,
    from_instance_id = p.from_instance_id,
    capability = capability,
    args = args,
    deadline = deadline,
  }
  local ok = pcall(handler, req, function(status, result, code, cursor)
    return self:respondKey(key, id, status, result, code, cursor)
  end)
  if not ok then
    self:respondKey(key, id, "error", nil, "internal_error")
  end
end

return M
