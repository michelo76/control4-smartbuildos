--[[==========================================================================
  Bond Fan — child driver

  One instance per Bond ceiling fan (the FAN function of a Bond device).
  Identity/state arrive from the Bond Bridge Gateway; controls travel back
  as BOND_ACTION requests. A native fan proxy makes it a normal Navigator
  fan tile with discrete speeds.

  Speed model: the proxy speaks C4 speeds 0..discrete_levels (0 = off); the
  Bond speaks SetSpeed 1..max_speed plus TurnOn/TurnOff. The child clamps
  proxy speeds to the device's real max_speed (a 3-speed fan under the
  6-level proxy uses 1-3 and ignores nothing — 4..6 clamp to 3).

  Direction is real on Bond (SetDirection/ToggleDirection) but the proxy's
  can_reverse is static XML and most Bond fans lack it, so it stays off in
  Navigator and lives on Composer commands instead.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "bond-fan.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "bond-fan.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local child = require("bond.child")

local FAN_PROXY_BINDING = 5001
--- Keypad button links (Connections view): toggle / speed down / speed up.
local TOGGLE_LINK = 300
local SPEED_DOWN_LINK = 301
local SPEED_UP_LINK = 302
local DEFAULT_NAME_PREFIX = "Bond Fan"

local EVENTS = {
  { 1, "Fan On", "The fan turned on." },
  { 2, "Fan Off", "The fan turned off." },
  { 3, "Speed Changed", "The fan speed changed." },
}

local VARIABLES = {
  { "FAN_ON", "false", "BOOL" },
  { "FAN_SPEED", "0", "NUMBER" },
  { "FAN_DIRECTION", "", "STRING" },
}

gInitialized = false

--- Last state applied, for transition detection. nil until first state.
gPower = nil
gSpeed = nil

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

--- The device's real top speed, from Bond properties (falls back to the
--- proxy's 6 so clamping never divides by zero).
local function maxSpeed()
  local identity = child.identity()
  local value = tonumber(((identity or {}).props or {}).max_speed)
  if value == nil or value < 1 then
    return 6
  end
  return value
end

--- Applies a Bond state document: variables, events, proxy notifications.
local function applyState(state)
  local power = tonumber(state.power)
  local speed = tonumber(state.speed)
  local direction = tonumber(state.direction)

  if power ~= nil then
    local on = power == 1
    if gPower ~= nil and (gPower == 1) ~= on then
      fireEvent(on and "Fan On" or "Fan Off")
    end
    gPower = power
    setVariable("FAN_ON", on and "true" or "false")
    pcall(function()
      C4:SetConditionalState("BOND_FAN_ON", on)
    end)
  end
  if speed ~= nil then
    if gSpeed ~= nil and gSpeed ~= speed then
      fireEvent("Speed Changed")
    end
    gSpeed = speed
  end

  -- The proxy's one source of truth: current speed, 0 while off.
  local proxySpeed = 0
  if (power or 0) == 1 then
    proxySpeed = speed or 1
  end
  setVariable("FAN_SPEED", proxySpeed)
  SendToProxy(FAN_PROXY_BINDING, "CURRENT_SPEED", { SPEED = proxySpeed }, "NOTIFY")
  -- Keypad LEDs bound to the toggle link track power.
  SendToProxy(TOGGLE_LINK, "MATCH_LED_STATE", { STATE = (power or 0) == 1 and "1" or "0" }, "NOTIFY")

  UpdateProperty("Fan", (power or 0) == 1 and "On" or "Off")
  UpdateProperty("Speed", tostring(proxySpeed) .. " of " .. tostring(maxSpeed()))
  if direction ~= nil then
    local label = direction == 1 and "FORWARD" or "REVERSE"
    setVariable("FAN_DIRECTION", label)
    UpdateProperty("Direction", label:lower())
    SendToProxy(FAN_PROXY_BINDING, "DIRECTION", { DIRECTION = label }, "NOTIFY")
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

-- ─── Fan proxy commands ───────────────────────────────────────────────────────

--- ON restores the Bond's own remembered speed — better than any preset the
--- proxy could designate, so can_set_preset stays false.
function RFP.ON(idBinding)
  if idBinding ~= FAN_PROXY_BINDING then
    return
  end
  child.action("TurnOn")
end

function RFP.OFF(idBinding)
  if idBinding ~= FAN_PROXY_BINDING then
    return
  end
  child.action("TurnOff")
end

function RFP.TOGGLE(idBinding)
  if idBinding ~= FAN_PROXY_BINDING then
    return
  end
  child.action("TogglePower")
end

function RFP.SET_SPEED(idBinding, _, tParams)
  if idBinding ~= FAN_PROXY_BINDING then
    return
  end
  local speed = tonumber((tParams or {}).SPEED or (tParams or {}).LEVEL) or 0
  if speed <= 0 then
    child.action("TurnOff")
    return
  end
  if speed > maxSpeed() then
    speed = maxSpeed()
  end
  child.action("SetSpeed", speed)
end

function RFP.CYCLE_SPEED_UP(idBinding)
  if idBinding ~= FAN_PROXY_BINDING then
    return
  end
  child.action("IncreaseSpeed", 1)
end

--- Cycling below speed 1 turns off (Bond's own DecreaseSpeed floors at 1,
--- which would leave the bottom button dead).
function RFP.CYCLE_SPEED_DOWN(idBinding)
  if idBinding ~= FAN_PROXY_BINDING then
    return
  end
  if (gPower or 0) == 1 and (gSpeed or 0) <= 1 then
    child.action("TurnOff")
  else
    child.action("DecreaseSpeed", 1)
  end
end

function RFP.SET_DIRECTION(idBinding, _, tParams)
  if idBinding ~= FAN_PROXY_BINDING then
    return
  end
  local direction = tostring((tParams or {}).DIRECTION or ""):upper()
  child.action("SetDirection", direction == "REVERSE" and -1 or 1)
end

function RFP.TOGGLE_DIRECTION(idBinding)
  if idBinding ~= FAN_PROXY_BINDING then
    return
  end
  child.action("ToggleDirection")
end

--- Keypad button links: tap = act. PUSH/RELEASE are absorbed silently so a
--- keypad that sends all three never double-fires.
function RFP.DO_CLICK(idBinding)
  if idBinding == TOGGLE_LINK then
    child.action("TogglePower")
  elseif idBinding == SPEED_DOWN_LINK then
    RFP.CYCLE_SPEED_DOWN(FAN_PROXY_BINDING)
  elseif idBinding == SPEED_UP_LINK then
    child.action("IncreaseSpeed", 1)
  end
end

function RFP.DO_PUSH() end
function RFP.DO_RELEASE() end

--- The proxy asking for initial state on (re)connect.
function RFP.GET_CURRENT_STATE(idBinding)
  if idBinding ~= FAN_PROXY_BINDING then
    return
  end
  local identity = child.identity()
  if identity ~= nil and identity.state ~= nil then
    applyState(identity.state)
  end
end

-- ─── Composer commands ────────────────────────────────────────────────────────

function EC.SET_DIRECTION(tParams)
  local direction = tostring((tParams or {}).Direction or ""):lower()
  child.action("SetDirection", direction == "reverse" and -1 or 1)
end

function EC.TOGGLE_DIRECTION()
  child.action("ToggleDirection")
end

function EC.BREEZE_ON()
  child.action("BreezeOn")
end

function EC.BREEZE_OFF()
  child.action("BreezeOff")
end

function EC.SET_TIMER(tParams)
  child.action("SetTimer", tonumber((tParams or {}).Seconds) or 0)
end

EC.Set_Direction = EC.SET_DIRECTION
EC.Toggle_Direction = EC.TOGGLE_DIRECTION
EC.Breeze_On = EC.BREEZE_ON
EC.Breeze_Off = EC.BREEZE_OFF
EC.Set_Timer = EC.SET_TIMER

-- ─── Conditionals / actions ───────────────────────────────────────────────────

function TC.BOND_FAN_ON()
  return (gPower or 0) == 1
end

function EC.REFRESH_FROM_GATEWAY()
  child.requestIdentity()
end

function EC.PRINT_DIAGNOSTICS()
  local identity = child.identity()
  log:print("== Bond Fan (SBOS) diagnostics ==")
  log:print("  gateway device: %s", tostring(child.findGatewayDeviceId() or "NOT FOUND"))
  log:print(
    "  identity: %s",
    identity ~= nil and string.format("'%s' (%s/%s)", identity.name, identity.id, identity.fn) or "none"
  )
  log:print("  power: %s | speed: %s | max: %s", tostring(gPower), tostring(gSpeed), tostring(maxSpeed()))
end

function EC.FORGET_DEVICE()
  child.forget()
  gPower = nil
  gSpeed = nil
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
