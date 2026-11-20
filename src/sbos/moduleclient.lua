--- The module-side half of the SmartBuildOS module contract v1.
---
--- Every optional SmartBuildOS driver that wants the Agent's shared services
--- (registration, the event pipeline, versioned configuration, restricted
--- commands, snapshots) uses this ONE implementation — Flight Recorder today,
--- the reserved modules tomorrow. Mirror of the Agent's EC.SBOS_MODULE_*
--- handlers; the wire vocabulary is in docs/flight-recorder/PROTOCOL.md.
---
--- Usage (from OnDriverLateInit):
---   local client = require("sbos.moduleclient")
---   client.setup({ module_id = "flight_recorder", driver_version = v,
---                  capabilities = {...}, entitlements = {...}, commands = {...},
---                  event_types = {...}, singleton = true,
---                  status = function() return status, detail, counters end,
---                  onRegistered = fn(reply), onAgentState = fn(agent),
---                  onCommand = fn(request), onConfig = fn(settings, version) })
---                  (onConfig returns applied, refusedCount[, superseded]:
---                  superseded = true means a newer document is in force and
---                  this one was not applied; no ACK is sent for it)
---   client.register()
---
--- Transport facts this module is built on: SendToDevice params are strings
--- on-controller (structured data travels JSON-encoded in one param); the
--- receiver's ExecuteCommand learns nothing about the sender, so the token
--- the Agent answers registration with is the only proof of identity.
---
--- Contract v2 (docs/protocol/MODULE-CONTRACT-V2.md), negotiated 1..2:
---   setup opts add  manifest = { driver, version, capabilities = {...} }
---                   require_protocol = 2   (bus features needed; against a
---                                           v1-only Agent the module reports
---                                           agent_update_required and keeps
---                                           its v1 services)
---                   onDirectoryChanged = fn(version)
---                   claim_driver_config = false  (leave EC.SBOS_DRIVER_CONFIG
---                                           to the driver; default true)
---   calls          client.discover(filter, cb)
---                   client.subscribe(id, topics, onEvents, onResult)
---                   client.unsubscribe(id)
---                   client.request(to, capability, args, opts, cb)
---                   client.onRequest(capability, handler) / client.respond(...)
---                   client.cloudRequest(op, body, opts, cb)
---   Engine: sbos.modulerpc. Re-registration on SBOS_MODULE_AGENT_HELLO
---   re-sends every subscription once the Agent answers.

local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local Envelope = require("sbos.envelope")
local SeqBlock = require("sbos.seqblock")
local ModuleRpc = require("sbos.modulerpc")
local Policy = require("sbos.modulepolicy")
JSON = JSON or require("JSON")

local M = {}

M.PROTOCOL_MIN = Policy.PROTOCOL_MIN
M.PROTOCOL_MAX = Policy.PROTOCOL_MAX
--- Events staged locally while unregistered or awaiting the Agent's local
--- ack. Small on purpose: the Agent's queue is the durable one.
M.MAX_STAGED = 300
M.FRAME_EVENTS = Envelope.LIMITS.batch
M.ACK_TIMEOUT_SECONDS = 30
M.MAX_FRAME_TRIES = 3

local REGISTER_TIMER = "SbosModuleRegister"
local STATUS_TIMER = "SbosModuleStatus"
local TICK_TIMER = "SbosModuleTick"
local SEQ_KEY = "sbos_module_seq"

local state

local function fresh()
  return {
    opts = {},
    agentId = nil,
    token = nil,
    registered = false,
    protocol = nil,
    lastReply = nil,
    agent = { paired = false, connected = false, installation_id = nil, boot_id = nil, agent_version = nil },
    staged = {}, -- envelopes not yet framed
    pending = {}, -- batch_id -> { events, at, tries }
    pendingOrder = {},
    seq = 0,
    batchSeq = 0,
    backoff = 30,
    counters = { events_sent = 0, events_acked = 0, events_dropped_local = 0, frames_resent = 0, registrations = 0 },
    lastError = "",
    agentUpdateRequired = false,
    rpc = nil,
  }
end
state = fresh()

local function now()
  return os.time()
end

local function sendToAgent(command, params)
  if state.agentId == nil then
    return false
  end
  local ok = pcall(function()
    C4:SendToDevice(state.agentId, command, params)
  end)
  return ok
end

