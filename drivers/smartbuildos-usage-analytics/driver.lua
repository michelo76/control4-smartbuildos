--[[==========================================================================
  SmartBuildOS Usage Analytics
  A module on the expanded SmartBuildOS Agent.

  Which rooms play media, on what, for how long; which lights burn the
  longest; which keypad buttons nobody ever presses. Measured on the
  controller from the variables and events the project already exposes,
  rolled up per day, kept 30 days, printable from Composer and uploaded
  once a day through the Agent for the Studio usage view. The dealer walks
  into a service visit knowing what to reprogram.

  The Agent supplies the shared services (registration, the durable event
  pipeline, restricted commands) and is the licensing authority (SKU
  SBOS_USAGE_ANALYTICS through sbos.license). This driver supplies the
  source plan (which rooms, lights, keypads), the meter, the rollups and
  the Composer surface.

  Pure rules: src/usage/{sources,meter}.lua — tested without a controller.
  Bench validation owed: docs/smartbuildos-usage-analytics/DESIGN.md.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-usage-analytics.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-usage-analytics.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

-- Every require at module scope: the build discovers modules by loading this
-- file under the shim, so a lazy require is left out of the .c4z.
local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local client = require("sbos.moduleclient")
local Catalog = require("tracer.catalog")
local CatalogData = require("tracer.catalog_data")
local Sources = require("usage.sources")
local Meter = require("usage.meter")

gInitialized = false

local MODULE_ID = "usage_analytics"
local SKU = "SBOS_USAGE_ANALYTICS"
local METER_KEY = "ua_meter_v1"
local LAST_DAILY_KEY = "ua_last_daily_v1"
local TICK_TIMER = "UaTick"
local STATUS_TIMER = "UaStatusPaint"
local REPLAN_TIMER = "UaReplan"
local CHECKPOINT_SECONDS = 300

local EVENT_DEGRADED, EVENT_RESTORED, EVENT_DAILY, EVENT_AGENT_ON, EVENT_AGENT_OFF = 1, 2, 3, 4, 5

local gMeter = nil
local gCatalog = nil
local gPlan = nil
local gListeners = {} -- "dev:var" -> { device_id, variable_id, kind = "room"|"light", name }
local gSubscriptions = {} -- "dev:ev" -> { device_id, event_id, name }
local gLastStatus = nil
local gLastUploadAt = nil
local gLastDailyAt = nil
local gLastError = "none"
local gDirty = false
local gLastCheckpoint = 0
local gLicenceHalted = false

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

local function now()
  return os.time()
end

local function dayOf(t)
  return os.date("%Y-%m-%d", math.floor(t))
end

-- ─── Emission ───────────────────────────────────────────────────────────────

local function emit(fields)
  local env, why = client.event(fields)
  if env == nil then
    gLastError = "event refused: " .. tostring(why)
    log:warn("Event refused (%s): %s", tostring(why), tostring(fields.event_type))
    return nil
  end
  client.sendEvents({ env })
  return env
end

-- ─── Status ─────────────────────────────────────────────────────────────────

local function listenerCount()
  local n = 0
  for _ in pairs(gListeners) do
    n = n + 1
  end
  for _ in pairs(gSubscriptions) do
    n = n + 1
  end
  return n
end

local function measuringStatus()
  if gMeter == nil then
    return "starting"
  end
  if gLicenceHalted then
    return "unlicensed"
  end
  if not isOn(Properties["Measuring"]) then
    return "disabled"
  end
  local s = listenerCount() > 0 and "measuring" or "idle"
  local agent = client.displayStatus()
  if agent == "ready" then
    return s
  end
  return s .. "_local (" .. agent .. ")"
end

local function counters()
  local c = {}
  if gMeter then
    for k, v in pairs(gMeter.counters) do
      c["meter_" .. k] = v
    end
    local n = 0
    for _ in pairs(gMeter.days) do
      n = n + 1
    end
    c.days_recorded = n
  end
  if gPlan then
    for k, v in pairs(gPlan.summary) do
      c["plan_" .. k] = v
    end
  end
  c.listeners = listenerCount()
  return c
end

local function daysRecorded()
  local n = 0
  for _ in pairs(gMeter and gMeter.days or {}) do
    n = n + 1
  end
  return n
end

local function todayLine()
  if gMeter == nil then
    return "nothing yet"
  end
  local s = gMeter:summary(1)
  return string.format(
    "media %.1f h, lights %.1f h, %d keypad press(es)",
    Meter.hours(s.media_seconds),
    Meter.hours(s.light_seconds),
    s.presses
  )
end

local function paint()
  local status = measuringStatus()
  local agent = client.displayStatus()
  local clientState = client._state()
  local buffered = #clientState.staged
  for _, id in ipairs(clientState.pendingOrder) do
    local f = clientState.pending[id]
    if f then
      buffered = buffered + #f.events
    end
  end
  local dropped = client.counters().events_dropped_local
  UpdateProperty("Measuring Status", status)
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
  UpdateProperty("Sources", Sources.describe(gPlan and gPlan.summary or nil))
  local today = todayLine()
  UpdateProperty("Today", today)
  UpdateProperty("Days Recorded", tostring(daysRecorded()))
  UpdateProperty("Last Daily Summary", gLastDailyAt and os.date("%Y-%m-%d %H:%M:%S", gLastDailyAt) or "none")
  UpdateProperty("Buffered Events", tostring(buffered))
  UpdateProperty("Dropped Events", tostring(dropped))
  UpdateProperty("Last Upload", gLastUploadAt and os.date("%Y-%m-%d %H:%M:%S", gLastUploadAt) or "never")
  UpdateProperty("Last Error", gLastError)
  setVar("MEASURING_STATUS", status)
  setVar("AGENT_CONNECTION", agent)
  if gMeter then
    local s = gMeter:summary(1)
    setVar("MEDIA_HOURS_TODAY", tostring(Meter.hours(s.media_seconds)))
    setVar("LIGHT_HOURS_TODAY", tostring(Meter.hours(s.light_seconds)))
    setVar("KEYPAD_PRESSES_TODAY", s.presses)
  end
  setVar("DAYS_RECORDED", daysRecorded())
  setVar("SOURCES", Sources.describe(gPlan and gPlan.summary or nil))
  setVar("BUFFERED_EVENTS", buffered)
  setVar("DROPPED_EVENTS", dropped)
  setVar("LAST_ERROR", gLastError)

  local healthy = status == "measuring" or status == "idle" or status == "disabled"
  if gLastStatus ~= nil and gLastStatus ~= healthy then
    fire(healthy and EVENT_RESTORED or EVENT_DEGRADED)
  end
  gLastStatus = healthy
end

-- ─── Director surface ───────────────────────────────────────────────────────

local function devices()
  local ok, list = pcall(function()
    return C4:GetDevices({})
  end)
  if ok and type(list) == "table" then
    return list
  end
  return {}
end

local function readVariables(deviceId)
  local ok, vars = pcall(function()
    return C4:GetDeviceVariables(deviceId)
  end)
  if ok and type(vars) == "table" and next(vars) ~= nil then
    return vars
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

local function excludedIds()
  local out = {}
  for s in tostring(Properties["Exclude Device IDs"] or ""):gmatch("[^,;%s]+") do
    local n = tonumber(s)
    if n ~= nil then
      out[n] = true
    end
  end
  return out
end

local function lkey(a, b)
  return tostring(a) .. ":" .. tostring(b)
end

local function releaseAll()
  for _, l in pairs(gListeners) do
    pcall(function()
      C4:UnregisterVariableListener(l.device_id, l.variable_id)
    end)
  end
  for _, s in pairs(gSubscriptions) do
    pcall(function()
      C4:UnregisterDeviceEvent(s.device_id, s.event_id)
    end)
  end
  gListeners = {}
  gSubscriptions = {}
end

--- Plans against the project, reconciles listeners and subscriptions, and
--- seeds the meter from current values so a room already playing counts
--- from now rather than from its next change.
local function applyPlan()
  if gMeter == nil then
    return
  end
  if gLicenceHalted or not isOn(Properties["Measuring"]) then
    releaseAll()
    gPlan = nil
    return
  end
  local plan = Sources.plan({
    devices = devices(),
    readVariables = readVariables,
    catalog = gCatalog,
    excluded = excludedIds(),
    selfDeviceId = C4:GetDeviceID(),
  })
  gPlan = plan
  -- Desired sets.
  local wantL, wantS = {}, {}
  local roomIds, lightIds, keypadIds = {}, {}, {}
  for roomId, r in pairs(plan.rooms) do
    roomIds[roomId] = true
    gMeter:addRoom(roomId, r.label)
    for varId, name in pairs(r.vars) do
      wantL[lkey(roomId, varId)] = { device_id = roomId, variable_id = varId, kind = "room", name = name }
    end
  end
  for id, l in pairs(plan.lights) do
    lightIds[id] = true
    gMeter:addLight(id, l.label, l.room)
    for varId, name in pairs(l.vars) do
      wantL[lkey(id, varId)] = { device_id = id, variable_id = varId, kind = "light", name = name }
    end
  end
  for id, k in pairs(plan.keypads) do
    keypadIds[id] = true
    gMeter:addKeypad(id, k.label, k.room)
    for eid, name in pairs(k.events) do
      wantS[lkey(id, eid)] = { device_id = id, event_id = eid, name = name }
    end
  end
  gMeter:keepOnly(roomIds, lightIds, keypadIds)
  -- Reconcile listeners.
  for key, l in pairs(gListeners) do
    if wantL[key] == nil then
      pcall(function()
        C4:UnregisterVariableListener(l.device_id, l.variable_id)
      end)
      gListeners[key] = nil
    end
  end
  for key, l in pairs(wantL) do
    if gListeners[key] == nil then
      local ok = pcall(function()
        C4:RegisterVariableListener(l.device_id, l.variable_id)
      end)
      if ok then
        gListeners[key] = l
      end
    else
      gListeners[key].name = l.name
    end
  end
  for key, s in pairs(gSubscriptions) do
    if wantS[key] == nil then
      pcall(function()
        C4:UnregisterDeviceEvent(s.device_id, s.event_id)
      end)
      gSubscriptions[key] = nil
    end
  end
  for key, s in pairs(wantS) do
    if gSubscriptions[key] == nil then
      local ok = pcall(function()
        C4:RegisterDeviceEvent(s.device_id, s.event_id)
      end)
      if ok then
        gSubscriptions[key] = s
      end
    end
  end
  -- Seed current values (not changes).
  for roomId, r in pairs(plan.rooms) do
    local vars = readVariables(roomId)
    if vars then
      for varId, name in pairs(r.vars) do
        local v = vars[varId] or vars[tostring(varId)]
        if type(v) == "table" then
          gMeter:onRoomVariable(roomId, name, v.value, true)
        end
      end
    end
  end
  for id, l in pairs(plan.lights) do
    local vars = readVariables(id)
    if vars then
      for varId, name in pairs(l.vars) do
        local v = vars[varId] or vars[tostring(varId)]
        if type(v) == "table" then
          gMeter:onLightVariable(id, name, v.value, true)
        end
      end
    end
  end
  gDirty = true
  emit({
    event_type = "usage.plan_applied",
    evidence_source = "derived",
    severity = "info",
    label = "Usage sources planned: " .. Sources.describe(plan.summary),
    payload = plan.summary,
  })
end

local function scheduleReplan()
  SetTimer(REPLAN_TIMER, 5 * ONE_SECOND, function()
    pcall(applyPlan)
    paint()
  end)
end

-- ─── Persistence ────────────────────────────────────────────────────────────

local function checkpoint(force)
  if gMeter == nil or (not gDirty and not force) then
    return
  end
  if not force and os.time() - gLastCheckpoint < CHECKPOINT_SECONDS then
    return
  end
  gLastCheckpoint = os.time()
  gDirty = false
  persist:set(METER_KEY, gMeter:serialize())
end

-- ─── Daily summary ──────────────────────────────────────────────────────────

local function sendDaily(day)
  local env = emit({
    event_type = "usage.daily",
    evidence_source = "derived",
    severity = "info",
    label = "Usage " .. tostring(day),
    correlation_id = "usage-daily-" .. tostring(day),
    payload = gMeter:payload(day),
  })
  if env ~= nil then
    gLastDailyAt = os.time()
    persist:set(LAST_DAILY_KEY, { day = day, at = gLastDailyAt })
    fire(EVENT_DAILY)
  end
  return env ~= nil
end

local function sendSummary(days)
  days = tonumber(days) or 7
  if days ~= 1 and days ~= 7 and days ~= 30 then
    days = 7
  end
  return emit({
    event_type = "usage.summary",
    evidence_source = "derived",
    severity = "info",
    label = string.format("Usage summary, %d day(s)", days),
    payload = gMeter:payload(days),
  }) ~= nil
end

local function tick()
  if gMeter == nil then
    return
  end
  local closed = gMeter:tick()
  for _, day in ipairs(closed) do
    sendDaily(day)
  end
  if #closed > 0 then
    gDirty = true
  end
  checkpoint(false)
end

-- ─── Licence ────────────────────────────────────────────────────────────────

local function reconcileLicence()
  local halt = license.enforces()
  if halt and not gLicenceHalted then
    gLicenceHalted = true
    releaseAll()
    gLastError = "SmartBuildOS licence: " .. tostring(license.statusLabel())
    log:warn("%s — measuring halted", gLastError)
  elseif not halt and gLicenceHalted then
    gLicenceHalted = false
    gLastError = "none"
    pcall(applyPlan)
  end
end

-- ─── Restricted commands from System Studio (through the Agent) ────────────

local COMMANDS = {
  send_summary = function(request)
    local ok = sendSummary(request.args.days)
    return ok and "Completed" or "Failed", ok and "summary staged" or gLastError
  end,
  reapply = function()
    applyPlan()
    paint()
    return "Completed", Sources.describe(gPlan and gPlan.summary or nil)
  end,
  refresh_status = function()
    paint()
    client.sendStatus()
    return "Completed", measuringStatus()
  end,
}

local function onCommand(request)
  local runner = COMMANDS[request.command]
  if runner == nil then
    client.commandResult(request.request_id, "Failed", "unknown Usage Analytics command: " .. request.command)
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
    { "MEASURING_STATUS", "starting", "STRING" },
    { "AGENT_CONNECTION", "waiting_for_agent", "STRING" },
    { "MEDIA_HOURS_TODAY", "0", "STRING" },
    { "LIGHT_HOURS_TODAY", "0", "STRING" },
    { "KEYPAD_PRESSES_TODAY", 0, "NUMBER" },
    { "DAYS_RECORDED", 0, "NUMBER" },
    { "SOURCES", "", "STRING" },
    { "BUFFERED_EVENTS", 0, "NUMBER" },
    { "DROPPED_EVENTS", 0, "NUMBER" },
    { "LAST_ERROR", "", "STRING" },
  }) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { 1, "Measuring Degraded", "Measuring lost the Agent, the licence or its sources" },
    { 2, "Measuring Restored", "Measuring is healthy again" },
    { 3, "Daily Summary Sent", "Yesterday's usage summary was handed to the Agent" },
    { 4, "Agent Connected", "Registered with the SmartBuildOS Agent" },
    { 5, "Agent Disconnected", "Lost the registration with the SmartBuildOS Agent" },
  }) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

