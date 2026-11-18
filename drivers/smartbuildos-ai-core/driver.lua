--[[==========================================================================
  SmartBuildOS AI Core
  The controller-side half of SmartBuildOS AI Core: Composer programming,
  properties, variables and events for an AI that runs in the SmartBuildOS
  cloud — never on the controller, and never with an API key here.

  What this driver does:
    COMMANDS   ten Composer commands (AI_ASK … AI_SEND_NOTIFICATION): each
               is validated and bounded, recorded as an ai_core.* envelope
               for the Agent's durable queue and (all but AI_RECORD_EVENT)
               sent as ONE cloud op through the Agent's module contract v2
               relay. The cloud answers at once: accepted with a job id
               (the result arrives later as deliver_result), completed with
               no job (set_context, send_notification: nothing follows), or
               a refusal shown as it is.
    RESULTS    six restricted operations from the platform (apply_config,
               refresh_status, deliver_result, raise_event, set_learning,
               run_diagnostic). None controls equipment, runs code or names
               a command to forward: device actions go through the Agent's
               existing command queue, never through this driver.
    EVENTS     collection without double capture: Flight Recorder topics
               are consumed when it is installed; this driver's own
               collector covers only what the Flight Recorder does not
               (Director system events; Agent events and selected variables
               when no Flight Recorder exists). Exclusions and the paused
               state apply before anything is recorded.
    RECOVERY   a small persisted buffer of critical events while no Agent
               answers, drained in order on recovery; drops are counted.

  The Agent (smartbuildos.c4z) supplies registration, the event pipeline,
  configuration delivery, restricted commands, the cloud relay and
  licensing (SKU SBOS_AI_CORE). Needs Agent protocol 2.

  Pure rules: src/aicore/{vocab,commands,config,operations,buffer,collector,
  state,diagnostic}.lua and src/sbos/* — all tested without a controller.
  Reference: docs/ai-core/DRIVER.md. Nothing here has run on a physical
  controller (emulator and unit tests only).
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-ai-core.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-ai-core.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

-- Every src/ module at module scope: the build's squish step only sees what
-- loads here (a require inside a function is left out of the .c4z).
local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local client = require("sbos.moduleclient")
local V = require("aicore.vocab")
local Commands = require("aicore.commands")
local Config = require("aicore.config")
local Operations = require("aicore.operations")
local Buffer = require("aicore.buffer")
local Collector = require("aicore.collector")
local State = require("aicore.state")
local Diagnostic = require("aicore.diagnostic")

gInitialized = false

local CONFIG_KEY = "aicore_config_v1"
local LEARNING_KEY = "aicore_learning_v1"
local BUFFER_KEY = "aicore_buffer_v1"
local LAST_KEY = "aicore_last_v1"
local TICK_TIMER = "AiCoreTick"
local LIVENESS_TIMER = "AiCoreLiveness"
local DISCOVER_TIMER = "AiCoreDiscover"
local TICK_SECONDS = 30
local LIVENESS_SECONDS = 5 * 60
local FR_SUBSCRIPTION = "fr"

--- AUTHORIZED statuses carry a feature list the backend issued; only then
--- is a missing feature a definite "no".
local AUTHORIZED =
  { AUTHORIZED_SUBSCRIPTION = true, AUTHORIZED_PERPETUAL = true, AUTHORIZED_GRACE = true, TRIAL = true }

local gConfig = Config.default()
local gConfigVersion = 0
local gConfigError = ""
local gLearning = { active = true, source = "default", reason = "" }
local gBuffer = nil
local gCollector = nil
local gBucket = nil
local gPlan = { subscribe = false, system_events = false, agent_events = false, variables = false }
--- What is known about the Flight Recorder (from the Agent's directory).
local gFr = { state = "unknown", instance_id = nil, capabilities = {}, subscribed = false, granted = nil }
local gSystemEvents = {} -- id -> true (registered with Director)
local gVarListeners = {} -- "dev:var" -> { device_id, variable_id, name, seen }
local gJobs = {} -- job id -> { command, request_id, at }
local gJobOrder = {}
local gAgentLost = false
local gCloudUnreachable = false
local gLicenceHalted = false
local gPrev = { code = nil, connected = nil }
local gCounters = {
  commands = 0,
  refused_local = 0,
  cloud_accepted = 0,
  cloud_completed = 0,
  cloud_refused = 0,
  cloud_unreachable = 0,
  events_recorded = 0,
  events_buffered = 0,
  events_unrecordable = 0,
  events_staged_without_agent = 0,
  results_delivered = 0,
  events_raised = 0,
  operations = 0,
  operations_refused = 0,
  liveness_failures = 0,
  jobs_expired = 0,
  jobs_dropped = 0,
  system_events = 0,
  variable_events = 0,
  agent_events = 0,
}
--- What programming and the properties show; persisted so a reload keeps it.
local gLast = {
  response_id = "",
  response = "",
  request_id = "",
  event_detail = "",
  event_correlation_id = "",
  error = "",
  error_kind = nil,
  refusal = nil,
  sync_at = nil,
  cloud_result = "none",
  test = "none",
  pending_approvals = 0,
  recommendation_count = 0,
}

-- ─── Small helpers ─────────────────────────────────────────────────────────

local function now()
  return os.time()
end

local function setVar(name, value)
  pcall(function()
    C4:SetVariable(name, value)
  end)
end

local function fire(key)
  local id = V.EVENT_ID[key]
  if id == nil then
    return false
  end
  return pcall(function()
    C4:FireEventByID(id)
  end)
end

local function saveLast()
  persist:set(LAST_KEY, gLast)
end

local function stamp(t)
  return t and os.date("%Y-%m-%d %H:%M:%S", t) or "never"
end

--- kind: what produced the error ("cloud" ones are cleared by the next
--- accepted cloud answer; local refusals stay until something replaces them).
local function setError(message, kind)
  message = tostring(message or ""):sub(1, V.LIMITS.error_text)
  gLast.error = message
  gLast.error_kind = message ~= "" and (kind or "local") or nil
  setVar("AI_LAST_ERROR", message)
  UpdateProperty("Last Error", message ~= "" and message or "none")
  saveLast()
  if message ~= "" then
    log:warn("%s", message)
  end
end

local function newRequestId()
  local ok, uuid = pcall(function()
    return C4:UUID("RANDOM")
  end)
  local core
  if ok and type(uuid) == "string" and uuid:match("^[%w%-]+$") then
    core = uuid:lower()
  else
    core = string.format("%x%x%04x", os.time(), math.random(0, 0x7fffffff), math.random(0, 0xffff))
  end
  return "aic-" .. core
end

--- Project rooms and devices as Director lists them (GetDevices: the key
--- is deviceName; rooms appear through the devices they hold).
local function projectDevices()
  local ok, list = pcall(function()
    return C4:GetDevices({})
  end)
  local out = {}
  if ok and type(list) == "table" then
    for rawId, d in pairs(list) do
      local id = tonumber(rawId)
      if id ~= nil and type(d) == "table" then
        out[id] = { name = d.deviceName, room_id = tonumber(d.roomId), room_name = d.roomName }
      end
    end
  end
  return out
end

local function projectRooms()
  local rooms = {}
  for _, d in pairs(projectDevices()) do
    if d.room_id ~= nil and d.room_name ~= nil then
      rooms[d.room_id] = d.room_name
    end
  end
  return rooms
end

--- Licence gate for ONE privileged action. Nil = allowed. Refuses only on a
--- definitive denial with enforcement on, or when an AUTHORIZED answer under
--- enforcement lacks the feature; every uncertain state is allowed.
local function licenceBlocks(feature)
  if license.enforces() then
    return "not licensed: " .. tostring(license.statusLabel())
  end
  if
    feature ~= nil
    and license.enforcementMode() == "enforce"
    and AUTHORIZED[license.status()]
    and not license.hasFeature(feature)
  then
    return "the licence does not include " .. feature
  end
  return nil
end

local function learningActive()
  return gLearning.active == true
end

-- ─── Recording (stage → Agent queue; buffer while no Agent answers) ───────

--- Builds an envelope in this module's identity and routes it. Returns the
--- envelope (or nil when the envelope itself was refused).
local function record(fields)
  local env, why = client.event(fields)
  if env == nil then
    gCounters.events_unrecordable = gCounters.events_unrecordable + 1
    log:warn("Event refused by the envelope rules (%s): %s", tostring(why), tostring(fields.event_type))
    return nil
  end
  gCounters.events_recorded = gCounters.events_recorded + 1
  local reachable = client.isRegistered() and not gAgentLost
  if reachable then
    client.sendEvents({ env })
  elseif Buffer.isCritical(env) then
    local outcome = gBuffer:push(env)
    if outcome == "held" then
      gCounters.events_buffered = gCounters.events_buffered + 1
    end
  else
    -- Not critical: the module client's in-memory stage (bounded,
    -- drop-oldest, counted) holds it until the Agent registers us again.
    gCounters.events_staged_without_agent = gCounters.events_staged_without_agent + 1
    client.sendEvents({ env })
  end
  return env
end

local function flushBuffer()
  if gBuffer == nil or gBuffer:depth() == 0 then
    return 0
  end
  local n = gBuffer:drain(function(env)
    client.sendEvents({ env })
  end)
  log:info("Flushed %d buffered critical event(s) to the Agent", n)
  return n
end

-- ─── Status (properties, variables, events) ────────────────────────────────

local function facts()
  local agent = client.agent()
  local pending = 0
  for _ in pairs(gJobs) do
    pending = pending + 1
  end
  return {
    agentFound = client.agentId() ~= nil,
    registered = client.isRegistered(),
    agentUpdateRequired = client.agentUpdateRequired(),
    agentLost = gAgentLost,
    paired = agent.paired,
    connected = agent.connected,
    cloudUnreachable = gCloudUnreachable,
    licenceHalted = gLicenceHalted,
    licenceLabel = license.statusLabel(),
    pendingJobs = pending,
    learningActive = learningActive(),
    lastRefusal = gLast.refusal,
  }
end

local function telemetryText()
  local c = client.counters()
  local b = gBuffer and gBuffer:counters() or { depth = 0, dropped = 0 }
  local staged = #client._state().staged
  if not learningActive() then
    return string.format("Learning paused: nothing collected (buffer %d, dropped %d)", b.depth, b.dropped)
  end
  if client.isRegistered() and not gAgentLost then
    return string.format(
      "Through the Agent: %d sent, %d acknowledged, %d dropped; buffer %d, buffer drops %d",
      c.events_sent,
      c.events_acked,
      c.events_dropped_local,
      b.depth,
      b.dropped
    )
  end
  return string.format(
    "No Agent answering: %d critical event(s) buffered, %d waiting in memory, %d dropped",
    b.depth,
    staged,
    b.dropped + c.events_dropped_local
  )
end

local function learningText()
  if gLicenceHalted then
    return "Stopped (not licensed)"
  end
  if gLearning.active then
    return "Active"
  end
  local why = gLearning.reason ~= "" and (": " .. gLearning.reason) or ""
  return "Paused by " .. tostring(gLearning.source) .. why
end

local function frText()
  local s = gFr.state
  if s == "present" then
    return "Installed: local history served"
      .. (gFr.subscribed and "; topics subscribed" or (gPlan.subscribe and "; subscribing" or ""))
  elseif s == "present_v1" then
    return "Installed (no local history service; update the Flight Recorder)"
  elseif s == "absent" then
    return "Not installed: AI Core collects its minimal set itself"
  end
  return "Unknown (needs Agent protocol 2)"
end

local function statusCounters()
  local c = {}
  for k, v in pairs(gCounters) do
    c[k] = v
  end
  local b = gBuffer and gBuffer:counters() or {}
  c.buffer_depth = b.depth or 0
  c.buffer_dropped = b.dropped or 0
  c.buffer_flushed = b.flushed or 0
  c.events_staged = #client._state().staged
  c.events_sent = client.counters().events_sent
  c.events_dropped = (b.dropped or 0) + client.counters().events_dropped_local
  c.requests = gCounters.commands
  c.refusals = gCounters.refused_local + gCounters.cloud_refused
  c.last_cloud_result = gLast.cloud_result
  if gCollector then
    for k, v in pairs(gCollector.counters) do
      c["collector_" .. k] = v
    end
  end
  c.applied_config_version = gConfigVersion
  c.config_error = gConfigError
  c.learning_active = learningActive()
  c.flight_recorder = gFr.state
  c.flight_recorder_subscribed = gFr.subscribed
  return c
end

local refresh -- forward (paint ↔ transitions ↔ collection)
local applyCollection
local discoverFlightRecorder

local function emitStatus(reason, code, previous)
  local f = facts()
  local warn = code ~= "ready" and code ~= "unlicensed"
  record({
    event_type = "ai_core.status",
    evidence_source = "derived",
    severity = warn and "warning" or "info",
    label = "AI Core " .. tostring(code),
    payload = {
      reason = reason,
      -- never a key named `code`: the envelope redacts it as a credential
      state = code,
      previous_state = previous,
      agent_connected = State.agentConnected(f),
      flight_recorder = gFr.state,
      learning_active = learningActive(),
      buffer_depth = gBuffer and gBuffer:depth() or 0,
      buffer_dropped = gBuffer and gBuffer:counters().dropped or 0,
      applied_config_version = gConfigVersion,
      pending_jobs = f.pendingJobs,
    },
  })
end

refresh = function(reason)
  local f = facts()
  local code = State.code(f)
  local connected = State.agentConnected(f)
  UpdateProperty("SmartBuildOS Connection Status", State.CONNECTION_TEXT[code])
  UpdateProperty("Agent Pairing Status", State.pairingText(f))
  UpdateProperty("AI Status", State.aiStatusText(code, f))
  UpdateProperty("Telemetry Status", telemetryText())
  UpdateProperty("Learning Status", learningText())
  UpdateProperty("Flight Recorder Link", frText())
  UpdateProperty("Last Synchronization", stamp(gLast.sync_at))
  UpdateProperty("Last Test Result", gLast.test)
  UpdateProperty("Property ID", gConfig.property_id or "Not delivered yet (System Studio)")
  UpdateProperty("Controller ID", gConfig.controller_id or "Not delivered yet (System Studio)")
  UpdateProperty("AI Provider", gConfig.provider.name or "Not configured (System Studio)")
  UpdateProperty("AI Model", gConfig.provider.model or "Not configured (System Studio)")
  UpdateProperty("AI API Credential", gConfig.credential_status or "Not configured")
  UpdateProperty(
    "Permission Mode",
    gConfig.permission_mode and (gConfig.permission_mode .. " (set in System Studio)")
      or "Not delivered yet (System Studio owns it)"
  )
  setVar("AI_STATUS", State.variable(code, f))
  setVar("AGENT_CONNECTED", connected and "true" or "false")
  setVar("LEARNING_ACTIVE", learningActive() and "true" or "false")
  setVar("AI_PENDING_APPROVALS", gLast.pending_approvals)
  setVar("AI_RECOMMENDATION_COUNT", gLast.recommendation_count)

  -- Transitions only.
  if gPrev.connected == true and not connected then
    fire("agent_disconnected")
    gLast.event_detail = "Agent disconnected: " .. State.CONNECTION_TEXT[code]
    setVar("AI_LAST_EVENT_DETAIL", gLast.event_detail)
    log:warn("SmartBuildOS Agent disconnected (%s)", code)
  end
  gPrev.connected = connected
  if gPrev.code ~= code then
    local previous = gPrev.code
    gPrev.code = code
    if gInitialized then
      emitStatus(reason or "transition", code, previous)
    end
  end
end

-- ─── Configuration ─────────────────────────────────────────────────────────

local function persistConfig()
  persist:set(CONFIG_KEY, { cfg = gConfig, version = gConfigVersion, error = gConfigError })
end

--- Validates the WHOLE document; applies it or keeps the last valid one.
--- @return boolean applied, table refusals
local function applyConfig(raw, version, source)
  local cfg, refusals = Config.validate(raw)
  if cfg == nil then
    gConfigError = "v" .. tostring(version) .. " refused: " .. Config.describeRefusals(refusals)
    persistConfig()
    setError("Configuration " .. gConfigError .. " (v" .. tostring(gConfigVersion) .. " kept)", "config")
    refresh("config_refused")
    return false, refusals
  end
  gConfig = cfg
  gConfigVersion = tonumber(version) or gConfigVersion
  gConfigError = ""
  -- The document's learning flag is the platform's latest word on learning
  -- (a licence without AI_LEARNING keeps it paused, and says so).
  local learningBlock = cfg.learning.active and licenceBlocks("AI_LEARNING") or nil
  gLearning = { active = cfg.learning.active and learningBlock == nil, source = source, reason = learningBlock or "" }
  persist:set(LEARNING_KEY, gLearning)
  persistConfig()
  gLast.sync_at = now()
  saveLast()
  if gLast.error_kind == "config" then
    setError("")
  end
  applyCollection()
  refresh("config_applied")
  log:info("AI Core configuration v%s applied (%s)", tostring(gConfigVersion), tostring(source))
  return true, refusals
end

-- ─── Collection ────────────────────────────────────────────────────────────

local function registerSystemEvents(want)
  if want then
    if C4.RegisterSystemEvent == nil then
      return
    end
    for _, e in ipairs(Collector.SYSTEM_EVENTS) do
      if not gSystemEvents[e.id] then
        local ok = pcall(function()
          C4:RegisterSystemEvent(e.id, 0)
        end)
        if ok then
          gSystemEvents[e.id] = true
        end
      end
    end
  else
    for id in pairs(gSystemEvents) do
      pcall(function()
        C4:UnregisterSystemEvent(id, 0)
      end)
      gSystemEvents[id] = nil
    end
  end
end

local function variableIdByName(deviceId, name)
  local ok, vars = pcall(function()
    return C4:GetDeviceVariables(deviceId)
  end)
  if not ok or type(vars) ~= "table" then
    return nil
  end
  for varId, v in pairs(vars) do
    if type(v) == "table" and v.name == name then
      return tonumber(varId)
    end
  end
  return nil
end

local function applyVariableListeners(want)
  local desired = {}
  if want then
    for _, s in ipairs(gConfig.collection.variables) do
      local varId = variableIdByName(s.device_id, s.variable)
      if varId ~= nil then
        desired[s.device_id .. ":" .. varId] = { device_id = s.device_id, variable_id = varId, name = s.variable }
      end
    end
  end
  for key, l in pairs(gVarListeners) do
    if desired[key] == nil then
      pcall(function()
        C4:UnregisterVariableListener(l.device_id, l.variable_id)
      end)
      gVarListeners[key] = nil
    end
  end
  for key, l in pairs(desired) do
    if gVarListeners[key] == nil then
      gVarListeners[key] = l
      local ok = pcall(function()
        C4:RegisterVariableListener(l.device_id, l.variable_id)
      end)
      if not ok then
        gVarListeners[key] = nil
      end
    end
  end
end

local function onFlightRecorderEvents(events, dropped)
  local admitted = gCollector:consume(events, dropped)
  if #admitted > 0 then
    gFr.last_event_at = now()
  end
end

applyCollection = function()
  if gCollector == nil then
    return
  end
  gLicenceHalted = license.enforces()
  local active = learningActive() and not gLicenceHalted
  gPlan = Collector.plan(gFr.state, gConfig, active)
  gCollector:setPolicy({
    active = active,
    excludedRooms = Config.excludedRoomSet(gConfig),
    excludedCategories = Config.excludedCategorySet(gConfig),
    maxPerMinute = gConfig.collection.max_events_per_minute,
  })
  registerSystemEvents(gPlan.system_events)
  applyVariableListeners(gPlan.variables)
  if gPlan.subscribe then
    if not gFr.subscribed and gFr.subscription_requested ~= true then
      gFr.subscription_requested = true
      local ok, code = client.subscribe(FR_SUBSCRIPTION, Collector.FR_TOPICS, onFlightRecorderEvents, function(accepted)
        gFr.subscription_requested = false
        gFr.subscribed = accepted == true
        refresh("subscription")
      end)
      if not ok then
        gFr.subscription_requested = false
        log:warn("Flight Recorder subscription not sent: %s", tostring(code))
      end
    end
  elseif gFr.subscribed or gFr.subscription_requested then
    client.unsubscribe(FR_SUBSCRIPTION)
    gFr.subscribed = false
    gFr.subscription_requested = false
  end
end

--- Reads the Flight Recorder's entry from the Agent's directory. Doubles as
--- the Agent liveness probe: no directory by the deadline = not answering.
discoverFlightRecorder = function(why)
  if not client.isRegistered() or (client.protocol() or 0) < 2 then
    return false
  end
  return client.discover({ module_id = "flight_recorder" }, function(directory, code)
    if code == "ok" then
      local recovered = gAgentLost
      gAgentLost = false
      if recovered then
        log:info("SmartBuildOS Agent answering again")
        flushBuffer()
      end
      local found = nil
      -- An entry that is not an object is skipped, never indexed: the
      -- directory is the Agent's, but a malformed one must not throw here.
      for _, m in ipairs(type(directory.modules) == "table" and directory.modules or {}) do
        if type(m) == "table" and m.module_id == "flight_recorder" and m.stale ~= true then
          found = m
        end
      end
      local state = "absent"
      local caps = {}
      if found ~= nil then
        for _, cap in ipairs(type(found.capabilities) == "table" and found.capabilities or {}) do
          local id = type(cap) == "table" and cap.id or cap
          if type(id) == "string" then
            caps[id] = true
          end
        end
        state = ((tonumber(found.protocol) or 1) >= 2 and caps["events.subscribe"]) and "present" or "present_v1"
      end
      local changed = state ~= gFr.state or tostring(found and found.instance_id) ~= tostring(gFr.instance_id)
      if changed then
        -- A new Flight Recorder instance needs a fresh subscription.
        if gFr.subscribed then
          client.unsubscribe(FR_SUBSCRIPTION)
        end
        gFr = { state = state, instance_id = found and found.instance_id, capabilities = caps, subscribed = false }
        log:info("Flight Recorder: %s", state)
      end
      applyCollection()
      refresh("discovery")
    elseif code == "deadline_exceeded" or code == "target_unavailable" then
      gCounters.liveness_failures = gCounters.liveness_failures + 1
      if not gAgentLost then
        gAgentLost = true
        log:warn("SmartBuildOS Agent did not answer (%s, %s)", tostring(code), tostring(why))
      end
      refresh("liveness")
      client.register()
    else
      log:warn("Directory request refused: %s", tostring(code))
    end
  end)
end

local function discoverSoon()
  SetTimer(DISCOVER_TIMER, 2 * ONE_SECOND, function()
    discoverFlightRecorder("directory_changed")
  end)
end

-- ─── Jobs (requests accepted by the cloud, waiting for deliver_result) ─────

local function addJob(jobId, command, requestId)
  if gJobs[jobId] == nil then
    gJobOrder[#gJobOrder + 1] = jobId
  end
  gJobs[jobId] = { command = command, request_id = requestId, at = now() }
  while #gJobOrder > V.LIMITS.pending_jobs do
    local old = table.remove(gJobOrder, 1)
    if gJobs[old] ~= nil then
      gJobs[old] = nil
      gCounters.jobs_dropped = gCounters.jobs_dropped + 1
    end
  end
end

local function finishJob(jobId, requestId)
  for i = #gJobOrder, 1, -1 do
    local id = gJobOrder[i]
    local j = gJobs[id]
    if j ~= nil and (id == jobId or (requestId ~= nil and j.request_id == requestId)) then
      gJobs[id] = nil
      table.remove(gJobOrder, i)
    end
  end
end

local function expireJobs()
  for i = #gJobOrder, 1, -1 do
    local id = gJobOrder[i]
    local j = gJobs[id]
    if j == nil then
      table.remove(gJobOrder, i)
    elseif now() - j.at > V.LIMITS.job_ttl_seconds then
      gJobs[id] = nil
      table.remove(gJobOrder, i)
      gCounters.jobs_expired = gCounters.jobs_expired + 1
    end
  end
end

-- ─── Composer commands → envelope + cloud op ───────────────────────────────

local function refuseLocally(name, code, message)
  gCounters.refused_local = gCounters.refused_local + 1
  gLast.refusal = "refused locally (" .. tostring(code) .. ")"
  setError(name .. " refused: " .. tostring(message))
  refresh("refused")
end

local function onCloudAnswer(name, requestId, answer)
  local r = Commands.interpret(answer)
  gLast.cloud_result = name .. ": " .. r.outcome .. (r.code ~= "ok" and (" (" .. r.code .. ")") or "")
  if r.outcome == "accepted" then
    gCounters.cloud_accepted = gCounters.cloud_accepted + 1
    gCloudUnreachable = false
    gLast.refusal = nil
    gLast.sync_at = now()
    addJob(r.job_id, name, requestId)
    if gLast.error_kind == "cloud" then
      setError("")
    end
  elseif r.outcome == "completed" then
    -- Done now (set_context, send_notification): no job, nothing to wait
    -- for, and no AI Response Ready — no result will ever be delivered.
    gCounters.cloud_completed = gCounters.cloud_completed + 1
    gCloudUnreachable = false
    gLast.refusal = nil
    gLast.sync_at = now()
    if gLast.error_kind == "cloud" then
      setError("")
    end
  elseif r.outcome == "unreachable" then
    gCounters.cloud_unreachable = gCounters.cloud_unreachable + 1
    gCloudUnreachable = r.code == "cloud_unreachable"
    gLast.refusal = "not delivered (" .. r.code .. ")"
    setError(name .. ": " .. r.message, "cloud")
  else
    gCounters.cloud_refused = gCounters.cloud_refused + 1
    gLast.refusal = "refused (" .. r.code .. ")"
    setError(name .. ": " .. r.message, "cloud")
  end
  saveLast()
  refresh("cloud_answer")
end

local function cloud(cmd, requestId, extra)
  client.cloudRequest(cmd.op, Commands.body(cmd, requestId, extra), { idempotency_key = requestId }, function(answer)
    onCloudAnswer(cmd.name, requestId, answer)
  end)
end

--- Asks the Flight Recorder for the target's recent local events (when it
--- can be asked) and records ONE ai_core.diagnostic envelope saying what it
--- found — or why there is nothing. done(env, fields).
local function runDiagnostic(target, requestId, source, done)
  local capability = target.device_id ~= nil and "events.device_history" or "events.room_activity"
  local frState = gFr.state
  if frState == "present" and not gFr.capabilities[capability] then
    frState = "present_v1"
  end
  local function finish(answer)
    local fields = Diagnostic.fields(target, { state = frState, answer = answer }, requestId, source)
    local env = record(fields)
    done(env, fields)
  end
  if frState ~= "present" then
    finish(nil)
    return
  end
  local args = { limit = Diagnostic.LIMITS.events }
  if target.device_id ~= nil then
    args.device_id = target.device_id
  else
    args.room_id = target.room_id
  end
  client.request("flight_recorder", capability, args, { timeout = 10, retries = 1 }, finish)
end

local function runCommand(name, params)
  if not gInitialized then
    return
  end
  gCounters.commands = gCounters.commands + 1
  local spec = Commands.SPECS[name]
  local block = licenceBlocks(spec.feature)
  if block ~= nil then
    refuseLocally(name, "not_permitted", block)
    return
  end
  if not gBucket.take() then
    refuseLocally(name, "rate_limited", "more than " .. V.LIMITS.commands_per_minute .. " AI commands a minute")
    return
  end
  local cmd, refusal = Commands.build(name, params, {
    rooms = projectRooms,
    devices = projectDevices,
    excludedRooms = Config.excludedRoomSet(gConfig),
    learningActive = learningActive(),
  })
  if cmd == nil then
    refuseLocally(name, refusal.code, refusal.message)
    return
  end
  local requestId = newRequestId()
  gLast.request_id = requestId
  setVar("AI_LAST_REQUEST_ID", requestId)
  saveLast()

  if name == "AI_RECORD_EVENT" then
    -- AI Core's own marker: exclusions and the paused state apply first.
    local ok, why = gCollector:admit({ room_id = cmd.args.room_id, category = cmd.args.category })
    if not ok then
      refuseLocally(name, "not_permitted", "not recorded (" .. why .. ")")
      return
    end
    record(Commands.envelope(cmd, requestId))
    refresh("recorded")
    return
  end
  if (client.protocol() or 0) < 2 and client.isRegistered() then
    refuseLocally(name, "incompatible_protocol", "the SmartBuildOS Agent must be updated (module contract v2)")
    return
  end
  if name == "AI_START_DIAGNOSTIC" then
    local target = {
      device_id = cmd.args.device_id,
      device_name = cmd.args.device_name,
      room_id = cmd.args.room_id or cmd.device_room_id,
      room_name = cmd.args.room_name,
    }
    if cmd.args.device_id ~= nil then
      target.room_id = nil -- a device target is asked by device
    end
    runDiagnostic(target, requestId, name, function(diagEnv, fields)
      record(Commands.envelope(cmd, requestId))
      cloud(cmd, requestId, {
        diagnostic_event_id = diagEnv and diagEnv.event_id or nil,
        local_event_ids = Diagnostic.eventIds(fields),
        flight_recorder_available = fields.payload.flight_recorder.available,
      })
    end)
    refresh("command")
    return
  end
  record(Commands.envelope(cmd, requestId))
  cloud(cmd, requestId)
  refresh("command")
end

for _, name in ipairs(Commands.NAMES) do
  EC[name] = function(tParams)
    local ok, err = pcall(runCommand, name, tParams or {})
    if not ok then
      setError(name .. " failed: " .. tostring(err))
    end
  end
end

-- ─── Restricted operations from the platform ───────────────────────────────

local OPS = {}

function OPS.apply_config(op)
  local applied, refusals = applyConfig(op.config, op.version, "operation")
  client.sendStatus({
    applied_config_version = tostring(gConfigVersion),
    config_error = gConfigError,
  })
  if applied then
    return "Completed", "configuration v" .. tostring(op.version) .. " applied"
  end
  return "Failed", "refused, v" .. tostring(gConfigVersion) .. " kept: " .. Config.describeRefusals(refusals)
end

function OPS.refresh_status()
  refresh("refresh_status")
  emitStatus("refresh_status", State.code(facts()), nil)
  client.sendStatus()
  return "Completed", State.code(facts())
end

function OPS.deliver_result(op)
  local bounded, cut = Operations.boundResponse(op.text)
  gLast.response = bounded
  gLast.response_id = op.response_id
  if op.pending_approvals ~= nil then
    gLast.pending_approvals = op.pending_approvals
  end
  if op.recommendation_count ~= nil then
    gLast.recommendation_count = op.recommendation_count
  end
  finishJob(op.job_id, op.request_id)
  gCounters.results_delivered = gCounters.results_delivered + 1
  if gLast.error_kind == "provider" then
    setError("") -- a delivered result means the provider answered again
  end
  saveLast()
  setVar("AI_LAST_RESPONSE", bounded)
  setVar("AI_LAST_RESPONSE_ID", op.response_id)
  refresh("result")
  fire("ai_response_ready")
  return "Completed", "response " .. op.response_id .. (cut and " (shortened for the variable)" or "")
end

--- Severity of the ai_core.event envelope: the failures are warnings
--- (critical for the buffer), everything else is information.
local RAISED_WARNING = { action_failed = true, ai_provider_error = true }

function OPS.raise_event(op, request)
  gLast.event_detail = op.detail
  -- Always written, so the value never belongs to an earlier event.
  gLast.event_correlation_id = op.correlation_id or ""
  if op.pending_approvals ~= nil then
    gLast.pending_approvals = op.pending_approvals
  end
  if op.recommendation_count ~= nil then
    gLast.recommendation_count = op.recommendation_count
  end
  gCounters.events_raised = gCounters.events_raised + 1
  saveLast()
  setVar("AI_LAST_EVENT_DETAIL", op.detail)
  setVar("AI_LAST_CORRELATION_ID", gLast.event_correlation_id)
  -- What the platform raised, on the timeline, tied to what it is about.
  record({
    event_type = "ai_core.event",
    evidence_source = "system",
    quality = op.detail ~= "" and "unreviewed_text" or "confirmed",
    severity = RAISED_WARNING[op.event] and "warning" or "info",
    label = op.event,
    correlation_id = op.correlation_id,
    payload = {
      event = op.event,
      detail = op.detail ~= "" and op.detail or nil,
      correlation_id = op.correlation_id,
      operation_request_id = request and request.request_id or nil,
      pending_approvals = op.pending_approvals,
      recommendation_count = op.recommendation_count,
      note = "raised by SmartBuildOS (restricted operation raise_event); the platform's word, not an observation",
    },
  })
  if op.event == "ai_provider_error" then
    -- The platform's word on the AI provider, shown where programming and
    -- the dealer look for errors; cleared by the next delivered result.
    setError(
      op.detail ~= "" and ("AI provider error: " .. op.detail) or "AI provider error (no detail from SmartBuildOS)",
      "provider"
    )
  end
  refresh("raise_event")
  fire(op.event)
  return "Completed", "fired " .. op.event
end

function OPS.set_learning(op)
  if op.active then
    local block = licenceBlocks("AI_LEARNING")
    if block ~= nil then
      return "Failed", block
    end
  end
  gLearning = { active = op.active, source = "System Studio", reason = op.reason or "" }
  persist:set(LEARNING_KEY, gLearning)
  applyCollection()
  refresh("learning")
  return "Completed", op.active and "learning active" or "learning paused"
end

function OPS.run_diagnostic(op, request)
  local block = licenceBlocks("BASE")
  if block ~= nil then
    return "Failed", block
  end
  local devices = projectDevices()
  local target = { device_id = op.device_id, room_id = op.room_id }
  if op.device_id ~= nil then
    target.device_name = devices[op.device_id] and devices[op.device_id].name or nil
  else
    target.room_name = projectRooms()[op.room_id]
  end
  runDiagnostic(target, request.request_id, "run_diagnostic", function(env, fields)
    local fr = fields.payload.flight_recorder
    client.commandResult(
      request.request_id,
      env and "Completed" or "Failed",
      env
          and string.format(
            "diagnostic %s: %s",
            env.event_id,
            fr.available and (#fr.events .. " local event(s)") or ("no local history (" .. tostring(fr.reason) .. ")")
          )
        or "the diagnostic envelope was refused"
    )
  end)
  return "Executing", "asking the Flight Recorder"
end

local function onOperation(request)
  gCounters.operations = gCounters.operations + 1
  local op, why = Operations.parse(request.command, request.args)
  if op == nil then
    gCounters.operations_refused = gCounters.operations_refused + 1
    client.commandResult(request.request_id, "Failed", why)
    log:warn("Operation %s refused: %s", tostring(request.command), tostring(why))
    return
  end
  gLast.sync_at = now()
  client.commandResult(request.request_id, "Executing", request.command)
  local ok, stateName, detail = pcall(OPS[op.kind], op, request)
  if not ok then
    client.commandResult(request.request_id, "Failed", tostring(stateName))
    return
  end
  if stateName ~= "Executing" then
    client.commandResult(request.request_id, stateName, detail)
  end
end

-- ─── Director callbacks: own collection ────────────────────────────────────

function OnSystemEvent(data)
  if not gInitialized or not gPlan.system_events then
    return
  end
  local name = Collector.systemEventName(data)
  local spec = name and Collector.SYSTEM_BY_NAME[name] or nil
  if spec == nil then
    return
  end
  if not gCollector:admit({ category = "system" }) then
    return
  end
  gCounters.system_events = gCounters.system_events + 1
  record({
    event_type = "ai_core.observation.system",
    evidence_source = "system",
    quality = "unreviewed_text",
    severity = spec.severity,
    label = name,
    payload = {
      event = name,
      system_event_id = spec.id,
      data = tostring(data):sub(1, 200),
      note = "Director system event; its payload format is not documented and no cause is known",
    },
  })
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  if not gInitialized then
    return
  end
  local key = tostring(tointeger(idDevice)) .. ":" .. tostring(tointeger(idVariable))
  local l = gVarListeners[key]
  if l == nil or not gPlan.variables then
    return
  end
  local initial = not l.seen
  l.seen = true
  local d = projectDevices()[l.device_id] or {}
  if not gCollector:admit({ room_id = d.room_id, category = "unknown" }) then
    return
  end
  gCounters.variable_events = gCounters.variable_events + 1
  local value = tostring(strValue or ""):sub(1, V.LIMITS.value)
  record({
    event_type = "ai_core.observation.variable",
    evidence_source = initial and "initial" or "observed",
    quality = tonumber(value) ~= nil and "confirmed" or "unreviewed_text",
    severity = "info",
    device_id = l.device_id,
    room_id = d.room_id,
    label = tostring(d.name or l.device_id) .. ": " .. l.name,
    payload = {
      device_name = d.name,
      variable = l.name,
      value = value,
      initial = initial,
      note = initial and "the value when listening started; not a change"
        or "value as Director reported it; the previous value and the cause are not known",
    },
  })
end

-- ─── Lifecycle ─────────────────────────────────────────────────────────────

local VARIABLES = {
  { "AI_STATUS", "starting", "STRING" },
  { "AI_LAST_RESPONSE", "", "STRING" },
  { "AI_LAST_RESPONSE_ID", "", "STRING" },
  { "AI_LAST_REQUEST_ID", "", "STRING" },
  { "AI_LAST_EVENT_DETAIL", "", "STRING" },
  { "AI_PENDING_APPROVALS", 0, "NUMBER" },
  { "AI_RECOMMENDATION_COUNT", 0, "NUMBER" },
  { "AGENT_CONNECTED", "false", "BOOL" },
  { "LEARNING_ACTIVE", "false", "BOOL" },
  { "AI_LAST_ERROR", "", "STRING" },
  { "AI_LAST_CORRELATION_ID", "", "STRING" },
}

local function registerComposerSurface()
  for _, v in ipairs(VARIABLES) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs(V.EVENTS) do
    pcall(function()
      C4:AddEvent(e.id, e.name, e.name)
    end)
  end
end

local function restore()
  local stored = persist:get(CONFIG_KEY, false)
  if type(stored) == "table" and type(stored.cfg) == "table" then
    local cfg = Config.validate(stored.cfg)
    if cfg ~= nil then
      gConfig = cfg
      gConfigVersion = tonumber(stored.version) or 0
      gConfigError = tostring(stored.error or "")
    end
  end
  local learning = persist:get(LEARNING_KEY, false)
  if type(learning) == "table" and type(learning.active) == "boolean" then
    gLearning =
      { active = learning.active, source = tostring(learning.source or "?"), reason = tostring(learning.reason or "") }
  else
    gLearning = { active = gConfig.learning.active, source = "default", reason = "" }
  end
  local last = persist:get(LAST_KEY, false)
  if type(last) == "table" then
    -- Only a value of the type the field holds is restored: a corrupted
    -- document must not put a table into a property or a variable (that
    -- would throw here, in LateInit, before the timers are armed).
    local types = {
      response_id = "string",
      response = "string",
      request_id = "string",
      event_detail = "string",
      event_correlation_id = "string",
      error = "string",
      error_kind = "string",
      refusal = "string",
      sync_at = "number",
      cloud_result = "string",
      test = "string",
      pending_approvals = "number",
      recommendation_count = "number",
    }
    for k, want in pairs(types) do
      if type(last[k]) == want then
        gLast[k] = last[k]
      end
    end
    if gLast.error == "" then
      gLast.error_kind = nil
    end
  end
  setVar("AI_LAST_RESPONSE", gLast.response)
  setVar("AI_LAST_RESPONSE_ID", gLast.response_id)
  setVar("AI_LAST_REQUEST_ID", gLast.request_id)
  setVar("AI_LAST_EVENT_DETAIL", gLast.event_detail)
  setVar("AI_LAST_CORRELATION_ID", gLast.event_correlation_id)
  setVar("AI_LAST_ERROR", gLast.error)
  UpdateProperty("Last Error", gLast.error ~= "" and gLast.error or "none")
end

local function tick()
  expireJobs()
  if gAgentLost then
    -- Probe every tick (30 s) while the Agent is not answering, not every
    -- 5 minutes: recovery should not wait for the liveness timer.
    discoverFlightRecorder("recovery")
  end
  if license.enforces() ~= gLicenceHalted then
    applyCollection()
  end
  if client.isRegistered() and not gAgentLost and gBuffer:depth() > 0 then
    flushBuffer()
  end
  refresh("tick")
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName("AICore")
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
end

function OnDriverLateInit(reason)
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  registerComposerSurface()
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end
  restore()
  gBuffer = Buffer.new({
    load = function()
      return persist:get(BUFFER_KEY, false)
    end,
    save = function(doc)
      persist:set(BUFFER_KEY, doc)
    end,
  })
  gCollector = Collector.new({ now = now })
  gBucket = Commands.newBucket(V.LIMITS.commands_per_minute, now)

  license.setup({ sku = V.SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    applyCollection()
    refresh("licence")
  end

  client.setup({
    module_id = V.MODULE_ID,
    driver_version = tostring(C4:GetDriverConfigInfo("version")),
    capabilities = { "ai_core", "local_diagnostics" },
    entitlements = { V.SKU },
    commands = V.OPERATIONS,
    event_types = { V.EVENT_PREFIX },
    singleton = true,
    require_protocol = 2,
    manifest = { driver = V.MANIFEST_DRIVER, capabilities = {} },
    status = function()
      return State.code(facts()), gLast.error, statusCounters()
    end,
    configVersion = function()
      return tostring(gConfigVersion)
    end,
    onRegistered = function(reply)
      if tostring(reply.ok) == "true" then
        gAgentLost = false
        pcall(license.register)
        flushBuffer()
        discoverFlightRecorder("registered")
      end
      applyCollection()
      refresh("registered")
    end,
    onAgentState = function(_, why)
      if why == "hello" then
        gAgentLost = false -- it restarted and is talking again
        gFr.subscribed = false -- subscriptions died with it; re-sent on registration
        gFr.subscription_requested = false
      end
      refresh(why)
    end,
    onDirectoryChanged = function()
      discoverSoon()
    end,
    onCommand = onOperation,
    onConfig = function(settings, version)
      local applied, refusals = applyConfig(settings, version, "System Studio")
      return applied, #refusals
    end,
  })
  -- At Log Level 5 the vendored ExecuteCommand prints every param of every
  -- command; the Agent's frames carry this module's token. Never printed.
  EC.suppressDebug = EC.suppressDebug or {}
  for name in pairs(EC) do
    if type(name) == "string" and name:find("^SBOS_MODULE_") then
      EC.suppressDebug[name] = true
    end
  end
  EC.SBOS_MODULE_AGENT_EVENT = function(tParams)
    tParams = tParams or {}
    if not gPlan.agent_events then
      return -- the Flight Recorder records these when it is installed
    end
    if not gCollector:admit({ category = "system" }) then
      return
    end
    local ok, detail = pcall(function()
      return JSON:decode(tostring(tParams.detail or "{}"))
    end)
    gCounters.agent_events = gCounters.agent_events + 1
    record({
      event_type = "ai_core.observation.agent",
      evidence_source = "system",
      severity = (tParams.name == "device_offline" or tParams.name == "unexpected_restart") and "warning" or "info",
      label = tostring(tParams.name or ""):sub(1, 64),
      payload = {
        event = tostring(tParams.name or ""):sub(1, 64),
        detail = ok and type(detail) == "table" and detail or {},
      },
    })
  end
  EC.suppressDebug.SBOS_MODULE_AGENT_EVENT = true

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)
  applyCollection()
  client.register()
  SetTimer(TICK_TIMER, TICK_SECONDS * ONE_SECOND, tick, true)
  SetTimer(LIVENESS_TIMER, LIVENESS_SECONDS * ONE_SECOND, function()
    discoverFlightRecorder("liveness")
  end, true)
  refresh("started")
  log:info("AI Core started (%s)", tostring(reason))
end

function OnDriverDestroyed()
  pcall(license.stop)
  registerSystemEvents(false)
  for key, l in pairs(gVarListeners) do
    pcall(function()
      C4:UnregisterVariableListener(l.device_id, l.variable_id)
    end)
    gVarListeners[key] = nil
  end
  client.flush()
  client.stop()
  CancelTimer(TICK_TIMER)
  CancelTimer(LIVENESS_TIMER)
  CancelTimer(DISCOVER_TIMER)
  saveLast()
end

-- ─── Properties ────────────────────────────────────────────────────────────

function OPC.Log_Level(value)
  log:setLogLevel(value)
  DEBUGPRINT = tostring(value):match("^5") ~= nil
end

function OPC.Log_Mode(value)
  log:setLogMode(value)
end

function OPC.Driver_Status()
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

-- ─── Actions ───────────────────────────────────────────────────────────────

function EC.TEST_AGENT_LINK()
  if client.agentId() == nil then
    gLast.test = "Agent link: no SmartBuildOS Agent in this project"
    refresh("test")
    return
  end
  if (client.protocol() or 0) < 2 then
    gLast.test = client.isRegistered()
        and "Agent link: registered at protocol 1; this driver needs an Agent update (protocol 2)"
      or "Agent link: not registered yet"
    refresh("test")
    return
  end
  gLast.test = "Agent link: asking the Agent…"
  refresh("test")
  client.discover(nil, function(directory, code)
    if code ~= "ok" then
      gLast.test = "Agent link: FAILED (" .. tostring(code) .. ")"
    else
      local a = type(directory.agent) == "table" and directory.agent or {}
      local modules = type(directory.modules) == "table" and directory.modules or {}
      gLast.test = string.format(
        "Agent link: OK at %s — Agent %s, protocol %s..%s, %s, %s; %d module(s)",
        stamp(now()),
        -- The Agent's own words, bounded: a property is not a log.
        tostring(a.version or "?"):sub(1, 40),
        tostring(a.protocol_min or "?"):sub(1, 8),
        tostring(a.protocol_max or "?"):sub(1, 8),
        a.paired and "paired" or "not paired",
        a.connected and "cloud connected" or "cloud NOT connected",
        #modules
      )
    end
    saveLast()
    refresh("test")
  end)
end

function EC.TEST_AI_CONNECTION()
  local block = licenceBlocks("BASE")
  if block ~= nil then
    gLast.test = "AI connection: " .. block
    refresh("test")
    return
  end
  local requestId = newRequestId()
  gLast.test = "AI connection: asking SmartBuildOS…"
  refresh("test")
  client.cloudRequest("test_provider", { request_id = requestId }, { idempotency_key = requestId }, function(answer)
    local r = Commands.interpret(answer)
    if r.outcome == "accepted" then
      gLast.test = "AI connection: test accepted (job " .. r.job_id .. "); result follows as AI Response Ready"
      gLast.sync_at = now()
      addJob(r.job_id, "TEST_AI_CONNECTION", requestId)
    elseif r.outcome == "completed" then
      -- No job id: nothing will follow, so do not promise a result.
      gLast.test = "AI connection: answered by SmartBuildOS (no result follows)"
      gLast.sync_at = now()
    else
      gLast.test = "AI connection: " .. r.outcome .. " (" .. tostring(r.code) .. ")"
    end
    saveLast()
    refresh("test")
  end)
end

function EC.SYNC_NOW()
  if not client.isRegistered() or gAgentLost then
    client.register()
  end
  flushBuffer()
  client.flush()
  discoverFlightRecorder("sync_now")
  client.sendStatus()
  if (client.protocol() or 0) >= 2 then
    local requestId = newRequestId()
    client.cloudRequest("status", {
      request_id = requestId,
      applied_config_version = gConfigVersion,
      learning_active = learningActive(),
      flight_recorder = gFr.state,
    }, { idempotency_key = requestId }, function(answer)
      if answer.status == "ok" then
        gLast.sync_at = now()
        gCloudUnreachable = false
      else
        local r = Commands.interpret(answer)
        gCloudUnreachable = r.code == "cloud_unreachable"
        setError("Sync Now: " .. r.message)
      end
      saveLast()
      refresh("sync")
    end)
  end
  refresh("sync")
end

function EC.PRINT_DIAGNOSTICS()
  local f = facts()
  local code = State.code(f)
  log:print("== SmartBuildOS AI Core ==")
  log:print("  status: %s (%s)", code, State.aiStatusText(code, f))
  log:print("  agent: %s", client.describe())
  log:print("  agent lost: %s; cloud unreachable: %s", tostring(gAgentLost), tostring(gCloudUnreachable))
  log:print("  licence: %s", license.describe())
  log:print("  configuration: v%s %s", tostring(gConfigVersion), gConfigError ~= "" and gConfigError or "(valid)")
  log:print("  learning: %s", learningText())
  log:print("  flight recorder: %s", frText())
  log:print(
    "  collection plan: subscribe=%s system_events=%s agent_events=%s variables=%s",
    tostring(gPlan.subscribe),
    tostring(gPlan.system_events),
    tostring(gPlan.agent_events),
    tostring(gPlan.variables)
  )
  local c = statusCounters()
  local keys = {}
  for k in pairs(c) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    log:print("  %s = %s", k, tostring(c[k]))
  end
  for _, id in ipairs(gJobOrder) do
    local j = gJobs[id]
    if j then
      log:print("  pending job %s: %s (%s) since %s", id, j.command, j.request_id, stamp(j.at))
    end
  end
  for k, v in pairs(client.busCounters()) do
    log:print("  bus %s = %s", tostring(k), tostring(v))
  end
end

-- ─── Conditionals ──────────────────────────────────────────────────────────

function TC.AI_READY()
  return State.code(facts()) == "ready"
end

function TC.AGENT_CONNECTED()
  return State.agentConnected(facts())
end

function TC.LEARNING_ACTIVE()
  return learningActive() and not gLicenceHalted
end

function TC.APPROVALS_PENDING()
  return (tonumber(gLast.pending_approvals) or 0) > 0
end

function TC.RECOMMENDATIONS_AVAILABLE()
  return (tonumber(gLast.recommendation_count) or 0) > 0
end
