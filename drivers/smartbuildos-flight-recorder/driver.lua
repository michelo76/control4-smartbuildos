--[[==========================================================================
  SmartBuildOS Flight Recorder
  The first production module built on the expanded SmartBuildOS Agent.

  What happened? Which device or automation was involved? What happened
  immediately before and afterward? Was an action merely REQUESTED, or was
  its result OBSERVED? What evidence supports an explanation?

  One driver, three layers:

    EVENTS     every Composer event every device fires, with no
               configuration (the former Event Tracer driver): which device,
               which event, when. Storm and budget protection.
    VARIABLES  the device and room variables selected in System Studio or by
               a template, with the value before and after each change.
    ROUTINES   what the dealer's programming says it is doing: traces, named
               markers, expected results; and a diagnostic snapshot on demand.

  All three land in ONE local history, in the order they happened, which the
  dealer prints from the Actions tab with no uplink; and all three go through
  the Agent to System Studio.

  The Agent supplies the shared services (registration, the durable event
  pipeline, versioned configuration delivery, restricted commands, snapshot
  upload) and is the licensing authority (SKU SBOS_FLIGHT_RECORDER). Local
  recording continues during an internet or SmartBuildOS outage; uploads
  wait in the Agent.

  Pure rules: src/flightrecorder/{config,recorder,traces,snapshot,history}.lua,
  src/tracer/{catalog,ring,tracer}.lua and src/sbos/{envelope,moduleclient}.lua
  — all tested without a controller.
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
local History = require("flightrecorder.history")
local Catalog = require("tracer.catalog")
local Ring = require("tracer.ring")
local Tracer = require("tracer.tracer")
--- Required at module scope on purpose: the build's squish step discovers a
--- driver's modules by loading it under the test shim, where LateInit stops
--- at the OS version check. A require inside a function is never seen there
--- and the module is left out of the .c4z (measured 2026-11-09: the built
--- driver painted "built-in: 0 driver(s)").
local okCatalogData, CatalogData = pcall(require, "tracer.catalog_data")

gInitialized = false

local MODULE_ID = "flight_recorder"
local SKU = "SBOS_FLIGHT_RECORDER"
local CONFIG_KEY = "fr_config_v1"
local CONFIG_META_KEY = "fr_config_meta_v1"
local PAUSED_KEY = "fr_paused"
local LEARNED_KEY = "fr_learned_v1"
local HISTORY_KEY = "fr_history_v1"
local TRACE_TICK_TIMER = "FrTraceTick"
local STATUS_TIMER = "FrStatusPaint"
local SNAPSHOT_TIMER = "FrSnapshotRun"
local SOON_TIMER = "FrPaintSoon"
local LEARNED_TIMER = "FrPersistLearned"
local PROJECT_TIMER = "FrProjectChanged"
local RECENT_RING = 100
local MAX_JOBS = 10
local SNAPSHOT_ACK_SECONDS = 600
local PROJECT_XML_MAX_BYTES = 6 * 1024 * 1024
local CHECKPOINT_SECONDS = 30
local PRINT_DEFAULT = 50

local EVENT_DEGRADED, EVENT_RESTORED, EVENT_BUFFER, EVENT_SNAP_OK, EVENT_SNAP_FAIL = 1, 2, 3, 4, 5
local EVENT_TRACE_OK, EVENT_TRACE_FAIL, EVENT_AGENT_ON, EVENT_AGENT_OFF = 6, 7, 8, 9
local EVENT_STORM, EVENT_STORM_END, EVENT_LEARNED = 10, 11, 12

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
--- Event capture: the engine, its catalogue of which events exist, and the
--- policy the Composer properties (or System Studio) last set.
local gTracer = nil
local gCatalog = nil
local gPolicy = Tracer.defaultPolicy()
local gPolicyRefusals = {}
local gHistoryDirty = false
local gLastCheckpoint = 0
local gLicenceHalted = false
--- Recorded envelopes other than device events (those are in the history).
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

--- Seconds, with fractions where the controller offers them: two device
--- events in the same second keep their order in the history. A test may pin
--- the clock by defining FLIGHT_RECORDER_NOW before loading the driver.
local gSocket = nil
local function now()
  if type(FLIGHT_RECORDER_NOW) == "function" then
    return FLIGHT_RECORDER_NOW()
  end
  if gSocket == nil then
    local ok, socket = pcall(require, "socket")
    gSocket = (ok and type(socket) == "table" and type(socket.gettime) == "function") and socket or false
  end
  if gSocket then
    return gSocket.gettime()
  end
  return os.time()
end

local function isOn(value)
  return tostring(value or ""):lower() == "on"
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

--- The outcome of the trace that just ended, for the Last Trace property.
--- (Print Last Trace reads the history itself, so it survives a restart.)
local function paintLastTrace(env)
  local p = type(env.payload) == "table" and env.payload or {}
  UpdateProperty(
    "Last Trace",
    string.format(
      "%s: %s (%d step(s), %d s) at %s",
      tostring(p.name or env.label),
      tostring(p.status),
      tonumber(p.steps) or 0,
      tonumber(p.duration_seconds) or 0,
      os.date("%H:%M:%S")
    )
  )
end

--- Every event this driver records goes through here: envelope, the local
--- history (so a variable change or a trace step sits between the device
--- events around it), the recent list snapshots carry, then the module
--- client's stage.
local function emit(fields)
  local env, why = client.event(fields)
  if env == nil then
    gLastError = "event refused: " .. tostring(why)
    log:warn("Event refused (%s): %s", tostring(why), tostring(fields.event_type))
    return nil
  end
  local eventType = tostring(env.event_type)
  if eventType:sub(1, 8) ~= "capture." then
    -- A device event is already in the history: the capture engine put it
    -- there before it asked for the upload. Everything else is offered.
    if gTracer ~= nil then
      local entry = History.entryFor(env, { device = deviceLabel })
      if entry ~= nil then
        gTracer:note(entry)
        gHistoryDirty = true
        if eventType == "trace.end" then
          paintLastTrace(env)
        end
      end
    end
    if eventType ~= "tracer.applied" then
      gRecent[#gRecent + 1] = env
      while #gRecent > RECENT_RING do
        table.remove(gRecent, 1)
      end
    end
  end
  client.sendEvents({ env })
  if eventType == "tracer.storm" then
    fire(EVENT_STORM)
  elseif eventType == "tracer.storm_ended" then
    fire(EVENT_STORM_END)
  elseif eventType == "tracer.learned" then
    fire(EVENT_LEARNED)
  end
  return env
end

-- ─── Status ─────────────────────────────────────────────────────────────────

--- One status for the whole recorder. "recording" means something is being
--- watched: a device event subscription or a variable listener.
local function recordingStatus()
  if gRecorder == nil or gTracer == nil then
    return "starting"
  end
  if gRecorder.paused or gTracer.paused then
    return "paused"
  end
  if not gConfig.enabled and not gPolicy.enabled then
    return "disabled"
  end
  if license.enforces() then
    return "unlicensed"
  end
  local watching = gRecorder:listenerCount() > 0 or gTracer:subscriptionCount() > 0
  local agent = client.displayStatus()
  if agent == "ready" then
    return watching and "recording" or "idle"
  end
  -- Recording continues locally; only the upload path is impaired.
  return (watching and "recording_local" or "idle") .. " (" .. agent .. ")"
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
  if gTracer then
    for k, v in pairs(gTracer.counters) do
      c["tracer_" .. k] = v
    end
    c.active_storms = #gTracer:activeStorms()
    c.history_held = gTracer.ring:count()
    c.history_seq = gTracer.ring.seq
  end
  if gCatalog then
    for k, v in pairs(gCatalog:counts()) do
      c["catalog_" .. k] = v
    end
  end
  c.policy_refusals = #gPolicyRefusals
  c.jobs = 0
  for _ in pairs(gJobs) do
    c.jobs = c.jobs + 1
  end
  c.applied_version = gMeta.applied_version
  c.desired_version = gMeta.desired_version
  c.config_source = gMeta.source
  return c
end

local function coverageLine()
  local s = gTracer and gTracer.summary or nil
  if s == nil or s.devices_total == nil then
    return "not applied yet"
  end
  if s.disabled then
    return "event capture off"
  end
  if s.paused then
    return "paused"
  end
  local parts = {
    string.format(
      "%d subscriptions on %d of %d devices",
      s.subscriptions or 0,
      s.devices_covered or 0,
      s.devices_total or 0
    ),
  }
  if (s.devices_unknown or 0) > 0 then
    parts[#parts + 1] = s.devices_unknown .. " unknown driver(s)"
  end
  if (s.devices_excluded or 0) > 0 then
    parts[#parts + 1] = s.devices_excluded .. " excluded"
  end
  if (s.unsubscribed_events or 0) > 0 then
    parts[#parts + 1] = s.unsubscribed_events .. " event(s) over Max Subscriptions"
  end
  if (s.register_failures or 0) > 0 then
    parts[#parts + 1] = s.register_failures .. " refused by Director"
  end
  return table.concat(parts, "; ")
end

local function catalogueLine()
  if gCatalog == nil then
    return "-"
  end
  local c = gCatalog:counts()
  local s = gTracer and gTracer.summary or nil
  local tiers = s and s.by_tier or {}
  return string.format(
    "project: %d device(s) → %d subs; built-in: %d driver(s) → %d subs; learned: %d event(s) → %d subs; probe: %d subs",
    c.project_devices or 0,
    tiers.project or 0,
    c.builtin_drivers or 0,
    tiers.builtin or 0,
    c.learned_events or 0,
    tiers.learned or 0,
    tiers.probe or 0
  )
end

--- The cheap, frequent part of painting: what the last device event was.
local function paintRecent()
  if gTracer == nil then
    return
  end
  local e = gTracer.ring:filter(function(entry)
    return entry.kind == "event"
  end, 1)[1]
  if e ~= nil then
    local text = tostring(e.device_label or e.device_id) .. ": " .. tostring(e.event_name)
    UpdateProperty("Last Event", string.format("%s  (%s)", text, Tracer.formatWhen(e.t or 0)))
    setVar("LAST_EVENT", text)
    setVar("LAST_EVENT_DEVICE", tonumber(e.device_id) or 0)
  end
  UpdateProperty("Events Captured", tostring(gTracer.counters.captured))
  setVar("EVENTS_CAPTURED", gTracer.counters.captured)
  local storms = gTracer:activeStorms()
  if #storms == 0 then
    UpdateProperty("Active Storms", "none")
  else
    local parts = {}
    for i = 1, math.min(3, #storms) do
      parts[#parts + 1] =
        string.format("%s: %s (%d)", tostring(storms[i].device_label), storms[i].event_name, storms[i].count)
    end
    if #storms > 3 then
      parts[#parts + 1] = "+" .. (#storms - 3) .. " more"
    end
    UpdateProperty("Active Storms", table.concat(parts, "; "))
  end
  setVar("ACTIVE_STORMS", #storms)
end

local function paintSoon()
  SetTimer(SOON_TIMER, 2 * ONE_SECOND, paintRecent)
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
  local dropped = (gRecorder and gRecorder.counters.dropped_budget or 0)
    + (gTracer and gTracer.counters.dropped_budget or 0)
    + client.counters().events_dropped_local
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
  local err = gLastError
  if #gPolicyRefusals > 0 then
    local first = gPolicyRefusals[1]
    err = (err ~= "none" and (err .. "; ") or "") .. "setting ignored: " .. first.path .. " " .. first.reason
  end
  UpdateProperty("Last Recording Error", err)
  UpdateProperty("Event Coverage", coverageLine())
  UpdateProperty("Event Catalogue", catalogueLine())
  paintRecent()
  setVar("SUBSCRIPTIONS", gTracer and gTracer:subscriptionCount() or 0)
  setVar("RECORDING_STATUS", status)
  setVar("AGENT_CONNECTION", agent)
  setVar("SELECTED_SOURCES", #gConfig.sources)
  setVar("ACTIVE_TRACES", gTraces and gTraces:activeCount() or 0)
  setVar("BUFFERED_EVENTS", buffered)
  setVar("DROPPED_EVENTS", dropped)
  setVar("LAST_UPLOAD", gLastUploadAt and os.date("!%Y-%m-%dT%H:%M:%SZ", gLastUploadAt) or "")
  setVar("LAST_RECORDING_ERROR", err)
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
    if not gConfig.enabled or gLicenceHalted then
      -- Kept, not applied: a halted recorder listens to nothing. (A resume
      -- hands the recorder the configuration again: see resumeAll.)
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

-- ─── Event capture policy (Composer properties → capture engine) ───────────

local function policyFromProperties()
  return {
    enabled = isOn(Properties["Event Capture"]),
    probe_unknown = isOn(Properties["Probe Unknown Drivers"]),
    probe_range = Properties["Probe Range"],
    max_subscriptions = Properties["Max Subscriptions"],
    events_per_minute = Properties["Event Upload Budget"],
    storm_threshold = Properties["Storm Threshold"],
    ring_size = Properties["Local History Size"],
    exclude_device_ids = Properties["Exclude Device IDs"],
    exclude_driver_files = Properties["Exclude Driver Files"],
  }
end

local function applyPolicy(raw, source)
  local policy, refusals = Tracer.validatePolicy(raw)
  if policy == nil then
    gLastError = "event capture settings from " .. tostring(source) .. " refused: " .. refusals[1].reason
    paint()
    return false, refusals
  end
  gPolicy = policy
  gPolicyRefusals = refusals
  if gTracer ~= nil and not gLicenceHalted then
    local ok, err = pcall(function()
      gTracer:apply(gPolicy)
    end)
    if not ok then
      gLastError = "event capture apply failed: " .. tostring(err)
      log:error("%s", gLastError)
    elseif gLastError:find("^event capture") then
      gLastError = "none"
    end
  end
  paint()
  client.sendStatus()
  return true, refusals
end

--- Event capture settings from System Studio. One truth stays the Composer
--- properties: the document is merged over the running policy (a key Studio
--- did not send keeps its value), refused whole if any field is invalid (a
--- person is looking at a form; nothing falls back silently), then written
--- INTO the properties and applied. It therefore survives a reload and
--- Composer shows what is running.
local function applyStudioPolicy(raw)
  if type(raw) ~= "table" then
    return false, { { path = "policy", reason = "must be an object" } }
  end
  local merged = {}
  for k, v in pairs(gPolicy or Tracer.defaultPolicy()) do
    merged[k] = v
  end
  for k, v in pairs(raw) do
    merged[k] = v
  end
  local policy, refusals = Tracer.validatePolicy(merged)
  if policy == nil or #refusals > 0 then
    return false, refusals
  end
  local function onOff(value)
    return value and "On" or "Off"
  end
  local ids = {}
  for i, id in ipairs(policy.exclude_device_ids) do
    ids[i] = tostring(id)
  end
  UpdateProperty("Event Capture", onOff(policy.enabled))
  UpdateProperty("Probe Unknown Drivers", onOff(policy.probe_unknown))
  UpdateProperty("Probe Range", tostring(policy.probe_range))
  UpdateProperty("Max Subscriptions", tostring(policy.max_subscriptions))
  UpdateProperty("Event Upload Budget", tostring(policy.events_per_minute))
  UpdateProperty("Storm Threshold", tostring(policy.storm_threshold))
  UpdateProperty("Local History Size", tostring(policy.ring_size))
  UpdateProperty("Exclude Device IDs", table.concat(ids, ", "))
  UpdateProperty("Exclude Driver Files", table.concat(policy.exclude_driver_files, ", "))
  return applyPolicy(policy, "studio")
end

-- ─── Local history and learned events: persistence ─────────────────────────

local function persistLearnedSoon()
  SetTimer(LEARNED_TIMER, 5 * ONE_SECOND, function()
    if gCatalog then
      persist:set(LEARNED_KEY, gCatalog:learnedDoc())
    end
  end)
end

--- The history survives a Director restart; the loss window is the
--- checkpoint interval.
local function checkpointHistory(force)
  if gTracer == nil or (not gHistoryDirty and not force) then
    return
  end
  if not force and os.time() - gLastCheckpoint < CHECKPOINT_SECONDS then
    return
  end
  gLastCheckpoint = os.time()
  gHistoryDirty = false
  persist:set(HISTORY_KEY, gTracer.ring:serialize())
end

-- ─── Licence ────────────────────────────────────────────────────────────────

--- Enforcement is the charter's "read-only" consequence: a DEFINITIVE denial
--- with enforcement on releases every event subscription and every variable
--- listener; uncertainty never does. The history already held stays readable.
local function reconcileLicence()
  local halt = license.enforces()
  if halt and not gLicenceHalted then
    gLicenceHalted = true
    if gTracer then
      gTracer:stop()
    end
    if gRecorder then
      gRecorder:stop()
    end
    gLastError = "SmartBuildOS licence: " .. tostring(license.statusLabel())
    log:warn("%s — recording halted", gLastError)
  elseif not halt and gLicenceHalted then
    gLicenceHalted = false
    gLastError = "none"
    if gTracer and gPolicy.enabled and not gTracer.paused then
      pcall(function()
        gTracer:apply(gPolicy)
      end)
    end
    if gRecorder and gConfig.enabled and not gRecorder.paused then
      pcall(function()
        gRecorder:apply(gConfig)
      end)
    end
  end
end

--- Composer saves and Agent arrivals come in bursts: one re-plan of event
--- capture a few seconds after the last trigger.
local function scheduleReplan()
  SetTimer(PROJECT_TIMER, 5 * ONE_SECOND, function()
    if gTracer and not gLicenceHalted then
      pcall(function()
        gTracer:onProjectChanged()
      end)
      paint()
    end
  end)
end

-- ─── Pause and resume (both halves, always together) ───────────────────────

--- @return boolean changed
local function pauseAll(reason)
  local changed = gRecorder:pause(reason)
  if gTracer:pause(reason) then
    changed = true
  end
  if changed then
    gTraces:interruptAll("recording paused")
    persist:set(PAUSED_KEY, true)
  end
  return changed
end

--- A resume applies what is CONFIGURED NOW, not what each engine last held:
--- after a restart while paused the engines hold their defaults, and a
--- configuration switched off while paused must stay off.
--- @return boolean changed
local function resumeAll(reason)
  persist:set(PAUSED_KEY, false)
  local changed = gRecorder.paused or gTracer.paused
  if not changed then
    return false
  end
  local function note(label, why)
    emit({
      event_type = "recorder.resumed",
      evidence_source = "derived",
      severity = "notice",
      label = label,
      payload = { reason = tostring(reason or ""), note = why },
    })
  end
  if gLicenceHalted then
    -- Nothing may listen; un-pause so that a restored licence resumes.
    gRecorder.paused, gTracer.paused = false, false
    note("Recording resumed (unlicensed: nothing is listening)", "the licence does not allow recording")
    return true
  end
  if gConfig.enabled then
    gRecorder.config = gConfig
    gRecorder:resume(reason)
  else
    gRecorder.paused = false
    note("Recording resumed (variable sources are switched off)", "the configuration is disabled")
  end
  gTracer.policy = gPolicy
  gTracer:resume(reason)
  return true
end

-- ─── Snapshots ──────────────────────────────────────────────────────────────

--- The local history as a snapshot carries it: one readable line per entry.
local function historyForSnapshot()
  local out = {}
  if gTracer == nil then
    return out
  end
  for _, e in ipairs(gTracer:recent(Snapshot.LIMITS.history)) do
    out[#out + 1] = {
      seq = e.seq,
      at = e.t and os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(e.t)) or nil,
      kind = e.kind,
      device_id = e.device_id,
      line = Tracer.formatEntry(e):sub(1, 240),
    }
  end
  return out
end

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
          event_capture = gTracer and {
            status = gTracer:status(),
            coverage = coverageLine(),
            catalogue = catalogueLine(),
            subscriptions = gTracer:subscriptionCount(),
            captured = gTracer.counters.captured,
            dropped_budget = gTracer.counters.dropped_budget,
            storms_seen = gTracer.counters.storms,
            policy = Tracer.policyReport(gPolicy),
          } or nil,
          storms = gTracer and gTracer:activeStorms() or {},
          history = historyForSnapshot(),
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
            if gTracer and (gTracer.summary == nil or (gTracer.summary.subscriptions or 0) == 0) then
              w[#w + 1] = "event capture holds no subscriptions (off, paused, unlicensed or nothing catalogued):"
                .. " the history has no device events from now"
            end
            if gTracer and #gTracer:activeStorms() > 0 then
              w[#w + 1] = "an event storm is in progress: repeats of the storming event are counted, not listed"
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
  apply_policy = function(request)
    local raw = request.args.policy
    if type(raw) ~= "table" then
      return "Failed", "apply_policy needs args.policy"
    end
    local ok, refusals = applyStudioPolicy(raw)
    if ok then
      return "Completed", "applied: " .. coverageLine()
    end
    local first = refusals[1]
    return "Failed",
      "refused, nothing changed: " .. tostring(first and (tostring(first.path) .. " " .. tostring(first.reason)))
  end,
  pause = function(request)
    if pauseAll("studio: " .. tostring(request.args.reason or "")) then
      paint()
      return "Completed", "recording paused"
    end
    return "Completed", "already paused"
  end,
  resume = function()
    if resumeAll("studio") then
      paint()
      return "Completed", "recording resumed; sources re-read; " .. coverageLine()
    end
    return "Completed", "already recording"
  end,
  reapply = function()
    if gTracer.paused then
      return "Completed", "paused; nothing re-applied"
    end
    if gLicenceHalted then
      return "Completed", "unlicensed; nothing re-applied"
    end
    gTracer:apply(gPolicy)
    paint()
    return "Completed", coverageLine()
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
    { "SUBSCRIPTIONS", 0, "NUMBER" },
    { "EVENTS_CAPTURED", 0, "NUMBER" },
    { "ACTIVE_STORMS", 0, "NUMBER" },
    { "LAST_EVENT", "", "STRING" },
    { "LAST_EVENT_DEVICE", 0, "NUMBER" },
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
    { 10, "Event Storm Detected", "One device fired the same event Storm Threshold times in a minute" },
    { 11, "Event Storm Ended", "A detected event storm stopped" },
    { 12, "Unknown Event Learned", "A probe subscription received an event the catalogue did not list" },
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

local function projectDevices()
  local ok, list = pcall(function()
    return C4:GetDevices({})
  end)
  if ok and type(list) == "table" then
    return list
  end
  return {}
end

--- The project with device data, which names the events of Control4's own
--- drivers. Nil (and the built-in and learned catalogues take over) when the
--- property is Off, the call fails, or the document is too large to hold.
local function projectXml()
  if not isOn(Properties["Read Events From Project"]) then
    return nil
  end
  local ok, xml = pcall(function()
    return C4:GetProjectItems("DEVICES", "NO_ROOT_TAGS")
  end)
  if not ok or type(xml) ~= "string" or xml == "" then
    return nil
  end
  if #xml > PROJECT_XML_MAX_BYTES then
    log:warn("Project XML is %d bytes; skipping the project catalogue tier", #xml)
    return nil
  end
  return xml
end

local function buildTracer()
  local builtin = {}
  if okCatalogData and type(CatalogData) == "table" then
    builtin = CatalogData
  else
    log:warn("Built-in event catalogue unavailable: %s", tostring(CatalogData))
  end
  gCatalog = Catalog.new({ builtin = builtin, learned = persist:get(LEARNED_KEY, false) or nil })
  local ring = nil
  local stored = persist:get(HISTORY_KEY, false)
  if type(stored) == "table" then
    local restored, ok = Ring.restore(stored, tonumber(Properties["Local History Size"]))
    if ok then
      ring = restored
    else
      gLastError = "persisted history unreadable; starting empty"
    end
  end
  return Tracer.new({
    now = now,
    register = function(deviceId, eventId)
      local ok = pcall(function()
        C4:RegisterDeviceEvent(deviceId, eventId)
      end)
      return ok
    end,
    unregister = function(deviceId, eventId)
      pcall(function()
        C4:UnregisterDeviceEvent(deviceId, eventId)
      end)
    end,
    devices = projectDevices,
    catalog = gCatalog,
    emit = emit,
    selfDeviceId = C4:GetDeviceID(),
    projectXml = projectXml,
    ring = ring,
    onLearned = persistLearnedSoon,
  })
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

  -- The capture engine first: it owns the history every other part writes to.
  gTracer = buildTracer()
  local policy, policyRefusals = Tracer.validatePolicy(policyFromProperties())
  gPolicy = policy or Tracer.defaultPolicy()
  gPolicyRefusals = policyRefusals or {}

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
    reconcileLicence()
    paint()
  end

  client.setup({
    module_id = MODULE_ID,
    driver_version = tostring(C4:GetDriverConfigInfo("version")),
    capabilities = {
      "recording",
      "traces",
      "snapshots",
      "sbos_events",
      "capture",
      "storms",
      "local_history",
    },
    entitlements = { SKU },
    commands = { "apply_config", "apply_policy", "pause", "resume", "reapply", "capture_snapshot", "refresh_status" },
    event_types = { "observation.", "trace.", "recorder.", "snapshot.", "capture.", "tracer." },
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
        if gLastError:find("^no SmartBuildOS Agent") then
          gLastError = "none"
        end
        -- The licence registration shares the Agent: an Agent added after
        -- this driver is picked up here rather than at the next reload.
        pcall(license.register)
        -- An Agent that was just added is a device event capture has not
        -- seen; its own events are worth capturing, so re-plan shortly.
        scheduleReplan()
      else
        gLastError = "Agent refused registration: " .. tostring(reply.reason)
        fire(EVENT_AGENT_OFF)
      end
      paint()
    end,
    onAgentState = function(agent, why)
      if why == "no_agent" then
        gLastError = "no SmartBuildOS Agent in this project (recording locally)"
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
    local name = tostring(tParams.name or "")
    if gRecorder then
      gRecorder:onSbosEvent(name, ok and detail or {})
    end
    if name == "project_changed" or name == "director_reloaded" then
      scheduleReplan()
    end
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)

  if persist:get(PAUSED_KEY, false) == true then
    gRecorder.paused = true
    gTracer.paused = true
    -- A resume re-applies what the recorder holds. Started paused, it holds
    -- nothing yet, and a resume after a reload listened to no source at all
    -- until the next configuration arrived: hand it the stored one.
    if gConfig.enabled then
      gRecorder.config = gConfig
    end
    gTracer.policy = gPolicy
  else
    local okE, errE = pcall(function()
      gTracer:apply(gPolicy)
    end)
    if not okE then
      gLastError = "event capture apply failed: " .. tostring(errE)
      log:error("%s", gLastError)
    end
    if gConfig.enabled then
      local okA, errA = pcall(function()
        gRecorder:apply(gConfig)
      end)
      if not okA then
        gLastError = "apply failed: " .. tostring(errA)
        log:error("%s", gLastError)
      end
    end
  end
  client.register()
  SetTimer(TRACE_TICK_TIMER, 30 * ONE_SECOND, function()
    if gTraces then
      gTraces:tick()
    end
    if gTracer then
      gTracer:tick()
      checkpointHistory(false)
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
  pcall(license.stop) -- the licence retry timer
  if gTraces then
    gTraces:interruptAll("driver removed or reloaded")
  end
  if gRecorder then
    gRecorder:stop()
  end
  if gTracer then
    gTracer:stop()
    checkpointHistory(true)
  end
  if gCatalog then
    persist:set(LEARNED_KEY, gCatalog:learnedDoc())
  end
  client.flush()
  client.stop()
  CancelTimer(TRACE_TICK_TIMER)
  CancelTimer(STATUS_TIMER)
  CancelTimer(SNAPSHOT_TIMER)
  CancelTimer(SOON_TIMER)
  CancelTimer(LEARNED_TIMER)
  CancelTimer(PROJECT_TIMER)
end

--- Director's callback for every subscribed device event. Replaces the
--- vendored handler, which prints on every call: far too chatty here.
function OnDeviceEvent(idDevice, idEvent)
  if gTracer == nil then
    return
  end
  local ok, err = pcall(function()
    if gTracer:onDeviceEvent(tointeger(idDevice), tointeger(idEvent)) then
      gHistoryDirty = true
      paintSoon()
    end
  end)
  if not ok then
    log:error("OnDeviceEvent %s/%s: %s", tostring(idDevice), tostring(idEvent), tostring(err))
  end
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

local function policyProperty()
  if gInitialized then
    applyPolicy(policyFromProperties(), "composer")
  end
end
OPC.Event_Capture = policyProperty
OPC.Read_Events_From_Project = policyProperty
OPC.Probe_Unknown_Drivers = policyProperty
OPC.Probe_Range = policyProperty
OPC.Max_Subscriptions = policyProperty
OPC.Storm_Threshold = policyProperty
OPC.Event_Upload_Budget = policyProperty
OPC.Local_History_Size = policyProperty
OPC.Exclude_Device_IDs = policyProperty
OPC.Exclude_Driver_Files = policyProperty

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
  log:print("  event coverage: %s", coverageLine())
  log:print("  event catalogue: %s", catalogueLine())
  for _, r in ipairs(gPolicyRefusals) do
    log:print("  setting ignored: %s %s", r.path, r.reason)
  end
  local c = counters()
  local keys = {}
  for k in pairs(c) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    log:print("  %s = %s", tostring(k), tostring(c[k]))
  end
  for _, storm in ipairs(gTracer and gTracer:activeStorms() or {}) do
    log:print(
      "  STORM %s: %s — %d this minute (%d not listed)",
      tostring(storm.device_label),
      storm.event_name,
      storm.count,
      storm.suppressed
    )
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
  log:print(
    "  history: %d entr%s held; run Print Recent History to read them",
    gTracer and gTracer.ring:count() or 0,
    (gTracer and gTracer.ring:count() or 0) == 1 and "y" or "ies"
  )
end

--- The history: device events, variable changes, trace steps and markers in
--- the order they happened.
function EC.PRINT_RECENT()
  if gTracer == nil then
    return
  end
  local list = gTracer:recent(PRINT_DEFAULT)
  log:print("== Flight Recorder history: last %d of %d held (to #%d) ==", #list, gTracer.ring:count(), gTracer.ring.seq)
  for _, e in ipairs(list) do
    log:print("  %s", Tracer.formatEntry(e))
  end
end

function EC.PRINT_DEVICE()
  if gTracer == nil then
    return
  end
  local id = tonumber(Properties["Inspect Device ID"])
  if id == nil then
    log:print("Set Inspect Device ID to a Director device id first")
    return
  end
  local list = gTracer:forDevice(id, PRINT_DEFAULT)
  log:print("== Flight Recorder history: last %d entries of device %d ==", #list, id)
  for _, e in ipairs(list) do
    log:print("  %s", Tracer.formatEntry(e))
  end
  local cov = gTracer.coverage[id]
  if cov then
    log:print(
      "  event coverage: %s (%s) tier=%s events=%d unsubscribed=%d",
      tostring(cov.label),
      tostring(cov.driver),
      tostring(cov.tier),
      cov.events,
      cov.unsubscribed
    )
  else
    log:print("  events: not in the current plan (excluded, this driver, or not in the project)")
  end
  local watched = 0
  for _, o in ipairs(gRecorder and gRecorder:observations() or {}) do
    if o.device_id == id then
      watched = watched + 1
      log:print("  variable %s = %s", tostring(o.variable), tostring(o.value))
    end
  end
  if watched == 0 then
    log:print("  variables: none of this device's variables is a selected source")
  end
end

--- Everything the history holds between the start and the end of the last
--- trace that ended: the routine's own steps and markers, and whatever the
--- house did in between. Read from the history itself, so it still answers
--- after a restart. A trace still running is printed, up to now, only when
--- none has ended.
function EC.PRINT_LAST_TRACE()
  if gTracer == nil then
    return
  end
  local ring = gTracer.ring
  local last = ring:filter(function(e)
    return e.kind == "trace" and e.status ~= nil
  end, 1)[1]
  local running = false
  if last == nil then
    last = ring:filter(function(e)
      return e.kind == "trace" and e.step == "start"
    end, 1)[1]
    running = last ~= nil
  end
  if last == nil then
    log:print("The history holds no trace. Add START_TRACE and COMPLETE_TRACE to a routine.")
    return
  end
  local id = last.trace_id
  local start = running and last
    or ring:filter(function(e)
      return e.kind == "trace" and e.trace_id == id and e.step == "start"
    end, 1)[1]
  local to = running and ring.seq or last.seq
  log:print(
    "== Flight Recorder trace: %s on %s — %s ==",
    tostring(last.name or (start and start.name) or "?"),
    tostring(last.channel or "main"),
    running and "still running" or tostring(last.text)
  )
  local from = start and start.seq or nil
  if from == nil then
    log:print("  the start of this trace is no longer held: Local History Size is %d", ring.capacity)
    from = ring:filter(function(e)
      return e.trace_id == id
    end)[1].seq
  end
  local own, others = 0, 0
  for _, e in
    ipairs(ring:filter(function(e)
      return e.seq >= from and e.seq <= to
    end))
  do
    local mine = e.trace_id ~= nil and e.trace_id == id
    if mine then
      own = own + 1
    else
      others = others + 1
    end
    log:print("  %s %s", mine and ">" or " ", Tracer.formatEntry(e))
  end
  log:print("  %d line(s) from the trace (>), %d from the house in between", own, others)
end

function EC.PRINT_COVERAGE()
  if gTracer == nil then
    return
  end
  log:print("== Flight Recorder event coverage: %s ==", coverageLine())
  for _, c in ipairs(gTracer:coverageList()) do
    log:print(
      "  %5d  %-32s %-36s %-8s %3d events%s",
      c.device_id,
      tostring(c.label or ""):sub(1, 32),
      tostring(c.driver or ""):sub(1, 36),
      tostring(c.tier or "unknown"),
      c.events,
      c.unsubscribed > 0 and (" (" .. c.unsubscribed .. " not subscribed)") or ""
    )
  end
end

function EC.REAPPLY()
  if gTracer and not gTracer.paused and not gLicenceHalted then
    gTracer:apply(gPolicy)
  end
  paint()
  client.sendStatus()
end

function EC.CLEAR_HISTORY()
  if gTracer then
    gTracer.ring = Ring.new(gPolicy.ring_size)
    gHistoryDirty = true
    checkpointHistory(true)
    UpdateProperty("Last Event", "none yet (history cleared)")
    UpdateProperty("Last Trace", "none yet (history cleared)")
    log:info("Local history cleared")
  end
end

function EC.FORGET_LEARNED()
  if gCatalog then
    gCatalog.learned = {}
    persist:set(LEARNED_KEY, {})
    if gTracer and not gTracer.paused and not gLicenceHalted then
      gTracer:apply(gPolicy)
    end
    paint()
    log:info("Learned events forgotten")
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
  pauseAll("composer: " .. tostring(tParams.REASON or ""))
  paint()
  client.sendStatus()
end

function EC.RESUME_RECORDING()
  resumeAll("composer")
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

function TC.STORM_ACTIVE()
  return gTracer ~= nil and #gTracer:activeStorms() > 0
end
