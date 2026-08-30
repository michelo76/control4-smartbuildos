--[[==========================================================================
  Bond Color Light — child driver for Firefly and other full-color devices

  One instance per Bond device with the Color feature (SetHSV — Firefly
  bulbs and strips). Identity/state arrive from the Bond Bridge Gateway;
  controls travel back as BOND_ACTION requests. A light_v2 proxy with color
  gives the stock Navigator color wheel and CCT picker.

  The color spaces, and who owns which:
    Control4 speaks CIE-1931 xy (SET_COLOR_TARGET / LIGHT_COLOR_CHANGED);
    Bond speaks HSV (SetHSV, `hsv` state) and Kelvin (SetColorTemp).
    The OS 3.3.0 C4:Color* helpers do every conversion — this driver never
    does colorimetry math of its own.

  Per Bond's own guidance, color changes send only `h` and `s` — brightness
  stays with SET_BRIGHTNESS_TARGET/SetBrightness, so picking a color never
  yanks the level. CCT targets go to SetColorTemp when the device has the
  ColorTemp feature (clamped to its real min/max), else degrade to white
  via SetHSV{s=0} — every Navigator gesture does the closest honest thing.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "bond-color-light.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "bond-color-light.c4z" }
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
local DEFAULT_NAME_PREFIX = "Bond Color Light"

--- The XML capability bounds; the device's real ColorTemp range narrows
--- them at runtime when known.
local CCT_MIN_DEFAULT = 2000
local CCT_MAX_DEFAULT = 7000

local EVENTS = {
  { 1, "Light On", "The light turned on." },
  { 2, "Light Off", "The light turned off." },
  { 3, "Color Changed", "The color changed." },
}

local VARIABLES = {
  { "LIGHT_ON", "false", "BOOL" },
  { "LIGHT_BRIGHTNESS", "0", "NUMBER" },
  { "HUE", "0", "NUMBER" },
  { "SATURATION", "0", "NUMBER" },
  { "COLOR_TEMP", "0", "NUMBER" },
}

gInitialized = false
gLightOn = nil
gBrightness = nil
gHue = nil
gSaturation = nil
gColorTemp = nil

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

local function hasColorTemp()
  return child.hasAction("SetColorTemp")
end

--- The device's real CCT bounds, from Bond properties when present.
local function cctBounds()
  local props = (child.identity() or {}).props or {}
  local min = tonumber(props.min_color_temp) or CCT_MIN_DEFAULT
  local max = tonumber(props.max_color_temp) or CCT_MAX_DEFAULT
  return min, max
end

--- Publishes the current color to the proxy. White (saturation 0) with a
--- known color temperature reports as CCT mode so Navigator's picker lands
--- on the right tab; everything else is full color.
local function notifyColor()
  local x, y, mode
  if gColorTemp ~= nil and (gSaturation or 0) == 0 then
    local ok, cx, cy = pcall(function()
      return C4:ColorCCTtoXY(gColorTemp)
    end)
    if ok and cx ~= nil then
      x, y, mode = cx, cy, 1
    end
  end
  if x == nil and gHue ~= nil then
    local ok, cx, cy = pcall(function()
      return C4:ColorHSVtoXY(gHue, gSaturation or 0, 100)
    end)
    if ok and cx ~= nil then
      x, y, mode = cx, cy, 0
    end
  end
  if x == nil then
    return
  end
  SendToProxy(LIGHT_PROXY_BINDING, "LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = x,
    LIGHT_COLOR_CURRENT_Y = y,
    LIGHT_COLOR_CURRENT_COLOR_MODE = mode,
  }, "NOTIFY")
end

--- Applies a Bond state document: variables, events, proxy notifications.
local function applyState(state)
  local light = tonumber(state.light)
  local brightness = tonumber(state.brightness)
  local hsv = type(state.hsv) == "table" and state.hsv or nil
  local colorTemp = tonumber(state.color_temp)

  if light ~= nil then
    local on = light == 1
    if gLightOn ~= nil and gLightOn ~= on then
      fireEvent(on and "Light On" or "Light Off")
    end
    gLightOn = on
    setVariable("LIGHT_ON", on and "true" or "false")
    pcall(function()
      C4:SetConditionalState("BOND_COLOR_LIGHT_ON", on)
    end)
  end
  if brightness ~= nil then
    gBrightness = brightness
  end

  local level = 0
  if (light or 0) == 1 then
    level = gBrightness or 100
  end
  setVariable("LIGHT_BRIGHTNESS", level)
  UpdateProperty("Light", (light or 0) == 1 and "On" or "Off")
  UpdateProperty("Brightness", tostring(level) .. "%")
  SendToProxy(LIGHT_PROXY_BINDING, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level }, "NOTIFY")
  -- Keypad LEDs: toggle and on links track lit, off link tracks dark.
  local lit = (light or 0) == 1
  SendToProxy(TOGGLE_LINK, "MATCH_LED_STATE", { STATE = lit and "1" or "0" }, "NOTIFY")
  SendToProxy(ON_LINK, "MATCH_LED_STATE", { STATE = lit and "1" or "0" }, "NOTIFY")
  SendToProxy(OFF_LINK, "MATCH_LED_STATE", { STATE = lit and "0" or "1" }, "NOTIFY")

  local colorMoved = false
  if hsv ~= nil then
    local h = tonumber(hsv.h)
    local s = tonumber(hsv.s)
    if h ~= nil and s ~= nil and (h ~= gHue or s ~= gSaturation) then
      colorMoved = gHue ~= nil
      gHue = h
      gSaturation = s
    elseif h ~= nil and s ~= nil then
      gHue = h
      gSaturation = s
    end
    setVariable("HUE", gHue or 0)
    setVariable("SATURATION", gSaturation or 0)
    UpdateProperty("Color", string.format("hue %d, saturation %d%%", gHue or 0, gSaturation or 0))
  end
  if colorTemp ~= nil then
    if gColorTemp ~= nil and gColorTemp ~= colorTemp then
      colorMoved = true
    end
    gColorTemp = colorTemp
    setVariable("COLOR_TEMP", colorTemp)
    UpdateProperty("Color Temperature", tostring(colorTemp) .. "K")
  end
  if colorMoved then
    fireEvent("Color Changed")
  end
  if hsv ~= nil or colorTemp ~= nil then
    notifyColor()
  end
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
  else
    child.action("SetBrightness", math.min(level, 100))
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

