--[[==========================================================================
  SmartBuildOS Event Tracer
  A module on the expanded SmartBuildOS Agent.

  "Why did the hall light come on at 3 am?" Director tells no driver which
  programming ran, but it will tell a driver every Composer EVENT every
  device fires, once asked. This driver asks for all of them, with no
  configuration, and keeps the answer in two places: a local ring the
  dealer can print without Composer Pro, and `capture.*` envelopes the
  Agent uploads to SmartBuildOS for the Studio timeline.

  The Agent supplies the shared services (registration, the durable event
  pipeline, settings delivery, restricted commands) and is the licensing
  authority (SKU SBOS_EVENT_TRACER through sbos.license). This driver
  supplies the capture policy, the catalogue of which events exist, storm
  and budget protection, and the Composer surface.

  Pure rules: src/tracer/{catalog,ring,tracer}.lua and
  src/sbos/{envelope,moduleclient}.lua — tested without a controller.
  Bench validation: docs/event-tracer/VERIFICATION.md.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-event-tracer.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-event-tracer.c4z" }
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
local Catalog = require("tracer.catalog")
local Ring = require("tracer.ring")
local Tracer = require("tracer.tracer")
--- Required at module scope on purpose: the build's squish step discovers a
--- driver's modules by loading it under the test shim, where LateInit stops
--- at the OS version check. A require inside a function is never seen there
--- and the module is left out of the .c4z (measured 2026-11-09: the built
--- tracer painted "built-in: 0 driver(s)").
local okCatalogData, CatalogData = pcall(require, "tracer.catalog_data")

gInitialized = false

local MODULE_ID = "event_tracer"
local SKU = "SBOS_EVENT_TRACER"
local LEARNED_KEY = "et_learned_v1"
local RING_KEY = "et_ring_v1"
local PAUSED_KEY = "et_paused"
local TICK_TIMER = "EtTick"
local STATUS_TIMER = "EtStatusPaint"
local SOON_TIMER = "EtPaintSoon"
local LEARNED_TIMER = "EtPersistLearned"
local PROJECT_TIMER = "EtProjectChanged"
local PROJECT_XML_MAX_BYTES = 6 * 1024 * 1024
local CHECKPOINT_SECONDS = 30
local PRINT_DEFAULT = 50

local EVENT_DEGRADED, EVENT_RESTORED, EVENT_STORM, EVENT_STORM_END = 1, 2, 3, 4
local EVENT_AGENT_ON, EVENT_AGENT_OFF, EVENT_LEARNED = 5, 6, 7

local gTracer = nil
local gCatalog = nil
local gPolicy = Tracer.defaultPolicy()
local gPolicyRefusals = {}
local gLastStatus = nil
local gBufferWarned = false
local gLastUploadAt = nil
local gLastError = "none"
local gRingDirty = false
local gLastCheckpoint = 0
local gLicenceHalted = false
local gActiveStorms = 0

--- Seconds, with fractions where the controller offers them. A test may
--- pin the clock by defining EVENT_TRACER_NOW before loading the driver.
local gSocket = nil
local function now()
  if type(EVENT_TRACER_NOW) == "function" then
    return EVENT_TRACER_NOW()
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

local function isOn(value)
  return tostring(value or ""):lower() == "on"
end

-- ─── Emission ───────────────────────────────────────────────────────────────

--- Every event this driver records for upload goes through here: envelope in
--- this module's identity, then the module client's stage.
local function emit(fields)
  local env, why = client.event(fields)
  if env == nil then
    gLastError = "event refused: " .. tostring(why)
    log:warn("Event refused (%s): %s", tostring(why), tostring(fields.event_type))
    return nil
  end
  client.sendEvents({ env })
  if fields.event_type == "tracer.storm" then
    fire(EVENT_STORM)
  elseif fields.event_type == "tracer.storm_ended" then
    fire(EVENT_STORM_END)
  elseif fields.event_type == "tracer.learned" then
    fire(EVENT_LEARNED)
  end
  return env
end

-- ─── Status ─────────────────────────────────────────────────────────────────

local function captureStatus()
  if gTracer == nil then
    return "starting"
  end
  if gLicenceHalted then
    return "unlicensed"
  end
  local s = gTracer:status()
  if s ~= "capturing" and s ~= "idle" then
    return s
  end
  local agent = client.displayStatus()
  if agent == "ready" then
    return s
  end
  -- Capture continues locally; only the upload path is impaired.
  return s .. "_local (" .. agent .. ")"
end

local function counters()
  local c = {}
  if gTracer then
    for k, v in pairs(gTracer.counters) do
      c["tracer_" .. k] = v
    end
    c.active_storms = #gTracer:activeStorms()
    c.ring_held = gTracer.ring:count()
    c.ring_seq = gTracer.ring.seq
  end
  if gCatalog then
    for k, v in pairs(gCatalog:counts()) do
      c["catalog_" .. k] = v
    end
  end
  c.policy_refusals = #gPolicyRefusals
  return c
end

local function coverageLine()
  local s = gTracer and gTracer.summary or nil
  if s == nil or s.devices_total == nil then
    return "not applied yet"
  end
  if s.disabled then
    return "capture off"
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

--- The cheap, frequent part of painting: what the last event was.
local function paintRecent()
  if gTracer == nil then
    return
  end
  local e = gTracer:latest()
  if e ~= nil then
    local text = e.kind == "mark" and ("MARK " .. tostring(e.event_name))
      or (tostring(e.device_label or e.device_id) .. ": " .. tostring(e.event_name))
    UpdateProperty("Last Event", string.format("%s  (%s)", text, os.date("%H:%M:%S", math.floor(e.t or 0))))
    setVar("LAST_EVENT", text)
    setVar("LAST_EVENT_DEVICE", tonumber(e.device_id) or 0)
  end
  UpdateProperty("Events Captured", tostring(gTracer.counters.captured))
  setVar("EVENTS_CAPTURED", gTracer.counters.captured)
  local storms = gTracer:activeStorms()
  gActiveStorms = #storms
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

local function paint()
  local status = captureStatus()
  local agent = client.displayStatus()
  local clientState = client._state()
  local buffered = #clientState.staged
  for _, id in ipairs(clientState.pendingOrder) do
    local f = clientState.pending[id]
    if f then
      buffered = buffered + #f.events
    end
  end
  local dropped = (gTracer and gTracer.counters.dropped_budget or 0) + client.counters().events_dropped_local
  UpdateProperty("Capture Status", status)
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
  UpdateProperty("Coverage", coverageLine())
  UpdateProperty("Catalogue", catalogueLine())
  UpdateProperty("Buffered Events", tostring(buffered))
  UpdateProperty("Dropped Events", tostring(dropped))
  UpdateProperty("Last Upload", gLastUploadAt and os.date("%Y-%m-%d %H:%M:%S", gLastUploadAt) or "never")
  local err = gLastError
  if #gPolicyRefusals > 0 then
    local first = gPolicyRefusals[1]
    err = (err ~= "none" and (err .. "; ") or "") .. "setting ignored: " .. first.path .. " " .. first.reason
  end
  UpdateProperty("Last Capture Error", err)
  paintRecent()
  setVar("CAPTURE_STATUS", status)
  setVar("AGENT_CONNECTION", agent)
  setVar("SUBSCRIPTIONS", gTracer and gTracer:subscriptionCount() or 0)
  setVar("BUFFERED_EVENTS", buffered)
  setVar("DROPPED_EVENTS", dropped)
  setVar("LAST_CAPTURE_ERROR", err)

  -- Degraded / restored on TRANSITION only. This driver's own device is
  -- never subscribed, so painting cannot feed back into capture.
  local healthy = status == "capturing" or status == "idle" or status == "disabled"
  if gLastStatus ~= nil and gLastStatus ~= healthy then
    fire(healthy and EVENT_RESTORED or EVENT_DEGRADED)
  end
  gLastStatus = healthy

  local threshold = tointeger(Properties["Buffer Warning Threshold"]) or 200
  if buffered >= threshold and not gBufferWarned then
    gBufferWarned = true
  elseif buffered < threshold / 2 then
    gBufferWarned = false
  end
end

local function paintSoon()
  SetTimer(SOON_TIMER, 2 * ONE_SECOND, paintRecent)
end

-- ─── Policy (Composer properties → tracer policy) ───────────────────────────

local function policyFromProperties()
  return {
    enabled = isOn(Properties["Capture"]),
    probe_unknown = isOn(Properties["Probe Unknown Drivers"]),
    probe_range = Properties["Probe Range"],
    max_subscriptions = Properties["Max Subscriptions"],
    events_per_minute = Properties["Upload Budget"],
    storm_threshold = Properties["Storm Threshold"],
    ring_size = Properties["Local History Size"],
    exclude_device_ids = Properties["Exclude Device IDs"],
    exclude_driver_files = Properties["Exclude Driver Files"],
  }
end

local function applyPolicy(raw, source)
  local policy, refusals = Tracer.validatePolicy(raw)
  if policy == nil then
    gLastError = "policy from " .. tostring(source) .. " refused: " .. refusals[1].reason
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
      gLastError = "apply failed: " .. tostring(err)
      log:error("%s", gLastError)
    else
      gLastError = "none"
    end
  end
  paint()
  client.sendStatus()
  return true, refusals
end

--- A policy from System Studio. One truth stays the Composer properties: the
--- document is merged over the running policy (a key Studio did not send
--- keeps its value), refused whole if any field is invalid (a person is
--- looking at a form; nothing falls back silently), then written INTO the
--- properties and applied. It therefore survives a reload and Composer shows
--- what is running.
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
  UpdateProperty("Capture", onOff(policy.enabled))
  UpdateProperty("Probe Unknown Drivers", onOff(policy.probe_unknown))
  UpdateProperty("Probe Range", tostring(policy.probe_range))
  UpdateProperty("Max Subscriptions", tostring(policy.max_subscriptions))
  UpdateProperty("Upload Budget", tostring(policy.events_per_minute))
  UpdateProperty("Storm Threshold", tostring(policy.storm_threshold))
  UpdateProperty("Local History Size", tostring(policy.ring_size))
  UpdateProperty("Exclude Device IDs", table.concat(ids, ", "))
  UpdateProperty("Exclude Driver Files", table.concat(policy.exclude_driver_files, ", "))
  return applyPolicy(policy, "studio")
end

-- ─── Persistence ────────────────────────────────────────────────────────────

local function persistLearnedSoon()
  SetTimer(LEARNED_TIMER, 5 * ONE_SECOND, function()
    if gCatalog then
      persist:set(LEARNED_KEY, gCatalog:learnedDoc())
    end
  end)
end

local function checkpointRing(force)
  if gTracer == nil or (not gRingDirty and not force) then
    return
  end
  if not force and os.time() - gLastCheckpoint < CHECKPOINT_SECONDS then
    return
  end
  gLastCheckpoint = os.time()
  gRingDirty = false
  persist:set(RING_KEY, gTracer.ring:serialize())
end

-- ─── Licence ────────────────────────────────────────────────────────────────

--- Enforcement is the charter's "read-only" consequence: a DEFINITIVE denial
--- with enforcement on releases every subscription; uncertainty never does.
local function reconcileLicence()
  local halt = license.enforces()
  if halt and not gLicenceHalted then
    gLicenceHalted = true
    if gTracer then
      gTracer:stop()
    end
    gLastError = "SmartBuildOS licence: " .. tostring(license.statusLabel())
    log:warn("%s — capture halted", gLastError)
  elseif not halt and gLicenceHalted then
    gLicenceHalted = false
    gLastError = "none"
    if gTracer and gPolicy.enabled and not gTracer.paused then
      pcall(function()
        gTracer:apply(gPolicy)
      end)
    end
  end
end

--- Composer saves and Agent arrivals come in bursts: one re-plan a few
--- seconds after the last trigger.
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

-- ─── Restricted commands from System Studio (through the Agent) ────────────

local COMMANDS = {
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
    if gTracer:pause("studio: " .. tostring(request.args.reason or "")) then
      persist:set(PAUSED_KEY, true)
      paint()
      return "Completed", "capture paused"
    end
    return "Completed", "already paused"
  end,
  resume = function()
    persist:set(PAUSED_KEY, false)
    if gTracer:resume("studio") then
      paint()
      return "Completed", "capture resumed; " .. coverageLine()
    end
    return "Completed", "already capturing"
  end,
  reapply = function()
    if gTracer.paused then
      return "Completed", "paused; nothing re-applied"
    end
    gTracer:apply(gPolicy)
    paint()
    return "Completed", coverageLine()
  end,
  refresh_status = function()
    paint()
    client.sendStatus()
    return "Completed", captureStatus()
  end,
}

local function onCommand(request)
  local runner = COMMANDS[request.command]
  if runner == nil then
    client.commandResult(request.request_id, "Failed", "unknown Event Tracer command: " .. request.command)
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
    { "CAPTURE_STATUS", "starting", "STRING" },
    { "AGENT_CONNECTION", "waiting_for_agent", "STRING" },
    { "SUBSCRIPTIONS", 0, "NUMBER" },
    { "EVENTS_CAPTURED", 0, "NUMBER" },
    { "ACTIVE_STORMS", 0, "NUMBER" },
    { "LAST_EVENT", "", "STRING" },
    { "LAST_EVENT_DEVICE", 0, "NUMBER" },
    { "BUFFERED_EVENTS", 0, "NUMBER" },
    { "DROPPED_EVENTS", 0, "NUMBER" },
    { "LAST_CAPTURE_ERROR", "", "STRING" },
  }) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { 1, "Capture Degraded", "Capture lost the Agent, the licence or its budget" },
    { 2, "Capture Restored", "Capture is healthy again" },
    { 3, "Event Storm Detected", "One device fired the same event more than Storm Threshold times in a minute" },
    { 4, "Event Storm Ended", "A detected event storm stopped" },
    { 5, "Agent Connected", "Registered with the SmartBuildOS Agent" },
    { 6, "Agent Disconnected", "Lost the registration with the SmartBuildOS Agent" },
    { 7, "Unknown Event Learned", "A probe subscription received an event the catalogue did not list" },
  }) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