local function buildMeter()
  local deps = { now = now, dayOf = dayOf, deviceLabel = deviceLabel }
  -- When the last daily summary went out: without this the property read
  -- "none" after every driver update, whatever had been sent.
  local lastDaily = persist:get(LAST_DAILY_KEY, false)
  gLastDailyAt = type(lastDaily) == "table" and tonumber(lastDaily.at) or nil
  local stored = persist:get(METER_KEY, false)
  if type(stored) == "table" then
    local restored, ok = Meter.restore(deps, stored)
    if ok then
      return restored
    end
    gLastError = "persisted statistics unreadable; starting empty"
  end
  return Meter.new(deps)
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName("UsageAnalytics")
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

  gCatalog = Catalog.new({ builtin = type(CatalogData) == "table" and CatalogData or {} })
  gMeter = buildMeter()

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    reconcileLicence()
    paint()
  end

  client.setup({
    module_id = MODULE_ID,
    driver_version = tostring(C4:GetDriverConfigInfo("version")),
    capabilities = { "media_hours", "light_hours", "keypad_presses", "daily_rollup" },
    entitlements = { SKU },
    commands = { "send_summary", "reapply", "refresh_status" },
    event_types = { "usage." },
    singleton = true,
    status = function()
      return measuringStatus(), gLastError ~= "none" and gLastError or "", counters()
    end,
    configVersion = function()
      return "0"
    end,
    onRegistered = function(reply)
      if tostring(reply.ok) == "true" then
        fire(EVENT_AGENT_ON)
        log:info("Usage Analytics registered with the Agent")
        pcall(license.register)
        scheduleReplan()
      else
        gLastError = "Agent refused registration: " .. tostring(reply.reason)
        fire(EVENT_AGENT_OFF)
      end
      paint()
    end,
    onAgentState = function(agent, why)
      if why == "no_agent" then
        gLastError = "no SmartBuildOS Agent in this project (measuring locally)"
      end
      paint()
    end,
    onCommand = onCommand,
    onConfig = function()
      return true, 0
    end,
    onAck = function()
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

  local okA, errA = pcall(applyPlan)
  if not okA then
    gLastError = "plan failed: " .. tostring(errA)
    log:error("%s", gLastError)
  end
  client.register()
  SetTimer(TICK_TIMER, 60 * ONE_SECOND, tick, true)
  SetTimer(STATUS_TIMER, 60 * ONE_SECOND, paint, true)
  paint()
end

function OnDriverDestroyed()
  pcall(license.stop) -- the licence retry timer
  releaseAll()
  checkpoint(true)
  client.flush()
  client.stop()
  CancelTimer(TICK_TIMER)
  CancelTimer(STATUS_TIMER)
  CancelTimer(REPLAN_TIMER)
end

--- Director's callback for every watched variable (rooms and lights).
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  if gMeter == nil then
    return
  end
  local l = gListeners[lkey(tointeger(idDevice), tointeger(idVariable))]
  if l == nil then
    return
  end
  local ok, err = pcall(function()
    if l.kind == "room" then
      gMeter:onRoomVariable(l.device_id, l.name, strValue)
    else
      gMeter:onLightVariable(l.device_id, l.name, strValue)
    end
    gDirty = true
  end)
  if not ok then
    log:error("OnWatchedVariableChanged %s/%s: %s", tostring(idDevice), tostring(idVariable), tostring(err))
  end
end

--- Director's callback for every subscribed keypad event. Replaces the
--- vendored handler, which prints on every call.
function OnDeviceEvent(idDevice, idEvent)
  if gMeter == nil then
    return
  end
  local s = gSubscriptions[lkey(tointeger(idDevice), tointeger(idEvent))]
  if s == nil then
    return
  end
  local ok, err = pcall(function()
    gMeter:onKeypadPress(s.device_id, s.event_id, s.name)
    gDirty = true
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

local function replanProperty()
  if gInitialized then
    applyPlan()
    paint()
    client.sendStatus()
  end
end
OPC.Measuring = replanProperty
OPC.Exclude_Device_IDs = replanProperty

-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.REGISTER_NOW()
  client.register()
end

function EC.REFRESH_STATUS()
  paint()
  client.sendStatus()
end

function EC.REFRESH_SOURCES()
  applyPlan()
  paint()
  client.sendStatus()
end

function EC.SEND_SUMMARY()
  local range = tostring(Properties["Report Range"] or "7 days")
  local days = range == "Today" and 1 or (range == "30 days" and 30 or 7)
  if not sendSummary(days) then
    log:warn("Summary not staged: %s", gLastError)
  end
  paint()
end

function EC.SEND_USAGE_SUMMARY(tParams)
  tParams = tParams or {}
  sendSummary(tParams.DAYS)
end

function EC.RESET_STATISTICS()
  if gMeter == nil then
    return
  end
  releaseAll()
  gMeter = Meter.new({ now = now, dayOf = dayOf, deviceLabel = deviceLabel })
  persist:set(METER_KEY, gMeter:serialize())
  persist:delete(LAST_DAILY_KEY)
  gLastDailyAt = nil
  applyPlan()
  paint()
  log:info("Usage statistics reset")
end

function EC.PRINT_SOURCES()
  if gPlan == nil then
    log:print("Usage Analytics: no plan (measuring off, unlicensed, or not started)")
    return
  end
  log:print("== Usage Analytics sources: %s ==", Sources.describe(gPlan.summary))
  local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
  end
  for _, id in ipairs(sortedKeys(gPlan.rooms)) do
    local r = gPlan.rooms[id]
    local names = {}
    for _, n in pairs(r.vars) do
      names[#names + 1] = n
    end
    table.sort(names)
    log:print("  room %5d  %-28s %s", id, tostring(r.label):sub(1, 28), table.concat(names, ", "))
  end
  for _, id in ipairs(sortedKeys(gPlan.lights)) do
    local l = gPlan.lights[id]
    log:print("  light %4d  %-28s %s", id, tostring(l.label):sub(1, 28), tostring(l.room or ""))
  end
  for _, id in ipairs(sortedKeys(gPlan.keypads)) do
    local k = gPlan.keypads[id]
    local n = 0
    for _ in pairs(k.events) do
      n = n + 1
    end
    log:print("  keypad %3d  %-28s %d press event(s)", id, tostring(k.label):sub(1, 28), n)
  end
end

function EC.PRINT_REPORT()
  if gMeter == nil then
    return
  end
  local range = tostring(Properties["Report Range"] or "7 days")
  local days = range == "Today" and 1 or (range == "30 days" and 30 or 7)
  for _, line in ipairs(gMeter:reportLines(days, range)) do
    log:print("%s", line)
  end
  log:print("  status: %s | agent: %s | licence: %s", measuringStatus(), client.describe(), license.describe())
end

-- ─── Conditionals ───────────────────────────────────────────────────────────

function TC.MEASURING_ACTIVE()
  local s = measuringStatus()
  return s == "measuring" or s:find("^measuring_local") ~= nil
end

function TC.AGENT_READY()
  return client.displayStatus() == "ready"
end
