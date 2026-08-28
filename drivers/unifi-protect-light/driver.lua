--[[==========================================================================
  UniFi Protect Light — child driver

  One instance per Protect floodlight. Identity/state/events arrive from the
  Gateway; controls travel back as single-shot PROTECT_CONTROL ops. Composer
  programming gets Light On/Off/Mode commands and motion events; Navigator
  presence (a light_v2 proxy) is a documented follow-up, not smuggled in.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "unifi-protect-light.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "unifi-protect-light.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")

local GATEWAY_BINDING = 1
local IDENTITY_PERSIST = "light_identity"
local AUTONAME_PERSIST = "auto_name_last"
local DEFAULT_NAME_PREFIX = "UniFi Protect Light"

local EVENTS = {
  { 1, "Motion Detected", "The floodlight detected motion." },
  { 2, "Light On", "The floodlight turned on." },
  { 3, "Light Off", "The floodlight turned off." },
  { 4, "Light Online", "The floodlight reconnected to the console." },
  { 5, "Light Offline", "The floodlight disconnected from the console." },
}

local VARIABLES = {
  { "LIGHT_ON", "false", "BOOL" },
  { "LIGHT_MODE", "", "STRING" },
  { "LAST_MOTION", "", "STRING" },
}

gInitialized = false
gIdentity = nil
gDeviceState = "UNKNOWN"
gLightOn = nil
gGatewayDeviceId = nil

local function fireEvent(name)
  pcall(function()
    C4:FireEvent(name)
  end)
end

local function setVariable(name, value)
  pcall(function()
    C4:SetVariable(name, tostring(value))
  end)
end

local function findGatewayDeviceId()
  if gGatewayDeviceId ~= nil then
    return gGatewayDeviceId
  end
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok or type(devices) ~= "table" then
    return nil
  end
  for rawId, device in pairs(devices) do
    local id = tonumber(rawId)
    local file = tostring((type(device) == "table" and device.driverFileName) or "")
    if id ~= nil and (file == "unifi-protect.c4z" or file == "unifi-protect.c4i") then
      gGatewayDeviceId = id
      return id
    end
  end
  return nil
end

local function askGateway(command, params)
  SendToProxy(GATEWAY_BINDING, command, params)
  local gatewayId = findGatewayDeviceId()
  if gatewayId ~= nil then
    params = params or {}
    params.requester = tostring(C4:GetDeviceID())
    SendToDevice(gatewayId, command, params)
  end
end

local function requestIdentity()
  UpdateProperty("Gateway Link", "Asked gateway at " .. os.date("%H:%M:%S") .. " - waiting for a reply")
  askGateway("PROTECT_GET_DEVICE", {})
end

local IDENTITY_RETRY_TIMER = "ProtectLightIdentityRetry"
local function armIdentityRetry()
  CancelTimer(IDENTITY_RETRY_TIMER)
  SetTimer(IDENTITY_RETRY_TIMER, 60 * ONE_SECOND, function()
    if gIdentity == nil then
      requestIdentity()
    end
  end, true)
end

local function autoNameDevices(name)
  name = tostring(name or "")
  if name == "" then
    return
  end
  local lastAuto = persist:get(AUTONAME_PERSIST, "")
  local id = C4:GetDeviceID()
  local current = tostring(C4:GetDeviceData(id, "name") or "")
  local isDefault = current:sub(1, #DEFAULT_NAME_PREFIX) == DEFAULT_NAME_PREFIX
  if current ~= name and (isDefault or (lastAuto ~= "" and current == lastAuto)) then
    pcall(function()
      C4:RenameDevice(id, name)
    end)
    persist:set(AUTONAME_PERSIST, name)
  end
end

local function applyLightState(tParams)
  if tParams.on ~= nil then
    local on = tostring(tParams.on) == "true"
    if gLightOn ~= nil and gLightOn ~= on then
      fireEvent(on and "Light On" or "Light Off")
    end
    gLightOn = on
    setVariable("LIGHT_ON", on and "true" or "false")
    UpdateProperty("Light", on and "On" or "Off")
  end
  if tParams.mode ~= nil then
    setVariable("LIGHT_MODE", tParams.mode)
    UpdateProperty("Light Mode", tostring(tParams.mode))
  end
end

local function updateStatusProperties()
  UpdateProperty("Floodlight", gIdentity ~= nil and gIdentity.name or "Not bound")
  UpdateProperty("Light State", gDeviceState)
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
end

function OnDriverLateInit()
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  local cached = persist:get(IDENTITY_PERSIST)
  if type(cached) == "table" and cached.id ~= nil then
    gIdentity = cached
  end
  for _, e in ipairs(EVENTS) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
  for _, v in ipairs(VARIABLES) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end
  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)
  updateStatusProperties()
  requestIdentity()
  armIdentityRetry()
end

function OnDriverDestroyed()
  CancelTimer(IDENTITY_RETRY_TIMER)
end

OBC[GATEWAY_BINDING] = function(_, _, bIsBound)
  if bIsBound then
    requestIdentity()
  else
    gDeviceState = "UNKNOWN"
    updateStatusProperties()
  end
end

function RFP.PROTECT_DEVICE(_, _, tParams)
  tParams = tParams or {}
  gIdentity = { id = tostring(tParams.id or ""), name = tostring(tParams.name or "Floodlight") }
  gDeviceState = tostring(tParams.state or "UNKNOWN")
  persist:set(IDENTITY_PERSIST, gIdentity)
  UpdateProperty("Gateway Link", string.format("OK - identified as '%s' at %s", gIdentity.name, os.date("%H:%M:%S")))
  updateStatusProperties()
  autoNameDevices(gIdentity.name)
  applyLightState(tParams)
end

function RFP.PROTECT_STATE(_, _, tParams)
  tParams = tParams or {}
  if gIdentity == nil then
    requestIdentity()
  end
  local newState = tostring(tParams.state or "UNKNOWN")
  if newState ~= gDeviceState then
    local previous = gDeviceState
    gDeviceState = newState
    if previous ~= "UNKNOWN" then
      fireEvent(newState == "CONNECTED" and "Light Online" or "Light Offline")
    end
  end
  updateStatusProperties()
  applyLightState(tParams)
end

function RFP.PROTECT_EVENT(_, _, tParams)
  tParams = tParams or {}
  if tostring(tParams.kind or "") == "motion" and tostring(tParams.phase or "start") == "start" then
    setVariable("LAST_MOTION", os.date("%Y-%m-%d %H:%M:%S"))
    fireEvent("Motion Detected")
  end
end

function RFP.PROTECT_CONTROL_RESULT(_, _, tParams)
  tParams = tParams or {}
  local op = tostring(tParams.op or "")
  if tostring(tParams.ok or "") == "true" then
    UpdateProperty("Last Control", op .. ": ok " .. os.date("%H:%M:%S"))
  else
    log:warn("Control %s failed: %s", op, tostring(tParams.reason or "unknown"))
    UpdateProperty("Last Control", op .. ": FAILED - " .. tostring(tParams.reason or "unknown"))
  end
end

EC.PROTECT_DEVICE = function(tParams)
  RFP.PROTECT_DEVICE(nil, nil, tParams)
end
EC.PROTECT_STATE = function(tParams)
  RFP.PROTECT_STATE(nil, nil, tParams)
end
EC.PROTECT_EVENT = function(tParams)
  RFP.PROTECT_EVENT(nil, nil, tParams)
end
EC.PROTECT_CONTROL_RESULT = function(tParams)
  RFP.PROTECT_CONTROL_RESULT(nil, nil, tParams)
end

function TC.LIGHT_ONLINE()
  return gDeviceState == "CONNECTED"
end

local function sendControl(op, params)
  params = params or {}
  params.op = op
  UpdateProperty("Last Control", op .. ": sent " .. os.date("%H:%M:%S"))
  askGateway("PROTECT_CONTROL", params)
end

function EC.LIGHT_ON()
  sendControl("light_force", { on = "true" })
end

function EC.LIGHT_OFF()
  sendControl("light_force", { on = "false" })
end

function EC.SET_LIGHT_MODE(tParams)
  sendControl("light_mode", {
    mode = tostring((tParams or {}).Mode or "motion"),
    enable_at = (tParams or {}).EnableAt,
  })
end

EC.Light_On = EC.LIGHT_ON
EC.Light_Off = EC.LIGHT_OFF
EC.Set_Light_Mode = EC.SET_LIGHT_MODE

function EC.REFRESH_LIGHT_INFO()
  requestIdentity()
end

function EC.PRINT_DIAGNOSTICS()
  log:print("== UniFi Protect Light (SBOS) diagnostics ==")
  log:print("  gateway device: %s", tostring(findGatewayDeviceId() or "NOT FOUND"))
  log:print("  identity: %s", gIdentity ~= nil and string.format("'%s' (%s)", gIdentity.name, gIdentity.id) or "none")
  log:print("  state: %s | light: %s", gDeviceState, tostring(gLightOn))
end

function EC.FORGET_LIGHT()
  gIdentity = nil
  gDeviceState = "UNKNOWN"
  gLightOn = nil
  persist:delete(IDENTITY_PERSIST)
  persist:delete(AUTONAME_PERSIST)
  updateStatusProperties()
  requestIdentity()
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
end

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
end