local function devices()
  local ok, list = pcall(function()
    return C4:GetDevices({})
  end)
  if ok and type(list) == "table" then
    return list
  end
  return {}
end

--- The PROBE tier: the project with device data. Nil (and the other tiers
--- take over) when the property is Off, the call fails, or the document is
--- too large to hold.
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
  local stored = persist:get(RING_KEY, false)
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
    devices = devices,
    catalog = gCatalog,
    emit = emit,
    selfDeviceId = C4:GetDeviceID(),
    projectXml = projectXml,
    ring = ring,
    onLearned = persistLearnedSoon,
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
  log:setLogName("EventTracer")
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

  gTracer = buildTracer()
  local policy, refusals = Tracer.validatePolicy(policyFromProperties())
  gPolicy = policy or Tracer.defaultPolicy()
  gPolicyRefusals = refusals or {}

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    reconcileLicence()
    paint()
  end

  client.setup({
    module_id = MODULE_ID,
    driver_version = tostring(C4:GetDriverConfigInfo("version")),
    capabilities = { "capture", "storms", "marks", "local_history" },
    entitlements = { SKU },
    commands = { "apply_policy", "pause", "resume", "reapply", "refresh_status" },
    event_types = { "capture.", "tracer." },
    singleton = true,
    status = function()
      return captureStatus(), gLastError ~= "none" and gLastError or "", counters()
    end,
    configVersion = function()
      return "0"
    end,
    onRegistered = function(reply)
      if tostring(reply.ok) == "true" then
        fire(EVENT_AGENT_ON)
        log:info("Event Tracer registered with the Agent")
        -- The licence registration shares the Agent: an Agent added after
        -- this driver is picked up here rather than at the next reload.
        pcall(license.register)
        -- An Agent that was just added is a device the plan has not seen;
        -- its own events are worth capturing, so re-plan shortly.
        scheduleReplan()
      else
        gLastError = "Agent refused registration: " .. tostring(reply.reason)
        fire(EVENT_AGENT_OFF)
      end
      paint()
    end,
    onAgentState = function(agent, why)
      if why == "no_agent" then
        gLastError = "no SmartBuildOS Agent in this project (capturing locally)"
      end
      paint()
    end,
    onCommand = onCommand,
    onConfig = function(settings, version)
      -- Studio settings for this SKU are a policy document.
      local ok, refusals = applyStudioPolicy(settings)
      return ok, #refusals
    end,
    onAck = function(batchId, accepted, params)
      gLastUploadAt = os.time()
      paint()
    end,
  })
  EC.SBOS_MODULE_AGENT_EVENT = function(tParams)
    tParams = tParams or {}
    local name = tostring(tParams.name or "")
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
    gTracer.paused = true
  else
    local okA, errA = pcall(function()
      gTracer:apply(gPolicy)
    end)
    if not okA then
      gLastError = "apply failed: " .. tostring(errA)
      log:error("%s", gLastError)
    end
  end
  client.register()
  SetTimer(TICK_TIMER, 30 * ONE_SECOND, function()
    if gTracer then
      gTracer:tick()
      checkpointRing(false)
    end
  end, true)
  SetTimer(STATUS_TIMER, 60 * ONE_SECOND, paint, true)
  paint()
