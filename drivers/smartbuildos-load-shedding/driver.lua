--[[==========================================================================
  SmartBuildOS Load Shedding
  Sheds heavy loads in three priority tiers when the grid drops or the
  battery runs low, and restores them in order once power has held. The
  outage and the battery level come from any contact sensor or variable in
  the project, or from the Set Outage / Set Battery commands. Vendor neutral.

  Licensing: the SmartBuildOS Agent is the authority (SKU SBOS_LOAD_SHEDDING
  through sbos.license). A definitive denial with enforcement on makes the
  driver READ-ONLY, and FIRST restores anything it had shed: a licence halt
  never leaves a load off.

  History: outage start, each tier shed, restore and restore-delay are sent
  to the Flight Recorder (RECORD_EVENT) when one is in the project. No
  private long-term log is kept here.

  Pure rules: src/loadshed/engine.lua (tested without a controller).
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-load-shedding.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-load-shedding.c4z" }
--#endif

-- Every require at module scope (the build's squish step finds modules by
-- loading this file under the test shim).
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local Engine = require("loadshed.engine")

gInitialized = false

local SKU = "SBOS_LOAD_SHEDDING"
local STATE_KEY = "ls_state_v1"
local SOURCES_KEY = "ls_sources_v1"
local PERSIST_TIMER = "LsPersist"
local STATUS_TIMER = "LsStatusPaint"
local POLL_TIMER = "LsInputPoll"
local SLOTS = 12
local FR_FILE = "smartbuildos-flight-recorder.c4z"

local EVENT_OUTAGE, EVENT_TIER, EVENT_RESTORED, EVENT_DELAYED = 1, 2, 3, 4
local EVENT_RESHED, EVENT_FAILED, EVENT_READONLY, EVENT_ACTIVE = 5, 6, 7, 8

local gEngine = nil
local gHalted = false
local gLastEvent = "none yet"
local gSources = { outage = nil, battery = nil } -- resolved {device_id, var_id, var_name, when}
local gOverride = { outage = nil, battery = nil } -- picked in programming, persisted
local gLastRaw = { outage = nil, battery = nil }
local gWatch = {} -- ["dev:var"] = { role = "outage"|"battery"|"load", slot = n }
local gFrId = nil
local gFrCheckedAt = -1000

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

local function nowSeconds()
  return os.time()
end

-- ─── Devices and variables ──────────────────────────────────────────────────

local function allDevices()
  local ok, d = pcall(function()
    return C4:GetDevices({})
  end)
  if ok and type(d) == "table" then
    return d
  end
  return {}
end

local function deviceVars(deviceId)
  local ok, raw = pcall(function()
    return C4:GetDeviceVariables(deviceId)
  end)
  if ok and type(raw) == "table" then
    return raw
  end
  return {}
end

--- name -> value for one device.
local function varsByName(deviceId)
  local out = {}
  for _, v in pairs(deviceVars(deviceId)) do
    if type(v) == "table" and v.name ~= nil then
      out[v.name] = v.value
    end
  end
  return out
end

local function findVarId(deviceId, name)
  for k, v in pairs(deviceVars(deviceId)) do
    if type(v) == "table" and v.name == name then
      return tonumber(k) or tonumber(v.id)
    end
  end
  return nil
end

local function readVar(deviceId, varId)
  local vars = deviceVars(deviceId)
  local v = vars[varId] or vars[tostring(varId)]
  if type(v) == "table" then
    return v.value
  end
  return nil
end

local function cleanName(s)
  return (tostring(s or ""):gsub(",", " "):gsub("·", "-"):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The drop-down text: "Name (Room) · id".
local function refreshLists()
  local labels = {}
  for rawId, d in pairs(allDevices()) do
    local id = tonumber(rawId)
    if id and id ~= C4:GetDeviceID() and type(d) == "table" and d.deviceName and d.deviceName ~= "" then
      local room = d.roomName and d.roomName ~= "" and (" (" .. cleanName(d.roomName) .. ")") or ""
      labels[#labels + 1] = string.format("%s%s · %d", cleanName(d.deviceName), room, id)
    end
    if #labels >= 400 then
      break
    end
  end
  table.sort(labels)
  local joined = #labels > 0 and ("-," .. table.concat(labels, ",")) or "-"
  local names = { "Outage Device", "Battery Device" }
  for n = 1, SLOTS do
    names[#names + 1] = "Load " .. n .. " Device"
  end
  for _, p in ipairs(names) do
    pcall(function()
      C4:UpdatePropertyList(p, joined, Properties[p] or "-")
    end)
  end
end

-- ─── Flight Recorder ────────────────────────────────────────────────────────

local function flightRecorderId()
  if gFrId ~= nil then
    return gFrId
  end
  local t = nowSeconds()
  if t - gFrCheckedAt < 300 then
    return nil
  end
  gFrCheckedAt = t
  for rawId, d in pairs(allDevices()) do
    if type(d) == "table" and d.driverFileName == FR_FILE then
      gFrId = tonumber(rawId)
      return gFrId
    end
  end
  return nil
end

--- One marker in the common history. Quiet when there is no recorder.
local function record(name, detail)
  if Properties["Record To Flight Recorder"] == "No" then
    return
  end
  local id = flightRecorderId()
  if id == nil then
    return
  end
  pcall(function()
    C4:SendToDevice(id, "RECORD_EVENT", { NAME = name, DETAIL = detail or "", CHANNEL = "load-shedding" })
  end)
end

-- ─── Persistence ────────────────────────────────────────────────────────────

local function save()
  if gEngine == nil then
    return
  end
  persist:set(STATE_KEY, gEngine:serialize())
end

local function saveSoon()
  SetTimer(PERSIST_TIMER, 2 * ONE_SECOND, save)
end

local function saveSources()
  persist:set(SOURCES_KEY, {
    outage = gOverride.outage,
    battery = gOverride.battery,
  })
end

-- ─── Status ─────────────────────────────────────────────────────────────────

local function statusText()
  if gEngine == nil then
    return "starting"
  end
  if gHalted then
    return "read-only (licence)"
  end
  return gEngine:phaseLabel()
end

local function summaryLine()
  if gEngine == nil then
    return "nothing shed"
  end
  local snap = gEngine:snapshot()
  local tiers = {}
  for t = 1, 3 do
    if gEngine:isTierShed(t) then
      tiers[#tiers + 1] = tostring(t)
    end
  end
  local batt = snap.battery and string.format("%d%%", math.floor(snap.battery + 0.5)) or "unknown"
  return string.format(
    "%d load(s) shed, tiers shed: %s, battery: %s",
    gEngine:shedCount(),
    #tiers > 0 and table.concat(tiers, ",") or "none",
    batt
  )
end

local function paint()
  if gEngine == nil then
    return
  end
  local status = statusText()
  UpdateProperty("Shed Status", status)
  UpdateProperty("Summary", summaryLine())
  UpdateProperty("Last Event", gLastEvent)
  setVar("LS_STATUS", status)
  setVar("OUTAGE_STATE", gEngine:phaseLabel())
  setVar("OUTAGE_ACTIVE", gEngine:outageActive() and "True" or "False")
  setVar("TIER_SHED", gEngine:highestShedTier())
  setVar("LOADS_SHED", gEngine:shedCount())
  local b = gEngine.st.battery
  setVar("BATTERY_PERCENT", b and math.floor(b + 0.5) or -1)
end

local function stamp(text)
  gLastEvent = string.format("%s (%s)", text, os.date("%H:%M:%S"))
end

local function refused(what, why)
  UpdateProperty("Last Refusal", string.format("%s: %s (%s)", what, tostring(why), os.date("%H:%M:%S")))
  log:warn("%s refused: %s", what, tostring(why))
end

-- ─── Engine events -> Composer + Flight Recorder ───────────────────────────

local function onEngineEvent(kind, f)
  if kind == "changed" then
    saveSoon()
    paint()
    return
  end
  if kind == "outage_started" then
    stamp("outage started")
    record("Outage started", "source: " .. tostring(f.source))
    fire(EVENT_OUTAGE)
  elseif kind == "tier_shed" then
    setVar("LAST_TIER_SHED", f.tier)
    stamp(string.format("tier %d shed (%d load(s), %s)", f.tier, f.count, tostring(f.reason)))
    record(string.format("Tier %d shed", f.tier), string.format("%d load(s); reason: %s", f.count, tostring(f.reason)))
    fire(EVENT_TIER)
  elseif kind == "tier_restored" then
    stamp(string.format("tier %d restored", f.tier))
    record(string.format("Tier %d restored", f.tier), string.format("%d load(s)", f.count))
  elseif kind == "restored" then
    stamp("restored, outage lasted " .. tostring(f.duration_s) .. " s")
    record("Outage ended, all loads restored", "outage lasted " .. tostring(f.duration_s) .. " s")
    fire(EVENT_RESTORED)
  elseif kind == "restore_delayed" then
    stamp("power back, holding " .. tostring(f.hold_s) .. " s")
    record("Power back, restore delayed", "hold " .. tostring(f.hold_s) .. " s")
    fire(EVENT_DELAYED)
  elseif kind == "flap" then
    stamp("grid dropped again before the hold ended")
    record("Grid flapped", "flap " .. tostring(f.flaps))
    fire(EVENT_DELAYED)
  elseif kind == "reshed" then
    stamp("load " .. tostring(f.slot) .. " re-shed")
    record("Load re-shed", "slot " .. tostring(f.slot) .. ", time " .. tostring(f.count))
    fire(EVENT_RESHED)
  elseif kind == "load_error" then
    stamp(string.format("load %s: %s failed", tostring(f.slot), tostring(f.action)))
    log:warn("load %s %s (%s) could not be sent", tostring(f.slot), tostring(f.action), tostring(f.command))
    fire(EVENT_FAILED)
  elseif kind == "load_shed" and f.skipped then
    log:info("load %s left alone: %s", tostring(f.slot), tostring(f.skipped))
  end
end

-- ─── Loads, sources and configuration ──────────────────────────────────────

local function number(name, default)
  local v = tonumber(Properties[name])
  if v == nil then
    return default
  end
  return v
end

local KINDS = { Light = "light", Relay = "relay", ["Thermostat setback"] = "thermostat" }

local function buildConfig()
  return {
    tier2_pct = number("Tier 2 Battery Percent", 50),
    tier3_pct = number("Tier 3 Battery Percent", 20),
    tier2_nodata_min = number("Tier 2 No Data Minutes", 15),
    tier3_nodata_min = number("Tier 3 No Data Minutes", 45),
    stable_hold_s = number("Stable Hold Seconds", 120),
    tier_delay_s = number("Tier Delay Seconds", 30),
    reshed = Properties["Re-shed Loads Turned On"] == "Yes",
  }
end

local function buildLoads()
  local list = {}
  for n = 1, SLOTS do
    local kind = KINDS[Properties["Load " .. n .. " Kind"] or ""]
    local label = Properties["Load " .. n .. " Device"] or "-"
    local id = Engine.parseDeviceId(label)
    if kind and id then
      list[#list + 1] = {
        slot = n,
        device_id = id,
        kind = kind,
        tier = tonumber(Properties["Load " .. n .. " Tier"]),
        setback_f = tonumber(Properties["Load " .. n .. " Setback F"]),
        name = (label:gsub("%s*·.*$", "")),
      }
    end
  end
  return list
end

local function applyConfig()
  if gEngine == nil then
    return
  end
  gEngine:setConfig(buildConfig())
  local problems = gEngine:setLoads(buildLoads())
  for _, p in ipairs(problems) do
    log:warn("Load %s not used: %s", tostring(p.slot), tostring(p.why))
  end
end

local function unwatchAll()
  for key in pairs(gWatch) do
    local d, v = key:match("^(%d+):(%d+)$")
    pcall(function()
      C4:UnregisterVariableListener(tonumber(d), tonumber(v))
    end)
  end
  gWatch = {}
end

--- Makes the registered listeners match `wanted` ([key] = entry): registers
--- new ones, drops stale ones, leaves the rest alone.
local function syncWatch(wanted)
  for key in pairs(gWatch) do
    if wanted[key] == nil then
      local d, v = key:match("^(%d+):(%d+)$")
      pcall(function()
        C4:UnregisterVariableListener(tonumber(d), tonumber(v))
      end)
      gWatch[key] = nil
    end
  end
  for key, entry in pairs(wanted) do
    if gWatch[key] == nil then
      local d, v = key:match("^(%d+):(%d+)$")
      local ok = pcall(function()
        C4:RegisterVariableListener(tonumber(d), tonumber(v))
      end)
      if ok then
        gWatch[key] = entry
      end
    else
      gWatch[key] = entry
    end
  end
end

--- The variable names whose change tells us a load was switched on.
local FEEDBACK = { light = { "LIGHT_STATE", "Brightness Percent" }, relay = { "STATE", "RELAY_STATE" } }

local function resolveSources()
  gSources = { outage = nil, battery = nil }
  local o = gOverride.outage
  if o then
    gSources.outage = { device_id = o.device_id, var_id = o.var_id, when = o.when }
  else
    local id = Engine.parseDeviceId(Properties["Outage Device"])
    local name = Properties["Outage Variable"] or ""
    if id and name ~= "" then
      gSources.outage = {
        device_id = id,
        var_name = name,
        var_id = findVarId(id, name),
        when = Properties["Outage When Value Is"] or "",
      }
    end
  end
  local b = gOverride.battery
  if b then
    gSources.battery = { device_id = b.device_id, var_id = b.var_id }
  else
    local id = Engine.parseDeviceId(Properties["Battery Device"])
    local name = Properties["Battery Variable"] or ""
    if id and name ~= "" then
      gSources.battery = { device_id = id, var_name = name, var_id = findVarId(id, name) }
    end
  end
  local wanted = {}
  for role, src in pairs(gSources) do
    if src.var_id == nil and src.var_name then
      src.var_id = findVarId(src.device_id, src.var_name)
    end
    if src.var_id then
      wanted[src.device_id .. ":" .. src.var_id] = { role = role }
    end
  end
  if gEngine and gEngine.cfg.reshed then
    for _, l in ipairs(gEngine.loads) do
      for _, name in ipairs(FEEDBACK[l.kind] or {}) do
        local vid = findVarId(l.device_id, name)
        if vid then
          wanted[l.device_id .. ":" .. vid] = { role = "load", slot = l.slot, var = name }
        end
      end
    end
  end
  syncWatch(wanted)
end

--- Applies the current outage / battery inputs. Only a CHANGED raw value acts,
--- so a Set Outage command is not undone by the next poll.
local function applyInputs(force)
  if gEngine == nil then
    return
  end
  local o = gSources.outage
  if o and o.var_id then
    local raw = readVar(o.device_id, o.var_id)
    if raw ~= nil and (force or raw ~= gLastRaw.outage) then
      gLastRaw.outage = raw
      local ok, why = gEngine:setOutage(Engine.valueMatches(raw, o.when), "input")
      if not ok then
        log:warn("outage input ignored: %s", tostring(why))
      end
    end
  end
  local b = gSources.battery
  if b and b.var_id then
    local raw = readVar(b.device_id, b.var_id)
    if raw ~= nil and tonumber(raw) ~= nil and (force or raw ~= gLastRaw.battery) then
      gLastRaw.battery = raw
      gEngine:setBattery(tonumber(raw))
    end
  end
end

local function rebuildAll()
  applyConfig()
  resolveSources()
  paint()
end

-- ─── Licence ────────────────────────────────────────────────────────────────

local function reconcileLicence()
  if gEngine == nil then
    return
  end
  local halt = license.enforces()
  if halt and not gHalted then
    gHalted = true
    -- Restore first, then read-only: the engine does both in this order.
    gEngine:setReadOnly(true)
    log:warn("SmartBuildOS licence: %s - Load Shedding restored every load and is read-only", tostring(license.statusLabel()))
    fire(EVENT_READONLY)
  elseif not halt and gHalted then
    gHalted = false
    gEngine:setReadOnly(false)
    fire(EVENT_ACTIVE)
    applyInputs(true)
  end
  paint()
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerComposerSurface()
  local vars = {
    { "OUTAGE_STATE", "Normal", "STRING" },
    { "OUTAGE_ACTIVE", "False", "STRING" },
    { "TIER_SHED", 0, "NUMBER" },
    { "LAST_TIER_SHED", 0, "NUMBER" },
    { "BATTERY_PERCENT", -1, "NUMBER" },
    { "LOADS_SHED", 0, "NUMBER" },
    { "LS_STATUS", "starting", "STRING" },
  }
  for _, v in ipairs(vars) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { 1, "Outage Started", "The grid dropped; tier 1 is shedding" },
    { 2, "Tier Shed", "A tier was shed (LAST_TIER_SHED says which)" },
    { 3, "Restored", "Every shed load is back" },
    { 4, "Restore Delayed", "Power is back; loads wait for it to hold" },
    { 5, "Load Re-shed", "A shed load was switched on and shed again" },
    { 6, "Load Control Failed", "A shed or restore command could not be sent" },
    { 7, "Load Shedding Read-Only", "The licence halted this driver" },
    { 8, "Load Shedding Active", "Active again after a read-only period" },
  }) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName("LoadShedding")
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

  gEngine = Engine.new({
    now = nowSeconds,
    schedule = function(id, ms, fn)
      SetTimer(id, ms, fn)
    end,
    cancel = function(id)
      CancelTimer(id)
    end,
    emit = onEngineEvent,
    read = function(load)
      return Engine.readerFor(load.kind)(varsByName(load.device_id))
    end,
    send = function(deviceId, command, params)
      local ok = pcall(function()
        C4:SendToDevice(deviceId, command, params or {})
      end)
      return ok
    end,
  })
  applyConfig()

  local stored = persist:get(STATE_KEY, false)
  if type(stored) == "table" then
    local ok, res, err = pcall(function()
      return gEngine:restore(stored)
    end)
    if not ok or res == false then
      log:error("Persisted state unreadable (%s); starting empty", tostring(ok and err or res))
    end
  end
  local so = persist:get(SOURCES_KEY, false)
  if type(so) == "table" then
    gOverride.outage = type(so.outage) == "table" and so.outage or nil
    gOverride.battery = type(so.battery) == "table" and so.battery or nil
  end

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    reconcileLicence()
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)
  refreshLists()
  resolveSources()
  -- The saved state says where the outage was; the input says where it is now.
  applyInputs(true)
  SetTimer(STATUS_TIMER, 60 * ONE_SECOND, paint, true)
  SetTimer(POLL_TIMER, 60 * ONE_SECOND, function()
    resolveSources()
    applyInputs(false)
  end, true)
  paint()
end

function OnDriverDestroyed()
  pcall(license.stop)
  if gEngine then
    save()
    gEngine:stop()
  end
  unwatchAll()
  CancelTimer(PERSIST_TIMER)
  CancelTimer(STATUS_TIMER)
  CancelTimer(POLL_TIMER)
end

--- Director's callback for every watched variable.
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  if gEngine == nil then
    return
  end
  local entry = gWatch[tostring(tointeger(idDevice)) .. ":" .. tostring(tointeger(idVariable))]
  if entry == nil then
    return
  end
  if entry.role == "outage" then
    gLastRaw.outage = strValue
    gEngine:setOutage(Engine.valueMatches(strValue, gSources.outage and gSources.outage.when), "input")
  elseif entry.role == "battery" then
    if tonumber(strValue) ~= nil then
      gLastRaw.battery = strValue
      gEngine:setBattery(tonumber(strValue))
    end
  elseif entry.role == "load" then
    local on
    if entry.var == "Brightness Percent" then
      on = (tonumber(strValue) or 0) > 0
    else
      local s = tostring(strValue):lower()
      on = s == "1" or s == "true" or s == "on" or s == "closed"
    end
    gEngine:observe(entry.slot, on)
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

local function onSetupChanged()
  if gInitialized then
    rebuildAll()
  end
end

--- Picking an input in the property list replaces one picked in programming.
local function onInputChanged(role)
  return function()
    if gInitialized then
      gOverride[role] = nil
      gLastRaw[role] = nil
      saveSources()
      rebuildAll()
      if role == "battery" and gSources.battery == nil then
        gEngine:clearBattery()
      end
      applyInputs(true)
    end
  end
end

local function opcKey(name)
  return (name:gsub("%W", "_"):gsub("[_]+", "_"):gsub("^_", ""):gsub("_$", ""))
end

for _, p in ipairs({
  "Tier 2 Battery Percent",
  "Tier 3 Battery Percent",
  "Tier 2 No Data Minutes",
  "Tier 3 No Data Minutes",
  "Stable Hold Seconds",
  "Tier Delay Seconds",
  "Re-shed Loads Turned On",
}) do
  OPC[opcKey(p)] = onSetupChanged
end
for _, p in ipairs({ "Outage Device", "Outage Variable", "Outage When Value Is" }) do
  OPC[opcKey(p)] = onInputChanged("outage")
end
for _, p in ipairs({ "Battery Device", "Battery Variable" }) do
  OPC[opcKey(p)] = onInputChanged("battery")
end
for n = 1, SLOTS do
  for _, f in ipairs({ "Device", "Kind", "Tier", "Setback F" }) do
    OPC[opcKey("Load " .. n .. " " .. f)] = onSetupChanged
  end
end

-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.REGISTER_NOW()
  license.register()
end

function EC.REFRESH_STATUS()
  paint()
end

function EC.REFRESH_LISTS()
  refreshLists()
end

function EC.PRINT_STATUS()
  if gEngine == nil then
    return
  end
  local snap = gEngine:snapshot()
  log:print("== Load Shedding ==")
  log:print("  status: %s", statusText())
  log:print("  licence: %s", license.describe())
  log:print("  %s", summaryLine())
  if snap.outage_since then
    log:print("  outage since %s", os.date("%H:%M:%S", math.floor(snap.outage_since)))
  end
  log:print("  flaps this outage: %d", snap.flaps)
  for _, l in ipairs(gEngine.loads) do
    local state = "not shed"
    for _, s in ipairs(snap.shed) do
      if s.slot == l.slot then
        state = s.skip and ("left alone: " .. s.skip) or "shed"
      end
    end
    log:print("  load %d: device %d, %s, tier %d: %s", l.slot, l.device_id, l.kind, l.tier, state)
  end
end

local function guarded(what, fn)
  if gEngine == nil then
    return false
  end
  local ok, why = fn()
  if not ok then
    refused(what, why)
  end
  paint()
  return ok
end

function EC.TEST_MODE()
  if gEngine == nil then
    return
  end
  local lines = gEngine:dryRun()
  log:print("== Load Shedding test mode (nothing sent) ==")
  for _, l in ipairs(lines) do
    log:print("  %s", l.text)
  end
  if #lines == 0 then
    log:print("  no loads are set up")
  end
  UpdateProperty("Last Test Result", string.format("%d step(s) listed (%s)", #lines, os.date("%H:%M:%S")))
end

function EC.RESTORE_ALL()
  guarded("Restore All", function()
    return gEngine:restoreAll()
  end)
end

-- ─── Composer programming commands ─────────────────────────────────────────

function EC.SHED_TIER(t)
  t = t or {}
  guarded("Shed Tier", function()
    return gEngine:shedTierNow(t.TIER)
  end)
end

function EC.SET_OUTAGE(t)
  t = t or {}
  local on = tostring(t.STATE or ""):lower()
  if on ~= "on" and on ~= "off" then
    refused("Set Outage", "STATE must be On or Off")
    return
  end
  guarded("Set Outage", function()
    return gEngine:setOutage(on == "on", "command")
  end)
end

function EC.SET_BATTERY(t)
  t = t or {}
  guarded("Set Battery", function()
    return gEngine:setBattery(t.PERCENT)
  end)
end

local function pickVariable(role, t, withWhen)
  local d, v = Engine.parseVariablePick(t.VARIABLE)
  if d == nil then
    refused("Watch " .. role .. " variable", "no variable picked")
    return
  end
  gOverride[role] = { device_id = d, var_id = v, when = withWhen and tostring(t.WHEN or "") or nil }
  gLastRaw[role] = nil
  saveSources()
  resolveSources()
  applyInputs(true)
  paint()
end

function EC.WATCH_OUTAGE_VARIABLE(t)
  t = t or {}
  if tostring(t.WHEN or "") == "" then
    refused("Watch outage variable", "WHEN is empty (for example 1,closed)")
    return
  end
  pickVariable("outage", t, true)
end

function EC.WATCH_BATTERY_VARIABLE(t)
  pickVariable("battery", t or {}, false)
end

-- ─── Conditionals (TestCondition name, tParams) ────────────────────────────

local function tierShed(n)
  return gEngine ~= nil and gEngine:isTierShed(n)
end

function TC.OUTAGE_ACTIVE()
  return gEngine ~= nil and gEngine:outageActive()
end

function TC.TIER_1_SHED()
  return tierShed(1)
end

function TC.TIER_2_SHED()
  return tierShed(2)
end

function TC.TIER_3_SHED()
  return tierShed(3)
end

function TC.LS_ACTIVE()
  return gInitialized and not gHalted
end