local function authParams(extra)
  local p = {
    module_id = state.opts.module_id,
    instance_id = tostring(C4:GetDeviceID()),
    token = state.token or "",
  }
  for k, v in pairs(extra or {}) do
    p[k] = v
  end
  return p
end

--- Persisted, monotonic sequence (sbos.seqblock: a reload may skip numbers,
--- never repeat one, because a repeated event id is dropped as a duplicate).
function M.nextSequence()
  if state.nextSeq == nil then
    state.nextSeq = SeqBlock.new(persist, SEQ_KEY)
  end
  state.seq = state.nextSeq()
  return state.seq
end

--- Builds an envelope in this module's identity. Returns env or nil + reason.
function M.event(fields)
  return Envelope.build(fields, {
    module_id = state.opts.module_id,
    instance_id = tostring(C4:GetDeviceID()),
    observed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    sequence = M.nextSequence(),
  })
end

local function statusTriple()
  if type(state.opts.status) == "function" then
    local ok, s, d, c = pcall(state.opts.status)
    if ok then
      return tostring(s or ""), tostring(d or ""), type(c) == "table" and c or {}
    end
  end
  return "", "", {}
end

local function csv(list)
  return table.concat(list or {}, ",")
end

--- Sends one status frame (liveness for the registry + counters for Studio).
function M.sendStatus(extra)
  if not state.registered then
    return false
  end
  local status, detail, counters = statusTriple()
  local merged = {}
  for k, v in pairs(counters) do
    merged[k] = v
  end
  for k, v in pairs(state.counters) do
    merged["client_" .. k] = v
  end
  merged.staged = #state.staged
  merged.pending_frames = #state.pendingOrder
  if state.rpc ~= nil then
    merged.bus = state.rpc.counters
  end
  local params = authParams({ status = status, detail = detail, counters = JSON:encode(merged) })
  for k, v in pairs(extra or {}) do
    params[k] = tostring(v)
  end
  return sendToAgent("SBOS_MODULE_STATUS", params)
end

local FLUSH_TIMER = "SbosModuleFlush"
local FLUSH_DELAY_MS = 2000

