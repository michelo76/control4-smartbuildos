--[[==========================================================================
  UniFi Protect Sensor — child driver

  One instance per Protect sensor. No credentials, no HTTP: identity, state
  and events arrive from the UniFi Protect Gateway over the binding/device
  protocol, exactly like the camera child. What this driver adds is the
  Control4-native shape of a sensor: CONTACT_SENSOR bindings the Security
  agent can consume, threshold events on temperature and humidity, and
  programming variables for every reading the hardware actually reports.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "unifi-protect-sensor.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "unifi-protect-sensor.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")

local GATEWAY_BINDING = 1
--- Provider CONTACT_SENSOR bindings (static, driver.xml).
local CONTACT_BINDING = 200
local MOTION_BINDING = 201

local IDENTITY_PERSIST = "sensor_identity"
local AUTONAME_PERSIST = "auto_name_last"
local DEFAULT_NAME_PREFIX = "UniFi Protect Sensor"

local EVENTS = {
  { 1, "Motion Detected", "The sensor detected motion." },
  { 2, "Contact Opened", "The sensor's contact opened." },
  { 3, "Contact Closed", "The sensor's contact closed." },
  { 4, "Water Leak Detected", "The sensor detected a water leak." },
  { 5, "Tamper Detected", "The sensor was tampered with." },
  { 6, "Battery Low", "The sensor's battery is low." },
  { 7, "Alarm Detected", "The sensor heard an alarm (smoke, CO, glass break)." },
  { 8, "Button Pressed", "The sensor's button was pressed." },
  { 9, "Temperature Above Threshold", "Temperature crossed above the configured threshold." },
  { 10, "Temperature Below Threshold", "Temperature crossed below the configured threshold." },
  { 11, "Humidity Above Threshold", "Humidity crossed above the configured threshold." },
  { 12, "Humidity Below Threshold", "Humidity crossed below the configured threshold." },
  { 13, "Sensor Online", "The sensor reconnected to the console." },
  { 14, "Sensor Offline", "The sensor disconnected from the console." },
  { 15, "CO Fault", "The sensor reported a carbon monoxide fault." },
}

local VARIABLES = {
  { "CONTACT_STATE", "unknown", "STRING" },
  { "MOTION_DETECTED", "false", "BOOL" },
  { "TEMPERATURE", "", "STRING" },
  { "HUMIDITY", "", "STRING" },
  { "LIGHT_LEVEL", "", "STRING" },
  { "BATTERY", "", "STRING" },
  { "LAST_MOTION", "", "STRING" },
}

gInitialized = false
gIdentity = nil
gDeviceState = "UNKNOWN"
gGatewayDeviceId = nil
--- Which side of each threshold the last reading sat on, so crossings fire
--- exactly once. Keys: temp_high, temp_low, hum_high, hum_low.
gThresholdSide = {}

local function fireEvent(name)
  log:debug("Firing event: %s", name)
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

local IDENTITY_RETRY_TIMER = "ProtectSensorIdentityRetry"
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
    log:info("Renaming device %s: '%s' -> '%s'", id, current, name)
    pcall(function()
      C4:RenameDevice(id, name)
    end)
    persist:set(AUTONAME_PERSIST, name)
  end
end

--- Threshold check for one metric: fires above/below events on CROSSINGS
--- only, judged against the dealer-configured limits. Blank limit = off.
local function checkThreshold(metric, value, highProp, lowProp, aboveEvent, belowEvent)
  local reading = tonumber(value)
  if reading == nil then
    return
  end
  local high = tonumber(Properties[highProp])
  if high ~= nil then
    local side = reading > high and "above" or "belowok"
    if gThresholdSide[metric .. "_high"] ~= nil and gThresholdSide[metric .. "_high"] ~= side and side == "above" then
      log:info("%s above threshold: %s > %s", metric, reading, high)
      fireEvent(aboveEvent)
    end
    gThresholdSide[metric .. "_high"] = side
  end
  local low = tonumber(Properties[lowProp])
  if low ~= nil then
    local side = reading < low and "below" or "aboveok"
    if gThresholdSide[metric .. "_low"] ~= nil and gThresholdSide[metric .. "_low"] ~= side and side == "below" then
      log:info("%s below threshold: %s < %s", metric, reading, low)
      fireEvent(belowEvent)
    end
    gThresholdSide[metric .. "_low"] = side
  end
end

--- Applies a state push or identity reply's readings.
local function applyReadings(tParams)
  if tParams.temperature ~= nil then
    setVariable("TEMPERATURE", tParams.temperature)
    UpdateProperty("Temperature", tostring(tParams.temperature))
    checkThreshold(
      "temp",
      tParams.temperature,
      "Temperature High Threshold",
      "Temperature Low Threshold",
      "Temperature Above Threshold",
      "Temperature Below Threshold"
    )
  end
  if tParams.humidity ~= nil then
    setVariable("HUMIDITY", tParams.humidity)
    UpdateProperty("Humidity", tostring(tParams.humidity))
    checkThreshold(
      "hum",
      tParams.humidity,
      "Humidity High Threshold",
      "Humidity Low Threshold",
      "Humidity Above Threshold",
      "Humidity Below Threshold"
    )
  end
  if tParams.light ~= nil then
    setVariable("LIGHT_LEVEL", tParams.light)
    UpdateProperty("Light Level", tostring(tParams.light))
  end
  if tParams.battery ~= nil then
    setVariable("BATTERY", tParams.battery)
    UpdateProperty("Battery", tostring(tParams.battery) .. "%")
  end
  if tParams.opened ~= nil then
    local opened = tostring(tParams.opened) == "true"
    setVariable("CONTACT_STATE", opened and "open" or "closed")
    UpdateProperty("Contact", opened and "Open" or "Closed")
    SendToProxy(CONTACT_BINDING, opened and "OPENED" or "CLOSED", {})
  end
end

local function updateStatusProperties()
  UpdateProperty("Sensor", gIdentity ~= nil and gIdentity.name or "Not bound")
  UpdateProperty("Sensor State", gDeviceState)
  UpdateProperty("Mount Type", gIdentity ~= nil and (gIdentity.mount or "-") or "-")
end

-- ─── Lifecycle ────────────────────────────────────────────────────────────────

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

-- ─── Gateway protocol ─────────────────────────────────────────────────────────

function RFP.PROTECT_DEVICE(_, _, tParams)
  tParams = tParams or {}
  gIdentity = {
    id = tostring(tParams.id or ""),
    name = tostring(tParams.name or "Sensor"),
    mount = tostring(tParams.mount or "none"),
  }
  gDeviceState = tostring(tParams.state or "UNKNOWN")
  persist:set(IDENTITY_PERSIST, gIdentity)
  UpdateProperty("Gateway Link", string.format("OK - identified as '%s' at %s", gIdentity.name, os.date("%H:%M:%S")))
  updateStatusProperties()
  autoNameDevices(gIdentity.name)
  applyReadings(tParams)
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
      if newState == "CONNECTED" then
        fireEvent("Sensor Online")
      elseif newState == "DISCONNECTED" then
        fireEvent("Sensor Offline")
      end
    end
  end
  updateStatusProperties()
  applyReadings(tParams)
end

--- Normalized sensor events from the Gateway: kind = motion|opened|closed|
--- alarm|extreme|battery|leak|tamper|button|cofault|smoketest.
function RFP.PROTECT_EVENT(_, _, tParams)
  tParams = tParams or {}
  local kind = tostring(tParams.kind or "")
  local phase = tostring(tParams.phase or "start")
  local now = os.date("%Y-%m-%d %H:%M:%S")

  if kind == "motion" then
    if phase == "start" then
      setVariable("MOTION_DETECTED", "true")
      setVariable("LAST_MOTION", now)
      SendToProxy(MOTION_BINDING, "CLOSED", {})
      fireEvent("Motion Detected")
    else
      setVariable("MOTION_DETECTED", "false")
      SendToProxy(MOTION_BINDING, "OPENED", {})
    end
  elseif kind == "opened" then
    setVariable("CONTACT_STATE", "open")
    UpdateProperty("Contact", "Open")
    SendToProxy(CONTACT_BINDING, "OPENED", {})
    fireEvent("Contact Opened")
  elseif kind == "closed" then
    setVariable("CONTACT_STATE", "closed")
    UpdateProperty("Contact", "Closed")
    SendToProxy(CONTACT_BINDING, "CLOSED", {})
    fireEvent("Contact Closed")
  elseif kind == "leak" and phase == "start" then
    fireEvent("Water Leak Detected")
  elseif kind == "tamper" and phase == "start" then
    fireEvent("Tamper Detected")
  elseif kind == "battery" then
    fireEvent("Battery Low")
  elseif kind == "alarm" and phase == "start" then
    fireEvent("Alarm Detected")
  elseif kind == "button" then
    fireEvent("Button Pressed")
  elseif kind == "cofault" then
    fireEvent("CO Fault")
  elseif kind == "extreme" then
    -- Extreme-value events carry which metric and its reading.
    local metric = tostring(tParams.sensor_type or "")
    local value = tParams.sensor_value
    if metric == "temperature" then
      applyReadings({ temperature = value })
    elseif metric == "humidity" then
      applyReadings({ humidity = value })
    elseif metric == "light" then
      applyReadings({ light = value })
    end
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

-- ─── Conditionals / actions / properties ──────────────────────────────────────

function TC.SENSOR_ONLINE()
  return gDeviceState == "CONNECTED"
end

function EC.REFRESH_SENSOR_INFO()
  requestIdentity()
end

function EC.PRINT_DIAGNOSTICS()
  log:print("== UniFi Protect Sensor (SBOS) diagnostics ==")
  log:print("  driver version: %s", tostring(C4.GetDriverConfigInfo and C4:GetDriverConfigInfo("version") or "?"))
  log:print("  device id: %s", tostring(C4:GetDeviceID()))
  log:print("  gateway device: %s", tostring(findGatewayDeviceId() or "NOT FOUND"))
  log:print("  identity: %s", gIdentity ~= nil and string.format("'%s' (%s)", gIdentity.name, gIdentity.id) or "none")
  log:print("  state: %s", gDeviceState)
  log:print("  gateway link: %s", tostring(Properties["Gateway Link"]))
end

function EC.FORGET_SENSOR()
  gIdentity = nil
  gDeviceState = "UNKNOWN"
  persist:delete(IDENTITY_PERSIST)
  persist:delete(AUTONAME_PERSIST)
  updateStatusProperties()
  requestIdentity()
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    return
  end
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    UpdateProperty("Log Mode", "Off", true)
  end)
end

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
end