end

function OnDriverDestroyed()
  if gTracer then
    gTracer:stop()
    checkpointRing(true)
  end
  if gCatalog then
    persist:set(LEARNED_KEY, gCatalog:learnedDoc())
  end
  client.flush()
  client.stop()
  CancelTimer(TICK_TIMER)
  CancelTimer(STATUS_TIMER)
  CancelTimer(SOON_TIMER)
  CancelTimer(LEARNED_TIMER)
  CancelTimer(PROJECT_TIMER)
end

--- Director's callback for every subscribed device event. Replaces the
--- vendored handler, which prints on every call — far too chatty here.
function OnDeviceEvent(idDevice, idEvent)
  if gTracer == nil then
    return
  end
  local ok, err = pcall(function()
    if gTracer:onDeviceEvent(tointeger(idDevice), tointeger(idEvent)) then
      gRingDirty = true
      paintSoon()
    end
  end)
  if not ok then
    log:error("OnDeviceEvent %s/%s: %s", tostring(idDevice), tostring(idEvent), tostring(err))
  end
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
OPC.Capture = policyProperty
OPC.Read_Events_From_Project = policyProperty
OPC.Probe_Unknown_Drivers = policyProperty
OPC.Probe_Range = policyProperty
OPC.Max_Subscriptions = policyProperty
OPC.Storm_Threshold = policyProperty
OPC.Upload_Budget = policyProperty
OPC.Local_History_Size = policyProperty
OPC.Exclude_Device_IDs = policyProperty
OPC.Exclude_Driver_Files = policyProperty

