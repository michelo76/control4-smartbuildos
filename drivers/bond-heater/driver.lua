--[[==========================================================================
  Bond Heater — child driver

  One instance per Bond heater with an adjustable heat level (HT devices
  with the Heat feature — Infratech and friends behind a Bond Bridge Pro).
  Identity/state arrive from the Bond Bridge Gateway; controls travel back
  as BOND_ACTION requests.

  The Navigator face is a heat-only THERMOSTAT dial where the setpoint IS
  the heat level: scale pinned to Celsius, range 0-100, so the ring reads
  0-100 with no meaningful units — turn the dial, SetHeat follows. There is
  no ambient sensor on these devices, so the centre of the dial stays
  blank (the driver never reports a temperature it does not have).

  The Extras tab carries the auto-off timer in minutes (Bond's Timer
  feature). Heaters with a factory fire-code cap (default_auto_timer_s)
  keep it — the Bond clamps SetTimer to that cap and restarts it on every
  state change; this driver surfaces the timer, never fights the cap.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "bond-heater.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "bond-heater.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local child = require("bond.child")

local THERMO_PROXY = 5001
local RELAY_BINDING = 200
--- Keypad button links (Connections view): toggle / heat up / heat down.
local TOGGLE_LINK = 300
local HEAT_UP_LINK = 301
local HEAT_DOWN_LINK = 302
local DEFAULT_NAME_PREFIX = "Bond Heater"

--- One keypad tap moves the heat level this much.
local HEAT_STEP = 10

--- Extras object id + the command its XML binds. The Extras contract: the
--- UI sends the object's command with the new value and reverts after 10
--- quiet seconds, so every handler answers with an EXTRAS_STATE_CHANGED.
local TIMER_OBJECT_ID = "timer_minutes"

local EVENTS = {
  { 1, "Heater On", "The heater turned on." },
  { 2, "Heater Off", "The heater turned off." },
  { 3, "Heat Level Changed", "The heat level changed." },
}

local VARIABLES = {
  { "HEATER_ON", "false", "BOOL" },
  { "HEAT_LEVEL", "0", "NUMBER" },
  { "TIMER_REMAINING", "0", "NUMBER" },
}

gInitialized = false
gPower = nil
gHeat = nil
gTimer = nil

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

-- ─── Extras (the Timer tab) ───────────────────────────────────────────────────

--- Minutes shown on the Extras tab, from the Bond's seconds-remaining.
local function timerMinutes()
  return math.ceil((gTimer or 0) / 60)
end

local function extrasSetupXml()
  return table.concat({
    '<extras_setup><extra><section label="Timer">',
    string.format(
      '<object type="number" id="%s" label="Timer (in minutes)" command="SET_TIMER_MINUTES" value="%d" min="0" max="480" step="5"/>',
      TIMER_OBJECT_ID,
      timerMinutes()
    ),
    "</section></extra></extras_setup>",
  })
end

local function extrasStateXml()
  return string.format(
    '<extras_state><extra><object id="%s" value="%d"/></extra></extras_state>',
    TIMER_OBJECT_ID,
    timerMinutes()
  )
end

local function sendExtrasSetup()
  SendToProxy(THERMO_PROXY, "EXTRAS_SETUP_CHANGED", { XML = extrasSetupXml() }, "NOTIFY")
end

local function sendExtrasState()
  SendToProxy(THERMO_PROXY, "EXTRAS_STATE_CHANGED", { XML = extrasStateXml() }, "NOTIFY")
end

-- ─── State ────────────────────────────────────────────────────────────────────

--- Applies a Bond state document: variables, events, thermostat + relay
--- notifications, Extras state.
local function applyState(state)
  local power = tonumber(state.power)
  local heat = tonumber(state.heat)
  local timer = tonumber(state.timer)

  if power ~= nil then
    local on = power == 1
    if gPower ~= nil and (gPower == 1) ~= on then
      fireEvent(on and "Heater On" or "Heater Off")
    end
    gPower = power
    setVariable("HEATER_ON", on and "true" or "false")
    pcall(function()
      C4:SetConditionalState("BOND_HEATER_ON", on)
    end)
    local mode = on and "Heat" or "Off"
    SendToProxy(THERMO_PROXY, "HVAC_MODE_CHANGED", { MODE = mode }, "NOTIFY")
    SendToProxy(THERMO_PROXY, "HVAC_STATE_CHANGED", { STATE = mode }, "NOTIFY")
    SendToProxy(RELAY_BINDING, on and "CLOSED" or "OPENED", {}, "NOTIFY")
    SendToProxy(TOGGLE_LINK, "MATCH_LED_STATE", { STATE = on and "1" or "0" }, "NOTIFY")
    UpdateProperty("Heater", on and "On" or "Off")
  end

  if heat ~= nil then
    if gHeat ~= nil and gHeat ~= heat then
      fireEvent("Heat Level Changed")
    end
    gHeat = heat
  end
  -- The dial's setpoint: the remembered heat level, shown even while off
  -- (Bond restores it on TurnOn, and a dial that zeroes when off fights
  -- the user who is about to turn it on).
  if gHeat ~= nil then
    setVariable("HEAT_LEVEL", gHeat)
    UpdateProperty("Heat Level", tostring(gHeat) .. "%")
    SendToProxy(THERMO_PROXY, "HEAT_SETPOINT_CHANGED", { SETPOINT = gHeat, SCALE = "CELSIUS" }, "NOTIFY")
  end

  if timer ~= nil then
    gTimer = timer
    setVariable("TIMER_REMAINING", timer)
    UpdateProperty("Timer", timer > 0 and (tostring(timer) .. "s remaining") or "off")
    sendExtrasState()
  end
end

child.setup({
  defaultNamePrefix = DEFAULT_NAME_PREFIX,
  onIdentity = function(identity)
    UpdateProperty("Bond Device", identity.name)
    sendExtrasSetup()
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
    sendExtrasSetup()
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

-- ─── Thermostat proxy commands ────────────────────────────────────────────────

--- The dial's setpoint: 0 turns the heater off, anything else is SetHeat
--- (which implicitly turns on — Bond's own Heat-feature contract).
local function setHeatLevel(level)
  level = tonumber(level)
  if level == nil then
    return
  end
  if level <= 0 then
    child.action("TurnOff")
  else
    child.action("SetHeat", math.min(math.floor(level), 100))
  end
end

function RFP.SET_SETPOINT_HEAT(idBinding, _, tParams)
  if idBinding ~= THERMO_PROXY then
    return
  end
  tParams = tParams or {}
  -- The proxy may hand the value under any of these keys depending on OS
  -- version and scale plumbing; scale is pinned to Celsius in the XML so
  -- they all mean the same 0-100 number.
  setHeatLevel(tParams.SETPOINT or tParams.CELSIUS or tParams.FAHRENHEIT or tParams.VALUE)
end

function RFP.SET_MODE_HVAC(idBinding, _, tParams)
  if idBinding ~= THERMO_PROXY then
    return
  end
  local mode = tostring((tParams or {}).MODE or ""):lower()
  if mode == "heat" then
    child.action("TurnOn")
  elseif mode == "off" then
    child.action("TurnOff")
  end
end

--- The proxy asking for initial values on (re)connect.
function RFP.GET_CURRENT_STATE(idBinding)
  if idBinding ~= THERMO_PROXY then
    return
  end
  local identity = child.identity()
  if identity ~= nil and identity.state ~= nil then
    applyState(identity.state)
  end
  sendExtrasSetup()
end

function RFP.GET_EXTRAS_SETUP(idBinding)
  if idBinding == THERMO_PROXY then
    sendExtrasSetup()
  end
end

function RFP.GET_EXTRAS_STATE(idBinding)
  if idBinding == THERMO_PROXY then
    sendExtrasState()
  end
end

--- The Extras timer object's own command: minutes from the UI. Always
--- answered with a state notify — the UI reverts the control after 10
--- silent seconds.
function RFP.SET_TIMER_MINUTES(idBinding, _, tParams)
  tParams = tParams or {}
  local minutes = tonumber(tParams.VALUE or tParams.value or tParams[TIMER_OBJECT_ID])
  if minutes == nil then
    sendExtrasState()
    return
  end
  gTimer = math.max(0, math.floor(minutes)) * 60
  child.action("SetTimer", gTimer)
  sendExtrasState()
end

-- ─── Button links / relay ─────────────────────────────────────────────────────

function RFP.DO_CLICK(idBinding)
  if idBinding == TOGGLE_LINK then
    child.action("TogglePower")
  elseif idBinding == HEAT_UP_LINK then
    child.action("IncreaseHeat", HEAT_STEP)
  elseif idBinding == HEAT_DOWN_LINK then
    if (gPower or 0) == 1 and (gHeat or 0) <= HEAT_STEP then
      child.action("TurnOff")
    else
      child.action("DecreaseHeat", HEAT_STEP)
    end
  end
end

function RFP.DO_PUSH() end
function RFP.DO_RELEASE() end

--- Relay vocabulary: CLOSE = energize = on.
function RFP.CLOSE(idBinding)
  if idBinding == RELAY_BINDING then
    child.action("TurnOn")
  end
end

function RFP.OPEN(idBinding)
  if idBinding == RELAY_BINDING then
    child.action("TurnOff")
  end
end

function RFP.TOGGLE(idBinding)
  if idBinding == RELAY_BINDING then
    child.action("TogglePower")
  end
end

-- ─── Composer commands ────────────────────────────────────────────────────────

function EC.TURN_ON()
  child.action("TurnOn")
end

function EC.TURN_OFF()
  child.action("TurnOff")
end

function EC.SET_HEAT(tParams)
  setHeatLevel((tParams or {}).Level)
end

function EC.SET_TIMER(tParams)
  child.action("SetTimer", tonumber((tParams or {}).Seconds) or 0)
end

EC.Turn_On = EC.TURN_ON
EC.Turn_Off = EC.TURN_OFF
EC.Set_Heat = EC.SET_HEAT
EC.Set_Timer = EC.SET_TIMER

-- ─── Conditionals / actions ───────────────────────────────────────────────────

function TC.BOND_HEATER_ON()
  return (gPower or 0) == 1
end

function EC.REFRESH_FROM_GATEWAY()
  child.requestIdentity()
end

function EC.PRINT_DIAGNOSTICS()
  local identity = child.identity()
  log:print("== Bond Heater (SBOS) diagnostics ==")
  log:print("  gateway device: %s", tostring(child.findGatewayDeviceId() or "NOT FOUND"))
  log:print(
    "  identity: %s",
    identity ~= nil and string.format("'%s' (%s/%s)", identity.name, identity.id, identity.fn) or "none"
  )
  log:print("  power: %s | heat: %s | timer: %ss", tostring(gPower), tostring(gHeat), tostring(gTimer))
end

function EC.FORGET_DEVICE()
  child.forget()
  gPower = nil
  gHeat = nil
  gTimer = nil
  UpdateProperty("Bond Device", "Not bound")
  child.requestIdentity()
end

-- ─── Properties ───────────────────────────────────────────────────────────────

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
end

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
end
