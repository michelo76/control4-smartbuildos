--[[==========================================================================
  Bond Weather — child driver for Breeze weather sensors

  One instance per Bond Breeze (BWS-1000 and friends). Measurements arrive
  from the Bond Bridge Gateway — a full document on every sync, and pushed
  the moment the Bond hears a new reading. Everything the sensor knows
  becomes Control4 material:

    - VALUE connections: an Outdoor Temperature (TEMPERATURE_VALUE) and an
      Outdoor Humidity (HUMIDITY_VALUE) provider — bind them to any
      thermostat and the Breeze becomes the project's outdoor sensor.
    - Variables for programming: TEMPERATURE_C/F, HUMIDITY, WIND_SPEED_MS,
      RAIN_RATE_MMH, SUN_LEVEL, IS_RAINING, SOLAR_BATTERY, BACKUP_BATTERY,
      NO_DATA.
    - Transition events: rain start/stop, wind/sun trigger, both batteries
      low/OK, freeze warning, data lost/restored. Transitions only — a
      sensor reporting every few seconds must not spam programming.

  Unit conventions (the Bond wire format is integer-scaled):
    data_temperature_dc  deci-Celsius   -> °C /10
    data_wind_speed_dms  decimeter/s    -> m/s /10
    battery_voltage_dV   decivolts      -> V  /10
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "bond-weather.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "bond-weather.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local child = require("bond.child")

local TEMPERATURE_BINDING = 100
local HUMIDITY_BINDING = 101
local DEFAULT_NAME_PREFIX = "Bond Weather"

local EVENTS = {
  { 1, "Rain Started", "It started raining." },
  { 2, "Rain Stopped", "It stopped raining." },
  { 3, "Wind Triggered", "Wind reached the configured trigger level." },
  { 4, "Sun Triggered", "Sun intensity reached the configured trigger level." },
  { 5, "Solar Battery Low", "The solar battery is running low." },
  { 6, "Solar Battery OK", "The solar battery recovered." },
  { 7, "Backup Battery Low", "The backup AA battery is running low." },
  { 8, "Backup Battery OK", "The backup AA battery recovered." },
  { 9, "Freeze Warning", "Sensor temperature is low - external 12V supply recommended." },
  { 10, "Freeze Warning Cleared", "Sensor temperature recovered." },
  { 11, "Data Lost", "No measurements for more than 30 minutes." },
  { 12, "Data Restored", "Measurements are flowing again." },
}

local VARIABLES = {
  { "TEMPERATURE_C", "0", "NUMBER" },
  { "TEMPERATURE_F", "0", "NUMBER" },
  { "HUMIDITY", "0", "NUMBER" },
  { "WIND_SPEED_MS", "0", "NUMBER" },
  { "RAIN_RATE_MMH", "0", "NUMBER" },
  { "SUN_LEVEL", "0", "NUMBER" },
  { "IS_RAINING", "false", "BOOL" },
  { "SOLAR_BATTERY", "0", "NUMBER" },
  { "BACKUP_BATTERY", "0", "NUMBER" },
  { "NO_DATA", "false", "BOOL" },
}

--- Boolean flags that fire paired transition events: state key ->
--- { asserted event, cleared event }.
local FLAG_EVENTS = {
  is_raining = { "Rain Started", "Rain Stopped" },
  status_flag_battery_low = { "Solar Battery Low", "Solar Battery OK" },
  status_flag_battery_2_low = { "Backup Battery Low", "Backup Battery OK" },
  status_flag_low_temperature = { "Freeze Warning", "Freeze Warning Cleared" },
  status_flag_no_data = { "Data Lost", "Data Restored" },
}

--- `status` values that fire a trigger event when entered.
local STATUS_EVENTS = {
  triggered_wind = "Wind Triggered",
  triggered_wind_manual = "Wind Triggered",
  triggered_rain = nil, -- is_raining already covers rain
  triggered_sun_high = "Sun Triggered",
}

gInitialized = false
--- Last-seen flags/status for transition detection.
gFlags = {}
gStatus = nil
gTempC = nil
gHumidity = nil

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

--- One decimal, as a number-ish string (Lua %.1f keeps trailing zero off
--- Composer displays consistent).
local function one(n)
  return string.format("%.1f", n)
end

--- Sends current temperature/humidity out the VALUE connections. NO_DATA
--- sends VALUE_UNAVAILABLE instead — a thermostat holding a stale outdoor
--- reading is worse than one showing none.
local function publishValues(timestamp)
  if gFlags.status_flag_no_data then
    SendToProxy(TEMPERATURE_BINDING, "VALUE_UNAVAILABLE", { STATUS = "offline" }, "NOTIFY")
    SendToProxy(HUMIDITY_BINDING, "VALUE_UNAVAILABLE", { STATUS = "offline" }, "NOTIFY")
    return
  end
  timestamp = timestamp or os.time()
  if gTempC ~= nil then
    SendToProxy(TEMPERATURE_BINDING, "VALUE_CHANGED", {
      CELSIUS = one(gTempC),
      FAHRENHEIT = one(gTempC * 9 / 5 + 32),
      TIMESTAMP = timestamp,
    }, "NOTIFY")
  end
  if gHumidity ~= nil then
    SendToProxy(HUMIDITY_BINDING, "VALUE_CHANGED", { VALUE = gHumidity, TIMESTAMP = timestamp }, "NOTIFY")
  end
end

--- Applies a Breeze state document.
local function applyState(state)
  -- Measurements.
  local tempDc = tonumber(state.data_temperature_dc)
  if tempDc ~= nil then
    gTempC = tempDc / 10
    local f = gTempC * 9 / 5 + 32
    setVariable("TEMPERATURE_C", one(gTempC))
    setVariable("TEMPERATURE_F", one(f))
    if tostring(Properties["Display Units"] or "Fahrenheit") == "Celsius" then
      UpdateProperty("Temperature", one(gTempC) .. " C")
    else
      UpdateProperty("Temperature", one(f) .. " F")
    end
  end
  local humidity = tonumber(state.data_humidity_percent)
  if humidity ~= nil then
    gHumidity = humidity
    setVariable("HUMIDITY", humidity)
    UpdateProperty("Humidity", humidity .. "%")
  end
  local windDms = tonumber(state.data_wind_speed_dms)
  if windDms ~= nil then
    setVariable("WIND_SPEED_MS", one(windDms / 10))
    UpdateProperty("Wind Speed", one(windDms / 10) .. " m/s")
  end
  local rain = tonumber(state.data_rain_mmh)
  if rain ~= nil then
    setVariable("RAIN_RATE_MMH", rain)
    UpdateProperty("Rain", rain .. " mm/h")
  end
  local sun = tonumber(state.data_sun_level)
  if sun ~= nil then
    setVariable("SUN_LEVEL", sun)
    UpdateProperty("Sun Level", sun == 0 and "Dark" or tostring(sun))
  end
  local unixtime = tonumber(state.data_unixtime)
  if unixtime ~= nil then
    UpdateProperty("Last Measured", os.date("%Y-%m-%d %H:%M:%S", unixtime))
  end

  -- Batteries (percent + decivolts).
  local battery = tonumber(state.battery)
  local voltage = tonumber(state.battery_voltage_dV)
  if battery ~= nil or voltage ~= nil then
    setVariable("SOLAR_BATTERY", battery or 0)
    UpdateProperty(
      "Solar Battery",
      string.format("%s%%%s", tostring(battery or "?"), voltage and (" (" .. one(voltage / 10) .. "V)") or "")
    )
  end
  local battery2 = tonumber(state.battery_2)
  local voltage2 = tonumber(state.battery_2_voltage_dV)
  if battery2 ~= nil or voltage2 ~= nil then
    setVariable("BACKUP_BATTERY", battery2 or 0)
    UpdateProperty(
      "Backup Battery",
      string.format("%s%%%s", tostring(battery2 or "?"), voltage2 and (" (" .. one(voltage2 / 10) .. "V)") or "")
    )
  end

  -- Flag transitions -> paired events. First sight is baseline, not a
  -- transition — a restart must not re-announce rain that never stopped.
  for key, pair in pairs(FLAG_EVENTS) do
    local value = state[key]
    if value ~= nil then
      local flag = value == true or tostring(value) == "true"
      if gFlags[key] ~= nil and gFlags[key] ~= flag then
        fireEvent(flag and pair[1] or pair[2])
      end
      gFlags[key] = flag
    end
  end
  setVariable("IS_RAINING", gFlags.is_raining and "true" or "false")
  setVariable("NO_DATA", gFlags.status_flag_no_data and "true" or "false")
  pcall(function()
    C4:SetConditionalState("BOND_WEATHER_RAINING", gFlags.is_raining == true)
  end)

  -- Status transitions -> trigger events.
  local status = state.status and tostring(state.status) or nil
  if status ~= nil then
    if gStatus ~= nil and gStatus ~= status and STATUS_EVENTS[status] ~= nil then
      fireEvent(STATUS_EVENTS[status])
    end
    gStatus = status
    local line = status
    if gFlags.status_flag_unstable then
      line = line .. ", unstable"
    end
    if gFlags.status_flag_no_data then
      line = line .. ", NO DATA"
    end
    if gFlags.status_flag_low_temperature then
      line = line .. ", freeze warning"
    end
    UpdateProperty("Sensor Status", line)
  end

  publishValues(unixtime)
end

child.setup({
  defaultNamePrefix = DEFAULT_NAME_PREFIX,
  onIdentity = function(identity)
    UpdateProperty("Bond Device", identity.name)
  end,
  onState = applyState,
})

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
  local identity = child.restoreIdentity()
  if identity ~= nil then
    UpdateProperty("Bond Device", identity.name)
    if identity.state ~= nil then
      applyState(identity.state)
    end
  end
  child.requestIdentity()
  child.armRetry()
end

function OnDriverDestroyed()
  child.cancelRetry()
end

-- ─── Value connection requests ────────────────────────────────────────────────

--- A consumer (thermostat) asking for the current reading.
function RFP.GET_SENSOR_VALUE(idBinding)
  if idBinding == TEMPERATURE_BINDING or idBinding == HUMIDITY_BINDING then
    publishValues(nil)
  end
end

-- ─── Actions / properties ─────────────────────────────────────────────────────

function EC.REFRESH_FROM_GATEWAY()
  child.requestIdentity()
end

function EC.PRINT_DIAGNOSTICS()
  local identity = child.identity()
  log:print("== Bond Weather (SBOS) diagnostics ==")
  log:print("  gateway device: %s", tostring(child.findGatewayDeviceId() or "NOT FOUND"))
  log:print(
    "  identity: %s",
    identity ~= nil and string.format("'%s' (%s/%s)", identity.name, identity.id, identity.fn) or "none"
  )
  log:print(
    "  temp C: %s | humidity: %s | status: %s | raining: %s | no data: %s",
    tostring(gTempC),
    tostring(gHumidity),
    tostring(gStatus),
    tostring(gFlags.is_raining),
    tostring(gFlags.status_flag_no_data)
  )
end

function EC.FORGET_DEVICE()
  child.forget()
  gFlags = {}
  gStatus = nil
  gTempC = nil
  gHumidity = nil
  UpdateProperty("Bond Device", "Not bound")
  child.requestIdentity()
end

function OPC.Display_Units()
  -- Repaint the Temperature property in the newly chosen unit.
  if gTempC ~= nil then
    if tostring(Properties["Display Units"] or "Fahrenheit") == "Celsius" then
      UpdateProperty("Temperature", one(gTempC) .. " C")
    else
      UpdateProperty("Temperature", one(gTempC * 9 / 5 + 32) .. " F")
    end
  end
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
end

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
end
