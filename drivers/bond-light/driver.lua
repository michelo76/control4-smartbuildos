--[[==========================================================================
  Bond Light — child driver

  One instance per Bond light function: a ceiling fan's light, a fireplace
  light, or a standalone Bond light/dimmer. Identity/state arrive from the
  Bond Bridge Gateway; controls travel back as BOND_ACTION requests. A
  native light_v2 proxy makes it a normal Navigator light.

  Brightness model: the proxy always offers a level (set_level is static
  XML). Devices whose action list carries SetBrightness dim for real; for
  on/off-only lights any non-zero level maps to TurnLightOn, and the level
  reported back snaps to 0/100 — the slider behaves like a switch instead
  of lying about a brightness the RF protocol cannot express.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "bond-light.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "bond-light.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local child = require("bond.child")

local LIGHT_PROXY_BINDING = 5001
--- Keypad button links (Connections view): toggle / on / off.
local TOGGLE_LINK = 300
local ON_LINK = 301
local OFF_LINK = 302
local DEFAULT_NAME_PREFIX = "Bond Light"

local EVENTS = {
  { 1, "Light On", "The light turned on." },
  { 2, "Light Off", "The light turned off." },
}

local VARIABLES = {
  { "LIGHT_ON", "false", "BOOL" },
  { "LIGHT_BRIGHTNESS", "0", "NUMBER" },
}

gInitialized = false
gLightOn = nil
gBrightness = nil

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

local function dimmable()
  return child.hasAction("SetBrightness")
end

--- Applies a Bond state document: variables, events, proxy notification.
local function applyState(state)
  local light = tonumber(state.light)
  local brightness = tonumber(state.brightness)

  if light ~= nil then
    local on = light == 1
    if gLightOn ~= nil and gLightOn ~= on then
      fireEvent(on and "Light On" or "Light Off")
    end
    gLightOn = on
    setVariable("LIGHT_ON", on and "true" or "false")
    pcall(function()
      C4:SetConditionalState("BOND_LIGHT_ON", on)
    end)
  end
  if brightness ~= nil then
    gBrightness = brightness
  end

  local level = 0
  if (light or 0) == 1 then
    level = dimmable() and (brightness or 100) or 100
  end
  setVariable("LIGHT_BRIGHTNESS", level)
  UpdateProperty("Light", (light or 0) == 1 and "On" or "Off")
  UpdateProperty("Brightness", dimmable() and (tostring(level) .. "%") or "not dimmable")
  SendToProxy(LIGHT_PROXY_BINDING, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level }, "NOTIFY")
  -- Keypad LEDs: toggle and on links track lit, off link tracks dark.
  local lit = (light or 0) == 1
  SendToProxy(TOGGLE_LINK, "MATCH_LED_STATE", { STATE = lit and "1" or "0" }, "NOTIFY")
  SendToProxy(ON_LINK, "MATCH_LED_STATE", { STATE = lit and "1" or "0" }, "NOTIFY")
  SendToProxy(OFF_LINK, "MATCH_LED_STATE", { STATE = lit and "0" or "1" }, "NOTIFY")
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

-- ─── Light proxy commands ─────────────────────────────────────────────────────

local function setLevel(level)
  level = tonumber(level) or 0
  if level <= 0 then
    child.action("TurnLightOff")
  elseif dimmable() then
    child.action("SetBrightness", math.min(level, 100))
  else
    child.action("TurnLightOn")
  end
end

function RFP.SET_BRIGHTNESS_TARGET(idBinding, _, tParams)
  if idBinding ~= LIGHT_PROXY_BINDING then
    return
  end
  setLevel((tParams or {}).LIGHT_BRIGHTNESS_TARGET or (tParams or {}).LEVEL)
end

function RFP.RAMP_TO_LEVEL(idBinding, _, tParams)
  return RFP.SET_BRIGHTNESS_TARGET(idBinding, nil, tParams)
end

function RFP.SET_LEVEL(idBinding, _, tParams)
  return RFP.SET_BRIGHTNESS_TARGET(idBinding, nil, tParams)
end

function RFP.ON(idBinding)
  if idBinding == LIGHT_PROXY_BINDING then
    child.action("TurnLightOn")
  end
end

function RFP.OFF(idBinding)
  if idBinding == LIGHT_PROXY_BINDING then
    child.action("TurnLightOff")
  end
end

function RFP.TOGGLE(idBinding)
  if idBinding == LIGHT_PROXY_BINDING then
    child.action("ToggleLight")
  end
end

--- Keypad button links: tap = act. PUSH/RELEASE absorbed silently.
function RFP.DO_CLICK(idBinding)
  if idBinding == TOGGLE_LINK then
    child.action("ToggleLight")
  elseif idBinding == ON_LINK then
    child.action("TurnLightOn")
  elseif idBinding == OFF_LINK then
    child.action("TurnLightOff")
  end
end

function RFP.DO_PUSH() end
function RFP.DO_RELEASE() end

function RFP.BUTTON_ACTION(idBinding, _, tParams)
  if idBinding ~= LIGHT_PROXY_BINDING or tostring((tParams or {}).ACTION or "") ~= "2" then
    return
  end
  local button = tostring((tParams or {}).BUTTON_ID or "2")
  if button == "0" then
    child.action("TurnLightOn")
  elseif button == "1" then
    child.action("TurnLightOff")
  else
    child.action("ToggleLight")
  end
end

-- ─── Composer commands ────────────────────────────────────────────────────────

function EC.START_DIMMER()
  child.action("StartDimmer")
end

function EC.STOP_DIMMER()
  child.action("Stop")
end

EC.Start_Dimmer = EC.START_DIMMER
EC.Stop_Dimmer = EC.STOP_DIMMER

-- ─── Conditionals / actions ───────────────────────────────────────────────────

function TC.BOND_LIGHT_ON()
  return gLightOn == true
end

function EC.REFRESH_FROM_GATEWAY()
  child.requestIdentity()
end

function EC.PRINT_DIAGNOSTICS()
  local identity = child.identity()
  log:print("== Bond Light (SBOS) diagnostics ==")
  log:print("  gateway device: %s", tostring(child.findGatewayDeviceId() or "NOT FOUND"))
  log:print(
    "  identity: %s",
    identity ~= nil and string.format("'%s' (%s/%s)", identity.name, identity.id, identity.fn) or "none"
  )
  log:print(
    "  light: %s | brightness: %s | dimmable: %s",
    tostring(gLightOn),
    tostring(gBrightness),
    tostring(dimmable())
  )
end

function EC.FORGET_DEVICE()
  child.forget()
  gLightOn = nil
  gBrightness = nil
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
