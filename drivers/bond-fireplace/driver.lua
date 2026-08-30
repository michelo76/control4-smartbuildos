--[[==========================================================================
  Bond Fireplace — child driver

  One instance per Bond fireplace. Five Navigator tiles (uibutton proxies),
  matching the commercial Bond driver's Comfort-screen layout with the
  suite's own icon set:

    5001  Power        (states Off/On — tap = toggle)
    5002  Flame Level  (states Off/Low/Medium/High — tap = cycle)
    5003  Flame Up     (tap = IncreaseFlame)
    5004  Flame Down   (tap = DecreaseFlame)
    5005  Fireplace Fan (states Off/Low/Medium/High — tap = cycle; FpFan)

  Buttons whose feature the device lacks (no Flame feature, no FpFan) stay
  visible but answer taps with a log line — uibutton proxies are static XML.
  Dealers hide unused tiles per-room in Composer; the documentation says so.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "bond-fireplace.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "bond-fireplace.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local child = require("bond.child")

local POWER_PROXY = 5001
local FLAME_PROXY = 5002
local FLAME_UP_PROXY = 5003
local FLAME_DOWN_PROXY = 5004
local FPFAN_PROXY = 5005
--- Keypad button links (Connections view): toggle / flame up / flame down.
local TOGGLE_LINK = 300
local FLAME_UP_LINK = 301
local FLAME_DOWN_LINK = 302
local DEFAULT_NAME_PREFIX = "Bond Fireplace"

--- Flame percent per cycle stop, and the labels the icon states use.
local FLAME_STOPS = { 33, 66, 100 }
local FPFAN_STOPS = { 33, 66, 100 }

local EVENTS = {
  { 1, "Fireplace On", "The fireplace turned on." },
  { 2, "Fireplace Off", "The fireplace turned off." },
  { 3, "Flame Changed", "The flame level changed." },
}

local VARIABLES = {
  { "FIREPLACE_ON", "false", "BOOL" },
  { "FLAME_LEVEL", "0", "NUMBER" },
  { "FIREPLACE_FAN_SPEED", "0", "NUMBER" },
}

gInitialized = false
gPower = nil
gFlame = nil
gFpFanPower = nil
gFpFanSpeed = nil

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

--- Level → icon-state label (shared by flame and fan tiles).
local function levelLabel(level)
  if level == nil or level <= 0 then
    return "Off"
  elseif level <= 40 then
    return "Low"
  elseif level <= 75 then
    return "Medium"
  end
  return "High"
end

local function setIcon(binding, iconState)
  SendToProxy(binding, "ICON_CHANGED", { icon = iconState, icon_description = iconState }, "NOTIFY")
end

--- Applies a Bond state document: variables, events, tile icons.
local function applyState(state)
  local power = tonumber(state.power)
  local flame = tonumber(state.flame)
  local fpfanPower = tonumber(state.fpfan_power)
  local fpfanSpeed = tonumber(state.fpfan_speed)

  if power ~= nil then
    local on = power == 1
    if gPower ~= nil and (gPower == 1) ~= on then
      fireEvent(on and "Fireplace On" or "Fireplace Off")
    end
    gPower = power
    setVariable("FIREPLACE_ON", on and "true" or "false")
    pcall(function()
      C4:SetConditionalState("BOND_FIREPLACE_ON", on)
    end)
    setIcon(POWER_PROXY, on and "On" or "Off")
    SendToProxy(TOGGLE_LINK, "MATCH_LED_STATE", { STATE = on and "1" or "0" }, "NOTIFY")
    UpdateProperty("Fireplace", on and "On" or "Off")
  end

  if flame ~= nil then
    if gFlame ~= nil and gFlame ~= flame then
      fireEvent("Flame Changed")
    end
    gFlame = flame
  end
  local flameShown = (gPower or 0) == 1 and (gFlame or 0) or 0
  setVariable("FLAME_LEVEL", flameShown)
  setIcon(FLAME_PROXY, levelLabel(flameShown))
  UpdateProperty("Flame", flameShown > 0 and (tostring(flameShown) .. "%") or "Off")

  if fpfanPower ~= nil then
    gFpFanPower = fpfanPower
  end
  if fpfanSpeed ~= nil then
    gFpFanSpeed = fpfanSpeed
  end
  if fpfanPower ~= nil or fpfanSpeed ~= nil then
    local fanShown = (gFpFanPower or 0) == 1 and (gFpFanSpeed or 0) or 0
    setVariable("FIREPLACE_FAN_SPEED", fanShown)
    setIcon(FPFAN_PROXY, levelLabel(fanShown))
    UpdateProperty("Fireplace Fan", fanShown > 0 and (tostring(fanShown) .. "%") or "Off")
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

-- ─── Tile taps ────────────────────────────────────────────────────────────────

--- Next stop in a cycle list, based on the current percent.
local function nextStop(stops, current)
  for _, stop in ipairs(stops) do
    if (current or 0) < stop then
      return stop
    end
  end
  return nil -- past the top: wrap to off
end

local function tapPower()
  child.action("TogglePower")
end

local function tapFlame()
  if not child.hasAction("SetFlame") then
    log:print("This fireplace has no flame level control (no Flame feature); use the Power tile")
    return
  end
  local current = (gPower or 0) == 1 and (gFlame or 0) or 0
  local stop = nextStop(FLAME_STOPS, current)
  if stop == nil then
    child.action("TurnOff")
  else
    child.action("SetFlame", stop)
  end
end

local function tapFlameUp()
  if child.hasAction("IncreaseFlame") then
    child.action("IncreaseFlame", 20)
  else
    tapFlame()
  end
end

local function tapFlameDown()
  if child.hasAction("DecreaseFlame") then
    child.action("DecreaseFlame", 20)
  else
    log:print("This fireplace has no flame level control")
  end
end

local function tapFpFan()
  if not child.hasAction("SetFpFan") then
    log:print("This fireplace has no fan (no FpFan feature)")
    return
  end
  local current = (gFpFanPower or 0) == 1 and (gFpFanSpeed or 0) or 0
  local stop = nextStop(FPFAN_STOPS, current)
  if stop == nil then
    child.action("TurnFpFanOff")
  else
    child.action("SetFpFan", stop)
  end
end

local TAPS = {
  [POWER_PROXY] = tapPower,
  [FLAME_PROXY] = tapFlame,
  [FLAME_UP_PROXY] = tapFlameUp,
  [FLAME_DOWN_PROXY] = tapFlameDown,
  [FPFAN_PROXY] = tapFpFan,
  -- Keypad button links share the tile handlers.
  [TOGGLE_LINK] = tapPower,
  [FLAME_UP_LINK] = tapFlameUp,
  [FLAME_DOWN_LINK] = tapFlameDown,
}

function RFP.SELECT(idBinding)
  local tap = TAPS[idBinding]
  if tap ~= nil then
    tap()
  end
end

function RFP.DO_CLICK(idBinding)
  return RFP.SELECT(idBinding)
end

function RFP.DO_PUSH() end
function RFP.DO_RELEASE() end

function RFP.ON(idBinding)
  if idBinding == POWER_PROXY then
    child.action("TurnOn")
  end
end

function RFP.OFF(idBinding)
  if idBinding == POWER_PROXY then
    child.action("TurnOff")
  end
end

-- ─── Composer commands ────────────────────────────────────────────────────────

function EC.TURN_ON()
  child.action("TurnOn")
end

function EC.TURN_OFF()
  child.action("TurnOff")
end

function EC.SET_FLAME(tParams)
  local level = tonumber((tParams or {}).Level)
  if level ~= nil and level >= 1 then
    child.action("SetFlame", math.min(level, 100))
  end
end

function EC.SET_FIREPLACE_FAN(tParams)
  local speed = tonumber((tParams or {}).Speed)
  if speed == nil then
    return
  end
  if speed <= 0 then
    child.action("TurnFpFanOff")
  else
    child.action("SetFpFan", math.min(speed, 100))
  end
end

function EC.SET_TIMER(tParams)
  child.action("SetTimer", tonumber((tParams or {}).Seconds) or 0)
end

EC.Turn_On = EC.TURN_ON
EC.Turn_Off = EC.TURN_OFF
EC.Set_Flame = EC.SET_FLAME
EC.Set_Fireplace_Fan = EC.SET_FIREPLACE_FAN
EC.Set_Timer = EC.SET_TIMER

-- ─── Conditionals / actions ───────────────────────────────────────────────────

function TC.BOND_FIREPLACE_ON()
  return (gPower or 0) == 1
end

function EC.REFRESH_FROM_GATEWAY()
  child.requestIdentity()
end

function EC.PRINT_DIAGNOSTICS()
  local identity = child.identity()
  log:print("== Bond Fireplace (SBOS) diagnostics ==")
  log:print("  gateway device: %s", tostring(child.findGatewayDeviceId() or "NOT FOUND"))
  log:print(
    "  identity: %s",
    identity ~= nil and string.format("'%s' (%s/%s)", identity.name, identity.id, identity.fn) or "none"
  )
  log:print(
    "  power: %s | flame: %s | fpfan: %s/%s",
    tostring(gPower),
    tostring(gFlame),
    tostring(gFpFanPower),
    tostring(gFpFanSpeed)
  )
end

function EC.FORGET_DEVICE()
  child.forget()
  gPower = nil
  gFlame = nil
  gFpFanPower = nil
  gFpFanSpeed = nil
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