-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.REGISTER_NOW()
  client.register()
end

function EC.REAPPLY()
  if gTracer and not gTracer.paused and not gLicenceHalted then
    gTracer:apply(gPolicy)
  end
  paint()
  client.sendStatus()
end

function EC.PAUSE_CAPTURE_ACTION()
  EC.PAUSE_CAPTURE({ REASON = "Composer action" })
end

function EC.RESUME_CAPTURE_ACTION()
  EC.RESUME_CAPTURE({})
end

function EC.REFRESH_STATUS()
  paint()
  client.sendStatus()
end

function EC.CLEAR_HISTORY()
  if gTracer then
    gTracer.ring = Ring.new(gPolicy.ring_size)
    gRingDirty = true
    checkpointRing(true)
    UpdateProperty("Last Event", "none yet (history cleared)")
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

function EC.PRINT_STATUS()
  log:print("== Event Tracer ==")
  log:print("  status: %s", captureStatus())
  log:print("  agent: %s", client.describe())
  log:print("  licence: %s", license.describe())
  log:print("  coverage: %s", coverageLine())
  log:print("  catalogue: %s", catalogueLine())
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
    log:print("  %s = %s", k, tostring(c[k]))
  end
  for _, s in ipairs(gTracer and gTracer:activeStorms() or {}) do
    log:print(
      "  STORM %s: %s — %d this minute (%d suppressed)",
      tostring(s.device_label),
      s.event_name,
      s.count,
      s.suppressed
    )
  end