local function flushFrames()
  if not state.registered then
    return
  end
  CancelTimer(FLUSH_TIMER)
  while #state.staged > 0 and #state.pendingOrder < 4 do
    local events = {}
    while #state.staged > 0 and #events < M.FRAME_EVENTS do
      events[#events + 1] = table.remove(state.staged, 1)
    end
    state.batchSeq = state.batchSeq + 1
    local batchId = tostring(C4:GetDeviceID()) .. ":" .. tostring(state.batchSeq) .. ":" .. tostring(now())
    state.pending[batchId] = { events = events, at = now(), tries = 1 }
    state.pendingOrder[#state.pendingOrder + 1] = batchId
    sendToAgent("SBOS_MODULE_EVENTS", authParams({ batch_id = batchId, events = JSON:encode(events) }))
    state.counters.events_sent = state.counters.events_sent + #events
  end
end

--- Hands envelopes to the Agent. Returns how many were accepted into the
--- local stage (the rest were dropped, counted).
function M.sendEvents(envelopes)
  local accepted = 0
  for _, env in ipairs(envelopes or {}) do
    if Envelope.validate(env, state.opts.module_id) then
      state.staged[#state.staged + 1] = env
      accepted = accepted + 1
    else
      state.counters.events_dropped_local = state.counters.events_dropped_local + 1
    end
  end
  while #state.staged > M.MAX_STAGED do
    table.remove(state.staged, 1)
    state.counters.events_dropped_local = state.counters.events_dropped_local + 1
  end
  -- One frame per burst, not per event: a full frame goes now, a partial one
  -- waits two seconds for company (the Agent's upload tick is slower anyway).
  if #state.staged >= M.FRAME_EVENTS then
    flushFrames()
  elseif state.registered then
    SetTimer(FLUSH_TIMER, FLUSH_DELAY_MS, flushFrames)
  end
  return accepted
end

--- Sends whatever is staged now (driver destroy, explicit flush).
function M.flush()
  flushFrames()
end

--- Reports a restricted command's state back (Accepted … Unverified).
function M.commandResult(requestId, stateName, detail)
  return sendToAgent(
    "SBOS_MODULE_COMMAND_RESULT",
    authParams({
      request_id = tostring(requestId),
      state = tostring(stateName),
      detail = tostring(detail or ""):sub(1, 400),
    })
  )
end

--- Hands a finished diagnostic snapshot document to the Agent for upload.
function M.sendSnapshot(job)
  local ok, encoded = pcall(function()
    return JSON:encode(job.document or {})
  end)
  if not ok then
    return false
  end
  return sendToAgent(
    "SBOS_MODULE_SNAPSHOT",
    authParams({
      job_id = tostring(job.job_id),
      status = tostring(job.status or "completed"),
      document = encoded,
      request_id = tostring(job.request_id or ""),
    })
  )
end

local function tick()
  -- Resend frames the Agent never acked (its ack can be lost like any
  -- SendToDevice); after MAX_FRAME_TRIES they are dropped and counted. The
  -- Agent dedups event ids, so a resend after a lost ack is harmless.
  local keep = {}
  for _, id in ipairs(state.pendingOrder) do
    local frame = state.pending[id]
    if frame ~= nil then
      if now() - frame.at >= M.ACK_TIMEOUT_SECONDS then
        if frame.tries >= M.MAX_FRAME_TRIES or not state.registered then
          state.pending[id] = nil
          state.counters.events_dropped_local = state.counters.events_dropped_local + #frame.events
          state.lastError = "frame " .. id .. " never acknowledged by the Agent"
        else
          frame.tries = frame.tries + 1
          frame.at = now()
          state.counters.frames_resent = state.counters.frames_resent + 1
          sendToAgent("SBOS_MODULE_EVENTS", authParams({ batch_id = id, events = JSON:encode(frame.events) }))
          keep[#keep + 1] = id
        end
      else
        keep[#keep + 1] = id
      end
    end
  end
  state.pendingOrder = keep
  flushFrames()
end

local function armRegisterRetry()
  SetTimer(REGISTER_TIMER, state.backoff * ONE_SECOND, function()
    if not state.registered then
      state.backoff = math.min(state.backoff * 2, 300)
      M.register()
    end
  end)
end

--- Finds the Agent and sends the registration. Safe to call repeatedly.
function M.register()
  state.agentId = license.agentDeviceId()
  if state.agentId == nil then
    state.registered = false
    state.lastError = "no SmartBuildOS Agent in this project"
    if state.opts.onAgentState then
      pcall(state.opts.onAgentState, state.agent, "no_agent")
    end
    armRegisterRetry()
    return false
  end
  local o = state.opts
  sendToAgent("SBOS_MODULE_REGISTER", {
    module_id = o.module_id,
    instance_id = tostring(C4:GetDeviceID()),
    requester = tostring(C4:GetDeviceID()),
    driver_version = tostring(o.driver_version or ""),
    protocol_min = tostring(o.protocol_min or M.PROTOCOL_MIN),
    protocol_max = tostring(o.protocol_max or M.PROTOCOL_MAX),
    capabilities = csv(o.capabilities),
    entitlements = csv(o.entitlements),
    commands = csv(o.commands),
    event_types = csv(o.event_types),
    config_version = tostring(o.configVersion and o.configVersion() or ""),
    singleton = o.singleton ~= false and "true" or "false",
    status = select(1, statusTriple()),
    manifest = M.manifestParam(),
  })
  armRegisterRetry()
  return true
end

--- The v2 capability manifest as a registration param ("" when none). A v1
--- Agent ignores the extra param.
function M.manifestParam()
  local m = state.opts.manifest
  if type(m) ~= "table" then
    return nil
  end
  local doc = {
    driver = m.driver,
    version = m.version or state.opts.driver_version,
    protocol = Policy.PROTOCOL_MAX,
    capabilities = m.capabilities or {},
  }
  local ok, encoded = pcall(function()
    return JSON:encode(doc)
  end)
  return ok and encoded or nil
end

--- Whether this module needs a newer Agent than the one it registered with
--- (set require_protocol = 2 to depend on discovery / pub/sub / requests).
local function noteAgentProtocol(agentMax)
  local need = tonumber(state.opts.require_protocol) or 1
  local was = state.agentUpdateRequired
  state.agentUpdateRequired = need > 1 and (tonumber(agentMax) or 0) < need
  if state.agentUpdateRequired and not was then
    state.lastError = string.format(
      "agent_update_required: this driver needs SmartBuildOS Agent protocol %d (the Agent speaks %s)",
      need,
      tostring(agentMax)
    )
    log:warn("%s", state.lastError)
    if state.opts.onAgentState then
      pcall(state.opts.onAgentState, state.agent, "agent_update_required")
    end
  end
end

local function onRegistered(tParams)
  tParams = tParams or {}
  if tostring(tParams.module_id or "") ~= state.opts.module_id then
    return
  end
  state.lastReply = tParams
  if tostring(tParams.ok) ~= "true" then
    state.registered = false
    state.token = nil
    if state.rpc then
      state.rpc:onUnregistered()
    end
    state.lastError = "registration refused: " .. tostring(tParams.reason or "unknown")
    log:warn("%s", state.lastError)
    if tParams.reason == "incompatible_protocol" and tParams.agent_protocol_max ~= nil then
      noteAgentProtocol(tParams.agent_protocol_max)
    end
    if state.opts.onRegistered then
      pcall(state.opts.onRegistered, tParams)
    end
    -- A definitive refusal (incompatible / duplicate) is not retried every
    -- 30 s; the slow retry still notices an Agent update or a removed twin.
    state.backoff = 300
    armRegisterRetry()
    return
  end
  state.registered = true
  state.token = tostring(tParams.token or "")
  state.protocol = tonumber(tParams.protocol)
  state.backoff = 30
  state.counters.registrations = state.counters.registrations + 1
  state.agent.paired = tostring(tParams.paired) == "true"
  state.agent.connected = tostring(tParams.connected) == "true"
  state.agent.installation_id = tParams.installation_id
  state.agent.boot_id = tParams.boot_id
  state.agent.agent_version = tParams.agent_version
  CancelTimer(REGISTER_TIMER)
  -- A v1-only Agent sends no agent_protocol_max; the negotiated protocol
  -- is then its maximum.
  noteAgentProtocol(tParams.agent_protocol_max or state.protocol)
  state.rpc:onRegistered(state.protocol)
  log:info(
    "Registered with the SmartBuildOS Agent (device %s, protocol %s)",
    tostring(state.agentId),
    tostring(state.protocol)
  )
  if state.opts.onRegistered then
    pcall(state.opts.onRegistered, tParams)
  end
  SetTimer(STATUS_TIMER, 5 * ONE_MINUTE, function()
    M.sendStatus()
  end, true)
  SetTimer(TICK_TIMER, 15 * ONE_SECOND, tick, true)
  M.sendStatus()
  flushFrames()
end

--- Public so the driver can wire it as its config handler as well as the
--- Agent's generic SBOS_DRIVER_CONFIG forwarding.
function M.onConfig(tParams)
  tParams = tParams or {}
  local version = tostring(tParams.settings_version or tParams.desired_version or "")
  local okD, settings = pcall(function()
    return JSON:decode(tostring(tParams.settings or "{}"))
  end)
  local applied, refused = false, 1
  if okD and type(settings) == "table" and state.opts.onConfig then
    local okA, a, r, superseded = pcall(state.opts.onConfig, settings, version)
    if okA and superseded == true then
      -- The handler kept a NEWER document than this one (a replayed or late
      -- copy): nothing changed, so nothing is acknowledged — neither
      -- "applied" (it was not) nor "refused" (it was valid, only old).
      local kept = state.opts.configVersion and state.opts.configVersion() or "?"
      log:info("driver config v%s superseded by v%s; not applied", version, tostring(kept))
      return
    end
    if okA then
      applied = a == true
      refused = tonumber(r) or 0
    end
  end
  -- Ack on the existing path (the Agent audits it to Driver Cloud) AND on
  -- the module status frame (applied_config_version for Studio).
  local sku = tostring(tParams.sku or (state.opts.entitlements or {})[1] or "")
  sendToAgent("SBOS_DRIVER_CONFIG_ACK", {
    sku = sku,
    applied = applied and "true" or "false",
    refused = tostring(refused),
    settings_version = version,
    requester = tostring(C4:GetDeviceID()),
  })
  M.sendStatus({
    applied_config_version = applied and version or (state.opts.configVersion and state.opts.configVersion() or ""),
    config_error = applied and "" or ("v" .. version .. " refused"),
  })
end

function M.setup(opts)
  state = fresh()
  state.opts = opts or {}
  state.rpc = ModuleRpc.new({
    send = function(command, params)
      return sendToAgent(command, authParams(params))
    end,
    token = function()
      return state.token
    end,
    now = now,
    setTimer = function(id, ms, fn)
      SetTimer(id, ms, fn)
    end,
    cancelTimer = function(id)
      CancelTimer(id)
    end,
    newId = function()
      return ModuleRpc.newId(C4)
    end,
    onDirectoryChanged = function(version)
      if state.opts.onDirectoryChanged then
        state.opts.onDirectoryChanged(version)
      end
    end,
  })
  EC.SBOS_MODULE_REGISTERED = onRegistered
  -- Contract v2 frames (the engine checks each one carries our token).
  EC.SBOS_MODULE_DIRECTORY = function(tParams)
    state.rpc:onDirectory(tParams or {})
  end
  EC.SBOS_MODULE_DIRECTORY_CHANGED = function(tParams)
    state.rpc:onDirectoryChanged(tParams or {})
  end
  EC.SBOS_MODULE_SUBSCRIBED = function(tParams)
    state.rpc:onSubscribed(tParams or {})
  end
  EC.SBOS_MODULE_PUBLISH = function(tParams)
    state.rpc:onPublish(tParams or {})
  end
  EC.SBOS_MODULE_REQUEST_ACK = function(tParams)
    state.rpc:onRequestAck(tParams or {})
  end
  EC.SBOS_MODULE_REQUEST = function(tParams)
    state.rpc:onIncomingRequest(tParams or {})
  end
  EC.SBOS_MODULE_RESPONSE = function(tParams)
    state.rpc:onResponse(tParams or {})
  end
  EC.SBOS_MODULE_CLOUD_RESPONSE = function(tParams)
    state.rpc:onCloudResponse(tParams or {})
  end
  EC.SBOS_MODULE_AGENT_HELLO = function(tParams)
    -- The Agent (re)started: our token is gone with its memory. Re-register
    -- (and, once it answers, re-subscribe: subscriptions died with it too).
    state.registered = false
    state.token = nil
    state.backoff = 30
    state.rpc:onAgentHello()
    CancelTimer(STATUS_TIMER)
    if state.opts.onAgentState then
      pcall(state.opts.onAgentState, state.agent, "hello")
    end
    M.register()
  end
  EC.SBOS_MODULE_AGENT_STATE = function(tParams)
    tParams = tParams or {}
    state.agent.paired = tostring(tParams.paired) == "true"
    state.agent.connected = tostring(tParams.connected) == "true"
    if tParams.installation_id ~= nil then
      state.agent.installation_id = tParams.installation_id
    end
    if tParams.boot_id ~= nil then
      state.agent.boot_id = tParams.boot_id
    end
    if state.opts.onAgentState then
      pcall(state.opts.onAgentState, state.agent, "update")
    end
  end
  EC.SBOS_MODULE_EVENTS_ACK = function(tParams)
    tParams = tParams or {}
    local id = tostring(tParams.batch_id or "")
    local frame = state.pending[id]
    if frame == nil then
      return
    end
    state.pending[id] = nil
    local keep = {}
    for _, other in ipairs(state.pendingOrder) do
      if other ~= id then
        keep[#keep + 1] = other
      end
    end
    state.pendingOrder = keep
    local accepted = tonumber(tParams.accepted) or 0
    state.counters.events_acked = state.counters.events_acked + accepted
    local rejected = #frame.events - accepted
    if rejected > 0 then
      state.counters.events_dropped_local = state.counters.events_dropped_local + rejected
      state.lastError = "Agent rejected " .. rejected .. " event(s): " .. tostring(tParams.reason or "")
    end
    if state.opts.onAck then
      pcall(state.opts.onAck, id, accepted, tParams)
    end
    flushFrames()
  end
  EC.SBOS_MODULE_COMMAND = function(tParams)
    tParams = tParams or {}
    if tostring(tParams.token or "") == "" or tParams.token ~= state.token then
      -- Only the Agent that registered us knows our token.
      return
    end
    local okD, args = pcall(function()
      return JSON:decode(tostring(tParams.args or "{}"))
    end)
    local request = {
      request_id = tostring(tParams.request_id or ""),
      command = tostring(tParams.command or ""),
      args = okD and type(args) == "table" and args or {},
      expires_at = tonumber(tParams.expires_at),
      issued_at = tonumber(tParams.issued_at),
    }
    if request.request_id == "" then
      return
    end
    if request.expires_at ~= nil and now() > request.expires_at then
      M.commandResult(request.request_id, "Expired", "arrived after its expiry")
      return
    end
    M.commandResult(request.request_id, "Accepted", "")
    if state.opts.onCommand then
      local ok, err = pcall(state.opts.onCommand, request)
      if not ok then
        M.commandResult(request.request_id, "Failed", tostring(err))
      end
    else
      M.commandResult(request.request_id, "Failed", "module handles no commands")
    end
  end
  EC.SBOS_MODULE_SNAPSHOT_ACK = function(tParams)
    if state.opts.onSnapshotAck then
      pcall(state.opts.onSnapshotAck, tParams or {})
    end
  end
  -- `claim_driver_config = false` leaves EC.SBOS_DRIVER_CONFIG to the driver
  -- (a driver whose remote settings already run through sbos.mirror, such as
  -- Atmosphere, must not lose them to a helper that calls setup). Default:
  -- the client takes it, as before.
  if state.opts.claim_driver_config ~= false then
    EC.SBOS_DRIVER_CONFIG = M.onConfig
  end
end

function M.stop()
  if state.rpc ~= nil then
    state.rpc:stop()
  end
  CancelTimer(FLUSH_TIMER)
  CancelTimer(REGISTER_TIMER)
  CancelTimer(STATUS_TIMER)
  CancelTimer(TICK_TIMER)
  if state.registered then
    sendToAgent("SBOS_MODULE_UNREGISTER", authParams({}))
  end
  state.registered = false
end

function M.isRegistered()
  return state.registered
end

-- ── contract v2 calls (sbos.modulerpc; no-ops with an error code until a
--    v2 registration exists) ──────────────────────────────────────────────

local function rpc()
  if state.rpc == nil then
    error("sbos.moduleclient: call setup() first")
  end
  return state.rpc
end

function M.discover(filter, cb)
  return rpc():discover(filter, cb)
end

function M.subscribe(id, topics, onEvents, onResult)
  return rpc():subscribe(id, topics, onEvents, onResult)
end

function M.unsubscribe(id)
  return rpc():unsubscribe(id)
end

function M.request(to, capability, args, opts, cb)
  return rpc():request(to, capability, args, opts, cb)
end

function M.onRequest(capability, handler)
  return rpc():onRequest(capability, handler)
end

function M.respond(requestId, status, result, errorCode, cursor)
  return rpc():respond(requestId, status, result, errorCode, cursor)
end

function M.cloudRequest(op, body, opts, cb)
  return rpc():cloudRequest(op, body, opts, cb)
end

--- The negotiated protocol (nil until registered).
function M.protocol()
  return state.protocol
end

--- True when require_protocol is higher than what the Agent speaks.
function M.agentUpdateRequired()
  return state.agentUpdateRequired
end

function M.busCounters()
  return state.rpc and state.rpc.counters or {}
end

function M.agent()
  return state.agent
end

function M.agentId()
  return state.agentId
end

function M.lastError()
  return state.lastError
end

function M.counters()
  return state.counters
end

--- The derived display status (the registry's vocabulary), from what this
--- side knows: no Agent / refused / unpaired / connection.
function M.displayStatus()
  if state.agentId == nil then
    return "waiting_for_agent"
  end
  if state.agentUpdateRequired then
    return "agent_update_required"
  end
  if not state.registered then
    local reason = state.lastReply and tostring(state.lastReply.reason or "") or ""
    if reason == "incompatible_protocol" then
      return "incompatible"
    end
    return "waiting_for_agent"
  end
  if not state.agent.paired then
    return "unpaired"
  end
  if not state.agent.connected then
    return "degraded"
  end
  return "ready"
end

function M.describe()
  return string.format(
    "agent=%s registered=%s protocol=%s paired=%s connected=%s staged=%d pending=%d sent=%d acked=%d dropped=%d",
    tostring(state.agentId or "NOT FOUND"),
    tostring(state.registered),
    tostring(state.protocol),
    tostring(state.agent.paired),
    tostring(state.agent.connected),
    #state.staged,
    #state.pendingOrder,
    state.counters.events_sent,
    state.counters.events_acked,
    state.counters.events_dropped_local
  )
end

function M._reset()
  state = fresh()
end

function M._state()
  return state
end

return M
