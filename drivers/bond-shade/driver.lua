--[[==========================================================================
  Bond Shade — child driver

  One instance per Bond motorized shade / awning / screen. Identity/state
  arrive from the Bond Bridge Gateway; controls travel back as BOND_ACTION
  requests. A native blind proxy gives the stock Navigator shade row —
  open/stop/close buttons plus a position slider where the device can
  actually do positions.

  Level model, and the ONE inversion to never get backwards:
    C4 blind level: 0 = closed … 100 = open
    Bond position:  0 = retracted (OPEN) … 100 = extended (CLOSED)
  so level = 100 - position. `open_raises`/`open_retracts` (awnings,
  top-down) only change which PHYSICAL direction "open" is — Bond already
  folds that into Open()/Close() and `open`/`position`, so no extra math
  here.

  Positionless shades (no SetPosition in actions): the driver reports
  SET_HAS_LEVEL false at identity time so Navigator drops the slider and
  keeps the three buttons — no lying 0-100 control for a shade that only
  knows open/close. Partial levels that still arrive map: 0 → Close,
  100 → Open, anything else → Preset when available, else nearest end.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "bond-shade.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "bond-shade.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local child = require("bond.child")

local BLIND_PROXY_BINDING = 5001
--- Keypad button links (Connections view): toggle / up / down / stop.
local TOGGLE_LINK = 300
local UP_LINK = 301
local DOWN_LINK = 302
local STOP_LINK = 303
local DEFAULT_NAME_PREFIX = "Bond Shade"

--- Travel-time fallback when the Bond has no `course_time` property. Their
--- commercial counterpart hardcodes 20s; ours only falls back to it.
local DEFAULT_TRAVEL_MS = 20000

local EVENTS = {
  { 1, "Opened", "The shade reported open." },
  { 2, "Closed", "The shade reported closed." },
}

local VARIABLES = {
  { "SHADE_OPEN", "false", "BOOL" },
  { "SHADE_LEVEL", "-1", "NUMBER" },
}

gInitialized = false
gOpen = nil
gLevel = nil

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

local function hasPosition()
  return child.hasAction("SetPosition")
end

--- Tells the proxy whether this shade really has a level. Sent at identity
--- time — capabilities XML is static, but the blind proxy accepts runtime
--- configuration notifications for exactly this reason.
local function announceLevelSupport()
  SendToProxy(BLIND_PROXY_BINDING, "SET_HAS_LEVEL", {
    HAS_LEVEL = hasPosition() and "true" or "false",
    LEVEL_OPEN = 100,
    LEVEL_CLOSED = hasPosition() and 0 or 2,
    LEVEL_DISCRETE_CONTROL = hasPosition() and "true" or "false",
  }, "NOTIFY")
  SendToProxy(BLIND_PROXY_BINDING, "SET_CAN_STOP", {
    CAN_STOP = child.hasAction("Hold") and "true" or "false",
  }, "NOTIFY")
end

--- Applies a Bond state document: variables, events, proxy notification.
local function applyState(state)
  local open = tonumber(state.open)
  local position = tonumber(state.position)

  if open ~= nil then
    local isOpen = open == 1
    if gOpen ~= nil and gOpen ~= isOpen then
      fireEvent(isOpen and "Opened" or "Closed")
    end
    gOpen = isOpen
    setVariable("SHADE_OPEN", isOpen and "true" or "false")
    pcall(function()
      C4:SetConditionalState("BOND_SHADE_OPEN", isOpen)
    end)
  end

  -- C4 level out of Bond position (inverted), falling back to the open flag
  -- for positionless shades, and honest about unknown (-1).
  local level
  if position ~= nil and position >= 0 and hasPosition() then
    level = 100 - math.max(0, math.min(100, position))
  elseif position ~= nil and position < 0 then
    level = -1
  elseif open ~= nil then
    level = open == 1 and 100 or 0
  end

  if level ~= nil then
    gLevel = level
    setVariable("SHADE_LEVEL", level)
    UpdateProperty("Position", level >= 0 and (tostring(level) .. "% open") or "unknown (after Preset/Hold)")
    if level >= 0 then
      SendToProxy(BLIND_PROXY_BINDING, "STOPPED", { LEVEL = level }, "NOTIFY")
    end
  end
end

child.setup({
  defaultNamePrefix = DEFAULT_NAME_PREFIX,
  onIdentity = function(identity)
    UpdateProperty("Bond Device", identity.name)
    announceLevelSupport()
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
    announceLevelSupport()
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

-- ─── Blind proxy commands ─────────────────────────────────────────────────────

--- Movement feedback: Navigator animates the shade toward `target` for the
--- travel time instead of snapping. The ramp is the Bond's own `course_time`
--- when the device carries one (Bridge Pro position emulation), scaled by
--- how far the shade actually has to travel; only unknown course times fall
--- back to a fixed figure. Unknown start position sends no feedback — an
--- animation from a made-up level is worse than a snap.
local function announceMoving(target)
  if gLevel == nil or gLevel < 0 or target == nil then
    return
  end
  local courseTime = tonumber(((child.identity() or {}).props or {}).course_time)
  if courseTime == nil or courseTime <= 0 then
    courseTime = DEFAULT_TRAVEL_MS
  end
  local ramp = math.floor(courseTime * math.abs(target - gLevel) / 100)
  if ramp <= 0 then
    return
  end
  SendToProxy(BLIND_PROXY_BINDING, "MOVING", { LEVEL_TARGET = target, RAMP_RATE = ramp, LEVEL = gLevel }, "NOTIFY")
end

local function goToLevel(level)
  level = tonumber(level)
  if level == nil then
    return
  end
  if level >= 100 then
    announceMoving(100)
    child.action("Open")
  elseif level <= 0 then
    announceMoving(0)
    child.action("Close")
  elseif hasPosition() then
    -- The inversion, the other way around.
    announceMoving(level)
    child.action("SetPosition", 100 - level)
  elseif child.hasAction("Preset") then
    child.action("Preset")
  elseif level >= 50 then
    announceMoving(100)
    child.action("Open")
  else
    announceMoving(0)
    child.action("Close")
  end
end

function RFP.SET_LEVEL_TARGET(idBinding, _, tParams)
  if idBinding ~= BLIND_PROXY_BINDING then
    return
  end
  goToLevel((tParams or {}).LEVEL_TARGET or (tParams or {}).LEVEL)
end

function RFP.SET_LEVEL(idBinding, _, tParams)
  return RFP.SET_LEVEL_TARGET(idBinding, nil, tParams)
end

function RFP.OPEN(idBinding)
  if idBinding == BLIND_PROXY_BINDING then
    announceMoving(100)
    child.action("Open")
  end
end

function RFP.CLOSE(idBinding)
  if idBinding == BLIND_PROXY_BINDING then
    announceMoving(0)
    child.action("Close")
  end
end

function RFP.TOGGLE(idBinding)
  if idBinding == BLIND_PROXY_BINDING then
    child.action("ToggleOpen")
  end
end

--- Hold stops the shade wherever it is; the immediate STOPPED halts the
--- Navigator animation right away, at the last KNOWN level — the true
--- position is unknown after a Hold (one-way RF) and the next state push
--- says so.
local function stopShade()
  child.action("Hold")
  if gLevel ~= nil and gLevel >= 0 then
    SendToProxy(BLIND_PROXY_BINDING, "STOPPED", { LEVEL = gLevel }, "NOTIFY")
  end
end

function RFP.STOP(idBinding)
  if idBinding == BLIND_PROXY_BINDING then
    stopShade()
  end
end

--- Keypad button links: tap = act. PUSH/RELEASE absorbed silently.
function RFP.DO_CLICK(idBinding)
  if idBinding == TOGGLE_LINK then
    child.action("ToggleOpen")
  elseif idBinding == UP_LINK then
    announceMoving(100)
    child.action("Open")
  elseif idBinding == DOWN_LINK then
    announceMoving(0)
    child.action("Close")
  elseif idBinding == STOP_LINK then
    stopShade()
  end
end

function RFP.DO_PUSH() end
function RFP.DO_RELEASE() end

-- ─── Composer commands ────────────────────────────────────────────────────────

function EC.OPEN()
  child.action("Open")
end

function EC.CLOSE()
  child.action("Close")
end

function EC.STOP()
  child.action("Hold")
end

function EC.GO_TO_PRESET()
  child.action("Preset")
end

EC.Open = EC.OPEN
EC.Close = EC.CLOSE
EC.Stop = EC.STOP
EC.Go_To_Preset = EC.GO_TO_PRESET

-- ─── Conditionals / actions ───────────────────────────────────────────────────

function TC.BOND_SHADE_OPEN()
  return gOpen == true
end

function EC.REFRESH_FROM_GATEWAY()
  child.requestIdentity()
end

function EC.PRINT_DIAGNOSTICS()
  local identity = child.identity()
  log:print("== Bond Shade (SBOS) diagnostics ==")
  log:print("  gateway device: %s", tostring(child.findGatewayDeviceId() or "NOT FOUND"))
  log:print(
    "  identity: %s",
    identity ~= nil and string.format("'%s' (%s/%s)", identity.name, identity.id, identity.fn) or "none"
  )
  log:print("  open: %s | level: %s | positional: %s", tostring(gOpen), tostring(gLevel), tostring(hasPosition()))
end

function EC.FORGET_DEVICE()
  child.forget()
  gOpen = nil
  gLevel = nil
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