--- Sets a white color temperature the closest honest way the device can.
local function setCct(kelvin)
  kelvin = tonumber(kelvin)
  if kelvin == nil then
    return
  end
  if hasColorTemp() then
    local min, max = cctBounds()
    child.action("SetColorTemp", math.max(min, math.min(max, math.floor(kelvin / 100 + 0.5) * 100)))
  else
    -- No ColorTemp feature: white is saturation 0.
    child.action("SetHSV", { h = 0, s = 0 })
  end
end

function RFP.SET_COLOR_TARGET(idBinding, _, tParams)
  if idBinding ~= LIGHT_PROXY_BINDING then
    return
  end
  tParams = tParams or {}
  local x = tonumber(tParams.LIGHT_COLOR_TARGET_X)
  local y = tonumber(tParams.LIGHT_COLOR_TARGET_Y)
  if x == nil or y == nil then
    return
  end
  local mode = tonumber(tParams.LIGHT_COLOR_TARGET_MODE or tParams.LIGHT_COLOR_TARGET_COLOR_MODE) or 0
  if mode == 1 then
    local ok, kelvin = pcall(function()
      return C4:ColorXYtoCCT(x, y)
    end)
    if ok and kelvin ~= nil then
      setCct(kelvin)
    end
    return
  end
  local ok, h, s = pcall(function()
    return C4:ColorXYtoHSV(x, y)
  end)
  if not ok or h == nil then
    return
  end
  -- h and s only — brightness belongs to SET_BRIGHTNESS_TARGET (Bond's own
  -- recommendation for 2-D color pickers).
  child.action("SetHSV", { h = math.floor(h + 0.5) % 360, s = math.max(0, math.min(100, math.floor(s + 0.5))) })
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

-- ─── Composer commands ────────────────────────────────────────────────────────

function EC.SET_COLOR(tParams)
  tParams = tParams or {}
  local h = tonumber(tParams.Hue)
  local s = tonumber(tParams.Saturation)
  if h == nil and s == nil then
    return
  end
  local argument = {}
  if h ~= nil then
    argument.h = math.floor(h + 0.5) % 360
  end
  if s ~= nil then
    argument.s = math.max(0, math.min(100, math.floor(s + 0.5)))
  end
  child.action("SetHSV", argument)
end

function EC.SET_COLOR_TEMPERATURE(tParams)
  setCct((tParams or {}).Kelvin)
end

function EC.START_DIMMER()
  child.action("StartDimmer")
end

function EC.STOP_DIMMER()
  child.action("Stop")
end

EC.Set_Color = EC.SET_COLOR
EC.Set_Color_Temperature = EC.SET_COLOR_TEMPERATURE
EC.Start_Dimmer = EC.START_DIMMER
EC.Stop_Dimmer = EC.STOP_DIMMER

-- ─── Conditionals / actions ───────────────────────────────────────────────────

function TC.BOND_COLOR_LIGHT_ON()
  return gLightOn == true
end

function EC.REFRESH_FROM_GATEWAY()
  child.requestIdentity()
end

function EC.PRINT_DIAGNOSTICS()
  local identity = child.identity()
  log:print("== Bond Color Light (SBOS) diagnostics ==")
  log:print("  gateway device: %s", tostring(child.findGatewayDeviceId() or "NOT FOUND"))
  log:print(
    "  identity: %s",
    identity ~= nil and string.format("'%s' (%s/%s)", identity.name, identity.id, identity.fn) or "none"
  )
  log:print(
    "  light: %s | brightness: %s | hsv: %s/%s | cct: %s (%s)",
    tostring(gLightOn),
    tostring(gBrightness),
    tostring(gHue),
    tostring(gSaturation),
    tostring(gColorTemp),
    hasColorTemp() and "native" or "via white HSV"
  )
end

function EC.FORGET_DEVICE()
  child.forget()
  gLightOn = nil
  gBrightness = nil
  gHue = nil
  gSaturation = nil
  gColorTemp = nil
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