end

function EC.PRINT_RECENT()
  if gTracer == nil then
    return
  end
  local list = gTracer:recent(PRINT_DEFAULT)
  log:print("== Event Tracer: last %d of %d held (seq to %d) ==", #list, gTracer.ring:count(), gTracer.ring.seq)
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
  log:print("== Event Tracer: last %d events of device %d ==", #list, id)
  for _, e in ipairs(list) do
    log:print("  %s", Tracer.formatEntry(e))
  end
  local cov = gTracer.coverage[id]
  if cov then
    log:print(
      "  coverage: %s (%s) tier=%s events=%d unsubscribed=%d",
      tostring(cov.label),
      tostring(cov.driver),
      tostring(cov.tier),
      cov.events,
      cov.unsubscribed
    )
  else
    log:print("  not in the current plan (excluded, self, or not in the project)")
  end
end

function EC.PRINT_COVERAGE()
  if gTracer == nil then
    return
  end
  log:print("== Event Tracer coverage: %s ==", coverageLine())
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

-- ─── Composer programming commands ─────────────────────────────────────────

function EC.MARK_TIMELINE(tParams)
  tParams = tParams or {}
  if gTracer == nil then
    return
  end
  if gTracer:mark(tParams.NAME, tParams.DETAIL, tonumber(tParams.DEVICE)) then
    gRingDirty = true
    paintSoon()
  else
    log:warn("MARK_TIMELINE without a NAME")
  end
end

function EC.PAUSE_CAPTURE(tParams)
  tParams = tParams or {}
  if gTracer and gTracer:pause("composer: " .. tostring(tParams.REASON or "")) then
    persist:set(PAUSED_KEY, true)
  end
  paint()
  client.sendStatus()
end

function EC.RESUME_CAPTURE()
  persist:set(PAUSED_KEY, false)
  if gTracer then
    gTracer:resume("composer")
  end
  paint()
  client.sendStatus()
end

-- ─── Conditionals ───────────────────────────────────────────────────────────

function TC.CAPTURE_ACTIVE()
  local s = captureStatus()
  return s == "capturing" or s:find("^capturing_local") ~= nil
end

function TC.AGENT_READY()
  return client.displayStatus() == "ready"
end

function TC.STORM_ACTIVE()
  return gTracer ~= nil and #gTracer:activeStorms() > 0
end
