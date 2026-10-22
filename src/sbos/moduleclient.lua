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
---   client.register()
---
--- Transport facts this module is built on: SendToDevice params are strings
--- on-controller (structured data travels JSON-encoded in one param); the
--- receiver's ExecuteCommand learns nothing about the sender, so the token
--- the Agent answers registration with is the only proof of identity.

local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local Envelope = require("sbos.envelope")
JSON = JSON or require("JSON")

local M = {}

M.PROTOCOL_MIN = 1
M.PROTOCOL_MAX = 1
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
local SEQ_STRIDE = 25

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

--- Persisted, monotonic sequence (stride-persisted like the telemetry queue:
--- a reload may skip up to 25 numbers, never repeat one).
function M.nextSequence()
  if state.seq == 0 then
    state.seq = tonumber(persist:get(SEQ_KEY, 0)) or 0
  end
  state.seq = state.seq + 1
  if state.seq % SEQ_STRIDE == 1 then
    persist:set(SEQ_KEY, state.seq + SEQ_STRIDE)
  end
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
  })
  armRegisterRetry()
  return true
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
    state.lastError = "registration refused: " .. tostring(tParams.reason or "unknown")
    log:warn("%s", state.lastError)
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
    local okA, a, r = pcall(state.opts.onConfig, settings, version)
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
  EC.SBOS_MODULE_REGISTERED = onRegistered
  EC.SBOS_MODULE_AGENT_HELLO = function(tParams)
    -- The Agent (re)started: our token is gone with its memory. Re-register.
    state.registered = false
    state.token = nil
    state.backoff = 30
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
  EC.SBOS_DRIVER_CONFIG = M.onConfig
end

function M.stop()
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
