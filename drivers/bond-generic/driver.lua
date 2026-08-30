--[[==========================================================================
  Bond Switch — child driver for generic Bond devices

  One instance per Bond device that is "just power": generic templates (GX),
  smart switches (SW), heaters (HT), bidets — anything with TurnOn/TurnOff
  and no richer function claimed. One Navigator tile (uibutton, On/Off
  states) plus a RELAY provider connection so Composer can treat it as a
  relay for integrations that want one.

  Heaters keep their SetHeat granularity through the Gateway's Run Bond
  Action command until a dedicated heater child exists (roadmap).
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "bond-generic.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "bond-generic.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local child = require("bond.child")

local BUTTON_PROXY = 5001
local RELAY_BINDING = 200
--- Keypad button links (Connections view): toggle / on / off.
local TOGGLE_LINK = 300
local ON_LINK = 301
local OFF_LINK = 302
local DEFAULT_NAME_PREFIX = "Bond Switch"

local EVENTS = {
  { 1, "Turned On", "The device turned on." },
  { 2, "Turned Off", "The device turned off." },
}

local VARIABLES = {
  { "SWITCH_ON", "false", "BOOL" },
}

gInitialized = false
gPower = nil

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

--- Applies a Bond state document: variable, events, tile icon, relay state.
local function applyState(state)
  local power = tonumber(state.power)
  if power == nil then
    return
  end
  local on = power == 1
  if gPower ~= nil and (gPower == 1) ~= on then
    fireEvent(on and "Turned On" or "Turned Off")
  end
  gPower = power
  setVariable("SWITCH_ON", on and "true" or "false")
  pcall(function()
    C4:SetConditionalState("BOND_SWITCH_ON", on)
  end)
  UpdateProperty("Power", on and "On" or "Off")
  SendToProxy(
    BUTTON_PROXY,
    "ICON_CHANGED",
    { icon = on and "On" or "Off", icon_description = on and "On" or "Off" },
    "NOTIFY"
  )
  SendToProxy(RELAY_BINDING, on and "CLOSED" or "OPENED", {}, "NOTIFY")
  -- Keypad LEDs: toggle and on links track on, off link tracks off.
  SendToProxy(TOGGLE_LINK, "MATCH_LED_STATE", { STATE = on and "1" or "0" }, "NOTIFY")
  SendToProxy(ON_LINK, "MATCH_LED_STATE", { STATE = on and "1" or "0" }, "NOTIFY")
  SendToProxy(OFF_LINK, "MATCH_LED_STATE", { STATE = on and "0" or "1" }, "NOTIFY")
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

-- ─── Tile / relay commands ────────────────────────────────────────────────────

function RFP.SELECT(idBinding)
  if idBinding == BUTTON_PROXY then
    child.action("TogglePower")
  end
end

function RFP.DO_CLICK(idBinding)
  if idBinding == TOGGLE_LINK then
    child.action("TogglePower")
  elseif idBinding == ON_LINK then
    child.action("TurnOn")
  elseif idBinding == OFF_LINK then
    child.action("TurnOff")
  else
    return RFP.SELECT(idBinding)
  end
end

function RFP.DO_PUSH() end
function RFP.DO_RELEASE() end

function RFP.ON(idBinding)
  if idBinding == BUTTON_PROXY then
    child.action("TurnOn")
  end
end

function RFP.OFF(idBinding)
  if idBinding == BUTTON_PROXY then
    child.action("TurnOff")
  end
end

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
  if idBinding == RELAY_BINDING or idBinding == BUTTON_PROXY then
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

function EC.SET_TIMER(tParams)
  child.action("SetTimer", tonumber((tParams or {}).Seconds) or 0)
end

EC.Turn_On = EC.TURN_ON
EC.Turn_Off = EC.TURN_OFF
EC.Set_Timer = EC.SET_TIMER

-- ─── Conditionals / actions ───────────────────────────────────────────────────

function TC.BOND_SWITCH_ON()
  return (gPower or 0) == 1
end

function EC.REFRESH_FROM_GATEWAY()
  child.requestIdentity()
end

function EC.PRINT_DIAGNOSTICS()
  local identity = child.identity()
  log:print("== Bond Switch (SBOS) diagnostics ==")
  log:print("  gateway device: %s", tostring(child.findGatewayDeviceId() or "NOT FOUND"))
  log:print(
    "  identity: %s",
    identity ~= nil and string.format("'%s' (%s/%s)", identity.name, identity.id, identity.fn) or "none"
  )
  log:print("  power: %s", tostring(gPower))
end

function EC.FORGET_DEVICE()
  child.forget()
  gPower = nil
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
