--[[==========================================================================
  SmartBuildOS System Link — Thermostat companion
  Presents ONE thermostat export of the linked project as a native Control4
  thermostatV2 thermostat. State arrives from the System Link bridge on this controller;
  control requests go back through it to the owner, who executes them on
  the real device. The proxy only ever shows CONFIRMED state from the owner;
  a request is shown separately as Requested State until feedback arrives.
  Licensing: inherits the bridge's pair licence (suite convention).
  Hardware validation: none yet — see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-system-link-thermostat.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-system-link-thermostat.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local base = require("systemlink.companiondriver")

gInitialized = false

-- FEATURE-GATED (SL-07): the thermostatV2 vocabulary below is taken from
-- Control4's shipped and Bond thermostat drivers, not from a cached proxy
-- document. The bridge refuses to export a thermostat unless the pair
-- licence carries the THERMOSTAT feature, and this driver shows the gate
-- in Bridge Link until then. Cached setpoints are NEVER pushed to the owner
-- on restart: only explicit user commands become requests.
local PROXY = 5001
local gMode, gState, gHeat, gCool, gTemp, gFan = nil, nil, nil, nil, nil, nil

local function num(v)
  if v == JSON.null then
    return nil
  end
  return tonumber(v)
end
local function str(v)
  if v == JSON.null or v == nil then
    return nil
  end
  return tostring(v)
end

base.install({
  kind = "thermostat",
  logName = "SystemLinkThermostat",
  applyState = function(fields, fresh)
    if fresh ~= "current" then
      return
    end
    local temp, heat, cool = num(fields.Temperature), num(fields.Heat_Setpoint), num(fields.Cool_Setpoint)
    local mode, hvac, fan = str(fields.HVAC_Mode), str(fields.HVAC_State), str(fields.Fan_Mode)
    if temp ~= nil and temp ~= gTemp then
      gTemp = temp
      SendToProxy(PROXY, "TEMPERATURE_CHANGED", { TEMPERATURE = temp, SCALE = "FAHRENHEIT" }, "NOTIFY")
    end
    if heat ~= nil and heat ~= gHeat then
      gHeat = heat
      SendToProxy(PROXY, "HEAT_SETPOINT_CHANGED", { SETPOINT = heat, SCALE = "FAHRENHEIT" }, "NOTIFY")
    end
    if cool ~= nil and cool ~= gCool then
      gCool = cool
      SendToProxy(PROXY, "COOL_SETPOINT_CHANGED", { SETPOINT = cool, SCALE = "FAHRENHEIT" }, "NOTIFY")
    end
    if mode ~= nil and mode ~= gMode then
      gMode = mode
      SendToProxy(PROXY, "HVAC_MODE_CHANGED", { MODE = mode }, "NOTIFY")
    end
    if hvac ~= nil and hvac ~= gState then
      gState = hvac
      SendToProxy(PROXY, "HVAC_STATE_CHANGED", { STATE = hvac }, "NOTIFY")
    end
    if fan ~= nil and fan ~= gFan then
      gFan = fan
      SendToProxy(PROXY, "FAN_MODE_CHANGED", { MODE = fan }, "NOTIFY")
    end
  end,
  describeState = function(fields)
    local temp, heat, cool, mode =
      num(fields.Temperature), num(fields.Heat_Setpoint), num(fields.Cool_Setpoint), str(fields.HVAC_Mode)
    if temp == nil and mode == nil then
      return "unavailable"
    end
    return string.format(
      "%s°F · heat %s · cool %s · %s",
      tostring(temp or "?"),
      tostring(heat or "?"),
      tostring(cool or "?"),
      mode or "?"
    )
  end,
  onLateInit = function()
    SendToProxy(PROXY, "SCALE_CHANGED", { SCALE = "FAHRENHEIT" }, "NOTIFY")
    SendToProxy(
      PROXY,
      "ALLOWED_HVAC_MODES_CHANGED",
      { MODES = "Off,Heat,Cool,Auto", CAN_HEAT = "true", CAN_COOL = "true", CAN_AUTO = "false" },
      "NOTIFY"
    )
    SendToProxy(PROXY, "ALLOWED_FAN_MODES_CHANGED", { MODES = "Auto,On" }, "NOTIFY")
  end,
})

local function setpointFrom(tParams)
  tParams = tParams or {}
  local v = tonumber(tParams.FAHRENHEIT) or tonumber(tParams.SETPOINT)
  if v == nil and tonumber(tParams.CELSIUS) then
    v = tonumber(tParams.CELSIUS) * 9 / 5 + 32
  end
  return v
end

function RFP.SET_SETPOINT_HEAT(idBinding, _, tParams)
  if idBinding ~= PROXY then
    return
  end
  local v = setpointFrom(tParams)
  if v then
    base.control("set_heat", { setpoint = v }, "heat " .. tostring(v))
  end
end
function RFP.SET_SETPOINT_COOL(idBinding, _, tParams)
  if idBinding ~= PROXY then
    return
  end
  local v = setpointFrom(tParams)
  if v then
    base.control("set_cool", { setpoint = v }, "cool " .. tostring(v))
  end
end
function RFP.SET_MODE_HVAC(idBinding, _, tParams)
  if idBinding ~= PROXY then
    return
  end
  base.control("set_mode", { mode = tostring((tParams or {}).MODE or "") }, "mode " .. tostring((tParams or {}).MODE))
end
function RFP.SET_MODE_FAN(idBinding, _, tParams)
  if idBinding ~= PROXY then
    return
  end
  base.control("set_fan", { mode = tostring((tParams or {}).MODE or "") }, "fan " .. tostring((tParams or {}).MODE))
end

-- ─── Bench actions: one click each, the same control path the proxy uses ───
-- (Composer's Actions tab, so a dealer can prove the link controls the
-- remote device without wiring programming first; bench 2026-10-20).
function EC.TEST_HEAT_68()
  base.control("set_heat", { setpoint = 68 }, "heat 68")
end
function EC.TEST_COOL_76()
  base.control("set_cool", { setpoint = 76 }, "cool 76")
end
function EC.TEST_MODE_HEAT()
  base.control("set_mode", { mode = "Heat" }, "mode Heat")
end
function EC.TEST_MODE_OFF()
  base.control("set_mode", { mode = "Off" }, "mode Off")
end
