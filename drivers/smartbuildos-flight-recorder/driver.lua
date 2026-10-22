--[[==========================================================================
  SmartBuildOS Flight Recorder
  The first production module built on the expanded SmartBuildOS Agent.

  What happened? Which device or automation was involved? What happened
  immediately before and afterward? Was an action merely REQUESTED, or was
  its result OBSERVED? What evidence supports an explanation?

  The Agent supplies the shared services (registration, the durable event
  pipeline, versioned configuration delivery, restricted commands, snapshot
  upload). This driver supplies the recording policy: which sources, how
  they are debounced/coalesced, the programming trace commands, the
  diagnostic snapshot, and the Composer surface. Local recording continues
  during an internet or SmartBuildOS outage; uploads wait in the Agent.

  Pure rules: src/flightrecorder/{config,recorder,traces,snapshot}.lua and
  src/sbos/{envelope,moduleclient}.lua — all tested without a controller.
  Hardware validation: see docs/flight-recorder/VERIFICATION.md.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-flight-recorder.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-flight-recorder.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local client = require("sbos.moduleclient")
local Envelope = require("sbos.envelope")
local Config = require("flightrecorder.config")
local Recorder = require("flightrecorder.recorder")
local Traces = require("flightrecorder.traces")
local Snapshot = require("flightrecorder.snapshot")

gInitialized = false

local MODULE_ID = "flight_recorder"
local SKU = "SBOS_FLIGHT_RECORDER"
local CONFIG_KEY = "fr_config_v1"
local CONFIG_META_KEY = "fr_config_meta_v1"
local PAUSED_KEY = "fr_paused"
local TRACE_TICK_TIMER = "FrTraceTick"
local STATUS_TIMER = "FrStatusPaint"
local SNAPSHOT_TIMER = "FrSnapshotRun"
local RECENT_RING = 100
local MAX_JOBS = 10
local SNAPSHOT_ACK_SECONDS = 600

local EVENT_DEGRADED, EVENT_RESTORED, EVENT_BUFFER, EVENT_SNAP_OK, EVENT_SNAP_FAIL = 1, 2, 3, 4, 5
local EVENT_TRACE_OK, EVENT_TRACE_FAIL, EVENT_AGENT_ON, EVENT_AGENT_OFF = 6, 7, 8, 9

--- Last VALID configuration (never replaced by a refused revision).
local gConfig = Config.default()
--- desired / applied / validation / sync bookkeeping.
local gMeta = {
  applied_version = 0,
  desired_version = nil,
  source = "default",
  last_sync_at = nil,
  last_error = nil,
  refusals = {},
}
local gRecorder = nil
local gTraces = nil
local gRecent = {}
local gJobs = {}
local gJobSeq = 0
local gPipeline = nil -- the Agent's queue health, from acks
local gLastStatus = nil
local gBufferWarned = false
local gLastUploadAt = nil
local gLastError = "none"

local function nowIso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function fire(id)
  pcall(function()
    C4:FireEventByID(id)
  end)
end

local function setVar(name, value)
  pcall(function()
    C4:SetVariable(name, value)
  end)
end

-- ─── Emission ───────────────────────────────────────────────────────────────

--- Every event this driver records goes through here: envelope, local ring
--- (for snapshots and Print Status), then the module client's stage.
local function emit(fields)
  local env, why = client.event(fields)
  if env == nil then
    gLastError = "event refused: " .. tostring(why)
    log:warn("Event refused (%s): %s", tostring(why), tostring(fields.event_type))
    return nil
  end
  gRecent[#gRecent + 1] = env
  while #gRecent > RECENT_RING do
    table.remove(gRecent, 1)
  end
  client.sendEvents({ env })
  return env
end

-- ─── Status ─────────────────────────────────────────────────────────────────

local function recordingStatus()
  if gRecorder == nil then
    return "starting"
  end
  if gRecorder.paused then
    return "paused"
  end
  if not gConfig.enabled then
    return "disabled"
  end
  if license.enforces() then
    return "unlicensed"
  end
  local agent = client.displayStatus()
  if agent == "ready" then
    return gRecorder:listenerCount() > 0 and "recording" or "idle"
  end
  -- Recording continues locally; only the upload path is impaired.
  return (gRecorder:listenerCount() > 0 and "recording_local" or "idle") .. " (" .. agent .. ")"
end

local function counters()
  local c = {}
  if gRecorder then
    for k, v in pairs(gRecorder.counters) do
      c["recorder_" .. k] = v
    end
  end
  if gTraces then
    for k, v in pairs(gTraces.counters) do
      c["trace_" .. k] = v
    end
    c.active_traces = gTraces:activeCount()
  end
  c.jobs = 0
  for _ in pairs(gJobs) do
    c.jobs = c.jobs + 1
  end
  c.applied_version = gMeta.applied_version
  c.desired_version = gMeta.desired_version
  c.config_source = gMeta.source
  return c
end

local function paint()
  local status = recordingStatus()
  local agent = client.displayStatus()
  local clientState = client._state()
  local buffered = #clientState.staged
  for _, id in ipairs(clientState.pendingOrder) do
    local f = clientState.pending[id]
    if f then
      buffered = buffered + #f.events
    end
  end
  local dropped = (gRecorder and gRecorder.counters.dropped_budget or 0) + client.counters().events_dropped_local
  UpdateProperty("Recording Status", status)
  UpdateProperty("Agent Connection", agent)
  UpdateProperty(
    "Agent Link",
    client.agentId()
        and string.format(
          "Agent device %s — %s",
          tostring(client.agentId()),
          client.isRegistered() and "registered" or "not registered"
        )
      or "No SmartBuildOS Agent found in this project"
  )
  UpdateProperty(
    "Configuration",
    string.format(
      "v%s applied (%s)%s%s",
      tostring(gMeta.applied_version),
      tostring(gMeta.source),
      gMeta.desired_version
          and gMeta.desired_version ~= gMeta.applied_version
          and (" — desired v" .. tostring(gMeta.desired_version) .. " refused")
        or "",
      gMeta.last_error and (": " .. gMeta.last_error) or ""
    )
  )
  local plan = gRecorder and gRecorder.plan or nil
  UpdateProperty(
    "Selected Sources",
    string.format(
      "%d selected, %d listening%s%s",
      #gConfig.sources,
      gRecorder and gRecorder:listenerCount() or 0,
      plan and #plan.stale > 0 and (", " .. #plan.stale .. " stale") or "",
      plan and #plan.unsupported > 0 and (", " .. #plan.unsupported .. " unsupported") or ""
    )
  )
  UpdateProperty("Active Traces", tostring(gTraces and gTraces:activeCount() or 0))
  UpdateProperty("Buffered Events", tostring(buffered))
  UpdateProperty("Dropped Events", tostring(dropped))
  UpdateProperty("Last Upload", gLastUploadAt and os.date("%Y-%m-%d %H:%M:%S", gLastUploadAt) or "never")
  UpdateProperty("Last Recording Error", gLastError)
  setVar("RECORDING_STATUS", status)
  setVar("AGENT_CONNECTION", agent)
  setVar("SELECTED_SOURCES", #gConfig.sources)
  setVar("ACTIVE_TRACES", gTraces and gTraces:activeCount() or 0)
  setVar("BUFFERED_EVENTS", buffered)
  setVar("DROPPED_EVENTS", dropped)
  setVar("LAST_UPLOAD", gLastUploadAt and os.date("!%Y-%m-%dT%H:%M:%SZ", gLastUploadAt) or "")
  setVar("LAST_RECORDING_ERROR", gLastError)
  setVar("CONFIG_VERSION", tostring(gMeta.applied_version))

  -- Degraded / restored on TRANSITION only. The recorder's own status is
  -- never a recordable source, so painting cannot feed back into recording.
  local healthy = status == "recording" or status == "idle" or status == "disabled"
  if gLastStatus ~= nil and gLastStatus ~= healthy then
    fire(healthy and EVENT_RESTORED or EVENT_DEGRADED)
  end
  gLastStatus = healthy

  local threshold = tointeger(Properties["Buffer Warning Threshold"]) or 200
  if buffered >= threshold and not gBufferWarned then
    gBufferWarned = true
    fire(EVENT_BUFFER)
  elseif buffered < threshold / 2 then
    gBufferWarned = false
  end
end

-- ─── Configuration ──────────────────────────────────────────────────────────

local function persistConfig()
  persist:set(CONFIG_KEY, gConfig)
  persist:set(CONFIG_META_KEY, gMeta)
end

--- Validates and applies a revision. Refusals keep the last valid document
--- and are reported (property, status frame, config ack, event).
--- @return boolean applied, table refusals, table|nil summary
local function applyRevision(raw, version, source)
  local cfg, refusals = Config.validate(raw)
  gMeta.desired_version = tonumber(version) or gMeta.desired_version
  gMeta.last_sync_at = os.time()
  if cfg == nil then
    local first = refusals[1]
    gMeta.last_error = first and (first.path .. ": " .. first.reason) or "invalid configuration"
    gMeta.refusals = refusals
    gLastError = "configuration v" .. tostring(version) .. " refused: " .. gMeta.last_error
    log:error("%s", gLastError)
    emit({
      event_type = "recorder.config_refused",
      evidence_source = "derived",
      severity = "error",
      label = "Configuration v" .. tostring(version) .. " refused",
      payload = {
        version = tonumber(version),
        source = source,
        refusals = refusals,
        kept_version = gMeta.applied_version,
      },
    })
    persistConfig()
    paint()
    return false, refusals
  end
  cfg.version = tonumber(version) or cfg.version
  gConfig = cfg
  gMeta.applied_version = cfg.version
  gMeta.source = source
  gMeta.last_error = nil
  gMeta.refusals = {}
  local summary = nil
  if gRecorder ~= nil then
    if not gConfig.enabled then
      gRecorder:stop()
      summary = Config.summary(gConfig, nil)
    else
      summary = gRecorder:apply(gConfig)
    end
  end
  persistConfig()
  gLastError = "none"
  paint()
  return true, refusals, summary
end

-- ─── Snapshots ──────────────────────────────────────────────────────────────

local function runSnapshotJobs()
  local running = nil
  local ids = {}
  for id in pairs(gJobs) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local job = gJobs[id]
    if job.status == "running" then
      running = job
    end
  end
  if running ~= nil then
    return
  end
  for _, id in ipairs(ids) do
    local job = gJobs[id]
    if job.status == "queued" then
      Snapshot.transition(job, "running", os.time())
      local ok, err = pcall(function()
        local health = client.counters()
        local doc = Snapshot.build({
          job_id = job.job_id,
          request_id = job.request_id,
          requested_by = job.requested_by,
          now_iso = nowIso(),
          agent = {
            device_id = client.agentId(),
            registered = client.isRegistered(),
            protocol = client._state().protocol,
            paired = client.agent().paired,
            connected = client.agent().connected,
            agent_version = client.agent().agent_version,
          },
          module = {
            module_id = MODULE_ID,
            driver_version = tostring(C4:GetDriverConfigInfo("version")),
            status = recordingStatus(),
            license = license.describe(),
            counters = counters(),
            client = health,
          },
          config = gConfig,
          plan_summary = gRecorder and Config.summary(gConfig, gRecorder.plan) or nil,
          queue = gPipeline,
          observations = gRecorder and gRecorder:observations() or {},
          recent = gRecent,
          warnings = (function()
            local w = {}
            if not client.isRegistered() then
              w[#w + 1] = "not registered with the Agent: queue health and upload state are unknown"
            end
            if gRecorder and gRecorder.plan then
              if #gRecorder.plan.stale > 0 then
                w[#w + 1] = #gRecorder.plan.stale .. " configured source(s) point at devices no longer in the project"
              end
              if #gRecorder.plan.unsupported > 0 then
                w[#w + 1] = #gRecorder.plan.unsupported .. " configured source(s) are not exposed by their device"
              end
            end
            if gRecorder and gRecorder.counters.dropped_budget > 0 then
              w[#w + 1] = "observations were dropped by the per-minute budget; recent history is incomplete"
            end
            return w
          end)(),
        })
        job.document = doc
      end)
      if not ok then
        Snapshot.transition(job, "failed", os.time(), err)
        UpdateProperty("Last Snapshot", "failed: " .. tostring(err))
        fire(EVENT_SNAP_FAIL)
        if job.request_id ~= "" then
          client.commandResult(job.request_id, "Failed", tostring(err))
        end
      else
        job.sent_at = os.time()
        if not client.sendSnapshot(job) then
          Snapshot.transition(job, "failed", os.time(), "no Agent to upload through")
          UpdateProperty("Last Snapshot", "failed: no Agent")
          fire(EVENT_SNAP_FAIL)
        else
          UpdateProperty("Last Snapshot", job.job_id .. " uploading")
          if job.request_id ~= "" then
            client.commandResult(job.request_id, "Executing", "snapshot built; uploading through the Agent")
          end
        end
        job.document = nil
      end
      return
    end
  end
end

local function requestSnapshot(requestId, requestedBy, note)
  -- Bound the job table; expire what never got an answer.
  local count = 0
  for id, job in pairs(gJobs) do
    if job.status == "running" and os.time() - job.updated_at > SNAPSHOT_ACK_SECONDS then
      Snapshot.transition(job, "expired", os.time(), "no acknowledgment from the Agent")
    end
    if
      (job.status == "completed" or job.status == "failed" or job.status == "expired")
      and os.time() - job.updated_at > 3600
    then
      gJobs[id] = nil
    else
      count = count + 1
    end
  end
  if count >= MAX_JOBS then
    return nil, "too many snapshot jobs pending"
  end
  gJobSeq = gJobSeq + 1
  local jobId = string.format("snap-%s-%d-%d", tostring(C4:GetDeviceID()), os.time(), gJobSeq)
  local job = Snapshot.newJob(jobId, requestId or "", requestedBy or "composer", os.time())
  job.note = tostring(note or ""):sub(1, 200)
  gJobs[jobId] = job
  emit({
    event_type = "snapshot.requested",
    evidence_source = "derived",
    label = "Snapshot requested",
    correlation_id = jobId,
    payload = { job_id = jobId, requested_by = job.requested_by, note = job.note },
  })
  SetTimer(SNAPSHOT_TIMER, 250, runSnapshotJobs)
  return jobId
end

-- ─── Restricted commands from System Studio (through the Agent) ────────────

local COMMANDS = {
  apply_config = function(request)
    local raw = request.args.config
    local version = request.args.version
    if type(raw) ~= "table" then
      return "Failed", "apply_config needs args.config"
    end
    local applied, refusals, summary = applyRevision(raw, version, "studio")
    if applied then
      return "Completed",
        string.format(
          "v%s applied: %d listener(s), %d stale, %d unsupported",
          tostring(version),
          summary and summary.listeners or 0,
          summary and summary.stale or 0,
          summary and summary.unsupported or 0
        )
    end
    local first = refusals[1]
    return "Failed", "refused: " .. (first and (first.path .. " " .. first.reason) or "invalid")
  end,
  pause = function(request)
    if gRecorder:pause("studio: " .. tostring(request.args.reason or "")) then
      gTraces:interruptAll("recording paused")
      persist:set(PAUSED_KEY, true)
      paint()
      return "Completed", "recording paused"
    end
    return "Completed", "already paused"
  end,
  resume = function()
    persist:set(PAUSED_KEY, false)
    if gRecorder:resume("studio") then
      paint()
      return "Completed", "recording resumed; sources re-read"
    end
    return "Completed", "already recording"
  end,
  capture_snapshot = function(request)
    local jobId, why = requestSnapshot(request.request_id, "studio", request.args.note)
    if jobId == nil then
      return "Failed", why
    end
    -- Completion is reported when the Agent acks the upload (Unverified if
    -- it never does); "Executing" is what the caller sees now.
    return "Executing", "snapshot job " .. jobId
  end,
  refresh_status = function()
    paint()
    client.sendStatus()
    return "Completed", recordingStatus()
  end,
}

local function onCommand(request)
  local runner = COMMANDS[request.command]
  if runner == nil then
    client.commandResult(request.request_id, "Failed", "unknown Flight Recorder command: " .. request.command)
    return
  end
  client.commandResult(request.request_id, "Executing", request.command)
  local ok, stateName, detail = pcall(runner, request)
  if not ok then
    client.commandResult(request.request_id, "Failed", tostring(stateName))
    return
  end
  if stateName ~= "Executing" then
    client.commandResult(request.request_id, stateName, detail)
  end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerComposerSurface()
  for _, v in ipairs({
    { "RECORDING_STATUS", "starting", "STRING" },
    { "AGENT_CONNECTION", "waiting_for_agent", "STRING" },
    { "SELECTED_SOURCES", 0, "NUMBER" },
    { "ACTIVE_TRACES", 0, "NUMBER" },
    { "BUFFERED_EVENTS", 0, "NUMBER" },
    { "DROPPED_EVENTS", 0, "NUMBER" },
    { "LAST_UPLOAD", "", "STRING" },
    { "LAST_RECORDING_ERROR", "", "STRING" },
    { "CONFIG_VERSION", "0", "STRING" },
  }) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { 1, "Recording Degraded", "Recording lost the Agent, the licence, the pairing or its budget" },
    { 2, "Recording Restored", "Recording is healthy again" },
    { 3, "Buffer Threshold Reached", "Events waiting for the Agent reached the threshold" },
    { 4, "Snapshot Completed", "A diagnostic snapshot was accepted by SmartBuildOS" },
    { 5, "Snapshot Failed", "A diagnostic snapshot failed" },
    { 6, "Trace Completed", "A programming trace was completed" },
    { 7, "Trace Failed", "A programming trace was failed, abandoned or interrupted" },
    { 8, "Agent Connected", "Registered with the SmartBuildOS Agent" },
    { 9, "Agent Disconnected", "Lost the registration with the SmartBuildOS Agent" },
  }) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

local function roomOf(deviceId)
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if ok and type(devices) == "table" then
    local d = devices[deviceId] or devices[tostring(deviceId)]
    if type(d) == "table" then
      return { id = tonumber(d.roomId), name = d.roomName }
    end
  end
  return nil
end

local function deviceLabel(deviceId)
  local ok, name = pcall(function()
    return C4:GetDeviceDisplayName(deviceId)
  end)
  if ok and type(name) == "string" and name ~= "" then
    return name
  end
  return nil
end

local function buildRecorder()
  return Recorder.new({
    now = os.time,
    schedule = function(key, ms, fn)
      SetTimer(key, ms, fn)
    end,
    cancel = function(key)
      CancelTimer(key)
    end,
    register = function(deviceId, varId)
      local ok = pcall(function()
        C4:RegisterVariableListener(deviceId, varId)
      end)
      return ok
    end,
    unregister = function(deviceId, varId)
      pcall(function()
        C4:UnregisterVariableListener(deviceId, varId)
      end)
    end,
    readVariables = function(deviceId)
      local ok, vars = pcall(function()
        return C4:GetDeviceVariables(deviceId)
      end)
      if ok and type(vars) == "table" and next(vars) ~= nil then
        return vars
      end
      return nil
    end,
    emit = emit,
    selfDeviceId = C4:GetDeviceID(),
    deviceLabel = deviceLabel,
    roomOf = roomOf,
  })
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName("FlightRecorder")
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

  -- Last valid configuration, or the default.
  local stored = persist:get(CONFIG_KEY, false)
  local meta = persist:get(CONFIG_META_KEY, false)
  if type(stored) == "table" then
    local cfg = Config.validate(stored)
    if cfg ~= nil then
      gConfig = cfg
    else
      gLastError = "persisted configuration unreadable; defaults in force"
    end
  end
  if type(meta) == "table" then
    gMeta = meta
    gMeta.refusals = gMeta.refusals or {}
  end

  gRecorder = buildRecorder()
  gTraces = Traces.new({
    now = os.time,
    emit = function(fields)
      local env = emit(fields)
      if env ~= nil and fields.event_type == "trace.end" then
        fire(fields.payload.status == "completed" and EVENT_TRACE_OK or EVENT_TRACE_FAIL)
      end
    end,
    newId = function(channel)
      return string.format("%s-%s-%d-%d", tostring(C4:GetDeviceID()), channel, os.time(), client.nextSequence())
    end,
  })

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    paint()
  end

  client.setup({
    module_id = MODULE_ID,
    driver_version = tostring(C4:GetDriverConfigInfo("version")),
    capabilities = { "recording", "traces", "snapshots", "sbos_events" },
    entitlements = { SKU },
    commands = { "apply_config", "pause", "resume", "capture_snapshot", "refresh_status" },
    event_types = { "observation.", "trace.", "recorder.", "snapshot." },
    singleton = true,
    status = function()
      return recordingStatus(), gLastError ~= "none" and gLastError or "", counters()
    end,
    configVersion = function()
      return tostring(gMeta.applied_version)
    end,
    onRegistered = function(reply)
      if tostring(reply.ok) == "true" then
        fire(EVENT_AGENT_ON)
        log:info("Flight Recorder registered with the Agent")
        -- The licence registration shares the Agent: an Agent added after
        -- this driver is picked up here rather than at the next reload.
        pcall(license.register)
      else
        gLastError = "Agent refused registration: " .. tostring(reply.reason)
        fire(EVENT_AGENT_OFF)
      end
      paint()
    end,
    onAgentState = function(agent, why)
      if why == "no_agent" then
        gLastError = "no SmartBuildOS Agent in this project"
      end
      paint()
    end,
    onCommand = onCommand,
    onConfig = function(settings, version)
      local applied, refusals = applyRevision(settings, version, "studio")
      return applied, #refusals
    end,
    onAck = function(batchId, accepted, params)
      gLastUploadAt = os.time()
      if type(params) == "table" and params.queue ~= nil then
        local ok, q = pcall(function()
          return JSON:decode(tostring(params.queue))
        end)
        if ok and type(q) == "table" then
          gPipeline = q
        end
      end
      paint()
    end,
    onSnapshotAck = function(params)
      local job = gJobs[tostring(params.job_id or "")]
      if job == nil then
        return
      end
      if tostring(params.ok) == "true" then
        Snapshot.transition(job, "completed", os.time())
        UpdateProperty("Last Snapshot", job.job_id .. " completed " .. os.date("%H:%M:%S"))
        fire(EVENT_SNAP_OK)
        if job.request_id ~= "" then
          client.commandResult(job.request_id, "Completed", "snapshot " .. job.job_id .. " stored")
        end
      else
        Snapshot.transition(job, "failed", os.time(), params.reason)
        UpdateProperty("Last Snapshot", job.job_id .. " failed: " .. tostring(params.reason))
        fire(EVENT_SNAP_FAIL)
        if job.request_id ~= "" then
          client.commandResult(job.request_id, "Failed", tostring(params.reason))
        end
      end
    end,
  })
  EC.SBOS_MODULE_AGENT_EVENT = function(tParams)
    tParams = tParams or {}
    local ok, detail = pcall(function()
      return JSON:decode(tostring(tParams.detail or "{}"))
    end)
    if gRecorder then
      gRecorder:onSbosEvent(tostring(tParams.name or ""), ok and detail or {})
    end
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)

  if persist:get(PAUSED_KEY, false) == true then
    gRecorder.paused = true
  elseif gConfig.enabled then
    local okA, errA = pcall(function()
      gRecorder:apply(gConfig)
    end)
    if not okA then
      gLastError = "apply failed: " .. tostring(errA)
      log:error("%s", gLastError)
    end
  end
  client.register()
  SetTimer(TRACE_TICK_TIMER, 30 * ONE_SECOND, function()
    if gTraces then
      gTraces:tick()
    end
    -- Expire snapshot jobs that never got an answer.
    for _, job in pairs(gJobs) do
      if job.status == "running" and os.time() - job.updated_at > SNAPSHOT_ACK_SECONDS then
        Snapshot.transition(job, "expired", os.time(), "no acknowledgment from the Agent")
        if job.request_id ~= "" then
          client.commandResult(job.request_id, "Unverified", "the Agent never acknowledged the snapshot upload")
        end
        UpdateProperty("Last Snapshot", job.job_id .. " expired")
      end
    end
  end, true)
  SetTimer(STATUS_TIMER, 60 * ONE_SECOND, paint, true)
  paint()
end

function OnDriverDestroyed()
  if gTraces then
    gTraces:interruptAll("driver removed or reloaded")
  end
  if gRecorder then
    gRecorder:stop()
  end
  client.flush()
  client.stop()
  CancelTimer(TRACE_TICK_TIMER)
  CancelTimer(STATUS_TIMER)
  CancelTimer(SNAPSHOT_TIMER)
end

--- Director's callback for every watched variable.
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  if gRecorder == nil then
    return
  end
  gRecorder:onChange(tointeger(idDevice), tointeger(idVariable), strValue)
end

-- ─── Properties ─────────────────────────────────────────────────────────────

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

-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.REGISTER_NOW()
  client.register()
end

function EC.PAUSE_RECORDING_ACTION()
  EC.PAUSE_RECORDING({ REASON = "Composer action" })
end

function EC.RESUME_RECORDING_ACTION()
  EC.RESUME_RECORDING({})
end

function EC.CAPTURE_SNAPSHOT_ACTION()
  EC.CAPTURE_SNAPSHOT({ NOTE = "Composer action" })
end

function EC.REFRESH_STATUS()
  paint()
  client.sendStatus()
end

local TEMPLATE_BY_LABEL = {
  ["Lighting"] = "lighting",
  ["Contacts and openings"] = "contacts",
  ["Motion and occupancy"] = "motion",
  ["Room media"] = "room_media",
  ["SmartBuildOS events"] = "sbos_events",
}

--- Composer's one configuration edit: add a template's sources (those that
--- exist in this project) as a LOCAL revision. System Studio owns the
--- document; this is reported as source "composer" and the next Studio save
--- replaces it (ownership rule in PROTOCOL.md §6).
function EC.APPLY_TEMPLATE()
  local templateId = TEMPLATE_BY_LABEL[tostring(Properties["Template"] or "-")]
  if templateId == nil then
    log:warn("Pick a Template first")
    return
  end
  local catalogue = {}
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if ok and type(devices) == "table" then
    local n = 0
    for rawId, d in pairs(devices) do
      local id = tonumber(rawId)
      n = n + 1
      if id ~= nil and id ~= C4:GetDeviceID() and n <= 400 then
        local okV, vars = pcall(function()
          return C4:GetDeviceVariables(id)
        end)
        if okV and type(vars) == "table" then
          local names = {}
          for _, v in pairs(vars) do
            if type(v) == "table" and type(v.name) == "string" then
              names[#names + 1] = v.name
            end
          end
          catalogue[#catalogue + 1] = {
            kind = "device_variable",
            device_id = id,
            device_label = type(d) == "table" and d.deviceName or nil,
            room_id = type(d) == "table" and tonumber(d.roomId) or nil,
            room_label = type(d) == "table" and d.roomName or nil,
            variables = names,
          }
        end
      end
    end
  end
  local additions = Config.applyTemplate(templateId, catalogue)
  if additions == nil or #additions == 0 then
    log:warn("Template %s adds nothing: no matching sources in this project", templateId)
    UpdateProperty("Last Recording Error", "template added no sources (none exist here)")
    return
  end
  local raw = {
    version = gMeta.applied_version + 1,
    enabled = gConfig.enabled,
    sources = {},
    budgets = gConfig.budgets,
    exclusions = gConfig.exclusions,
    privacy = gConfig.privacy,
  }
  local seen = {}
  for _, s in ipairs(gConfig.sources) do
    raw.sources[#raw.sources + 1] = s
    seen[s.id] = true
  end
  for _, s in ipairs(additions) do
    local id = Config.sourceId(s.kind, s.device_id or 0, s.variable or s.event)
    if not seen[id] and #raw.sources < gConfig.budgets.max_sources then
      raw.sources[#raw.sources + 1] = s
      seen[id] = true
    end
  end
  for _, s in ipairs(raw.sources) do
    s.id = nil
  end
  local applied = applyRevision(raw, raw.version, "composer")
  log:info("Template %s: %s", templateId, applied and "applied" or "refused")
  client.sendStatus()
end

function EC.CLEAR_LOCAL_SOURCES()
  local raw = {
    version = gMeta.applied_version + 1,
    enabled = gConfig.enabled,
    sources = {},
    budgets = gConfig.budgets,
    exclusions = gConfig.exclusions,
    privacy = gConfig.privacy,
  }
  applyRevision(raw, raw.version, "composer")
  client.sendStatus()
end

function EC.PRINT_STATUS()
  log:print("== Flight Recorder ==")
  log:print("  status: %s", recordingStatus())
  log:print("  agent: %s", client.describe())
  log:print("  licence: %s", license.describe())
  log:print(
    "  configuration: v%s (%s) desired v%s error=%s",
    tostring(gMeta.applied_version),
    tostring(gMeta.source),
    tostring(gMeta.desired_version),
    tostring(gMeta.last_error)
  )
  for k, v in pairs(counters()) do
    log:print("  %s = %s", tostring(k), tostring(v))
  end
  if gPipeline then
    log:print(
      "  agent queue: depth=%s dropped=%s last_ack=%s",
      tostring(gPipeline.depth),
      tostring(gPipeline.dropped),
      tostring(gPipeline.last_ack_at)
    )
  end
  for _, t in ipairs(gTraces and gTraces:activeList() or {}) do
    log:print("  active trace %s on %s (%d steps)", t.trace_id, t.channel, t.steps)
  end
  for _, env in ipairs(gRecent) do
    log:print("  recent %s %s %s", env.observed_at, env.event_type, tostring(env.label or ""))
  end
end

function EC.PRINT_SOURCES()
  log:print("== Flight Recorder sources (v%s) ==", tostring(gMeta.applied_version))
  for _, s in ipairs(gConfig.sources) do
    log:print("  %s %s %s", s.id, s.enabled and "on" or "off", s.label)
  end
  if gRecorder and gRecorder.plan then
    for _, item in ipairs(gRecorder.plan.stale) do
      log:print("  STALE %s: %s", item.source.id, item.reason)
    end
    for _, item in ipairs(gRecorder.plan.unsupported) do
      log:print("  UNSUPPORTED %s: %s", item.source.id, item.reason)
    end
    for _, item in ipairs(gRecorder.plan.excluded) do
      log:print("  EXCLUDED %s: %s", item.source.id, item.reason)
    end
  end
  for _, o in ipairs(gRecorder and gRecorder:observations() or {}) do
    log:print("  %s = %s (%s)", o.label, tostring(o.value), o.known and "known" or "unknown")
  end
end

-- ─── Composer programming commands ─────────────────────────────────────────

function EC.RECORD_EVENT(tParams)
  tParams = tParams or {}
  local name = tostring(tParams.NAME or ""):sub(1, 120)
  if name == "" then
    log:warn("RECORD_EVENT without a NAME")
    return
  end
  local channel = Traces.channelOf(tParams.CHANNEL)
  local active = nil
  for _, t in ipairs(gTraces:activeList()) do
    if t.channel == channel then
      active = t
    end
  end
  emit({
    event_type = "observation.programmed",
    evidence_source = "requested",
    quality = "unreviewed_text",
    label = name,
    device_id = tonumber(tParams.DEVICE),
    correlation_id = active and active.trace_id or nil,
    payload = {
      name = name,
      detail = tostring(tParams.DETAIL or ""):sub(1, 400),
      channel = tParams.CHANNEL ~= nil and channel or nil,
      note = "recorded by Composer programming; a request, not an observed result",
    },
  })
end

function EC.START_TRACE(tParams)
  tParams = tParams or {}
  gTraces:start(tParams.CHANNEL, tParams.NAME)
  paint()
end

function EC.RECORD_TRACE_STEP(tParams)
  tParams = tParams or {}
  gTraces:step(tParams.CHANNEL, tParams.MESSAGE, tParams.DEVICE)
end

function EC.RECORD_TRACE_DECISION(tParams)
  tParams = tParams or {}
  gTraces:decision(tParams.CHANNEL, tParams.CONDITION, tParams.OUTCOME)
end

function EC.RECORD_EXPECTED_RESULT(tParams)
  tParams = tParams or {}
  gTraces:expected(tParams.CHANNEL, tParams.EXPECTED, tParams.DEVICE)
end

function EC.COMPLETE_TRACE(tParams)
  tParams = tParams or {}
  gTraces:complete(tParams.CHANNEL, tParams.NOTE)
  paint()
end

function EC.FAIL_TRACE(tParams)
  tParams = tParams or {}
  gTraces:fail(tParams.CHANNEL, tParams.REASON)
  paint()
end

function EC.CAPTURE_SNAPSHOT(tParams)
  tParams = tParams or {}
  local jobId, why = requestSnapshot("", "composer", tParams.NOTE)
  if jobId == nil then
    UpdateProperty("Last Snapshot", "refused: " .. tostring(why))
    fire(EVENT_SNAP_FAIL)
  end
end

function EC.PAUSE_RECORDING(tParams)
  tParams = tParams or {}
  if gRecorder:pause("composer: " .. tostring(tParams.REASON or "")) then
    gTraces:interruptAll("recording paused")
    persist:set(PAUSED_KEY, true)
  end
  paint()
  client.sendStatus()
end

function EC.RESUME_RECORDING()
  persist:set(PAUSED_KEY, false)
  gRecorder:resume("composer")
  paint()
  client.sendStatus()
end

-- ─── Conditionals ───────────────────────────────────────────────────────────

function TC.RECORDING_ACTIVE()
  local s = recordingStatus()
  return s == "recording" or s:find("^recording_local") ~= nil
end

function TC.AGENT_READY()
  return client.displayStatus() == "ready"
end
