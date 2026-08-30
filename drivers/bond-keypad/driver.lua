--[[==========================================================================
  Bond Keypad — child driver for Sidekick remotes

  One instance per Bond Sidekick (SKN-386, Mate Pro and friends). Identity
  and battery/signal arrive from the Bond Bridge Gateway; key presses
  arrive as BOND_KEYSTREAM pushes — the Bond only reports Sidekick keys
  over its push protocol (the HTTP endpoint answers 204 by design), so
  press latency is BPUP latency.

  What a press becomes, per key 1-8:
    - Composer events: Button N - Tap / Double Tap / Hold Start / Hold End
      (event ids stride by 5 per button, matching the layout dealers know
      from the commercial Bond keypad driver).
    - BUTTON_LINK connections: Tap and Double Tap links emit a click; the
      Hold link emits push on HOLD_START and release on HOLD_END, so a
      held Sidekick key can RAMP a bound Control4 dimmer.
    - Variables LAST_BUTTON / LAST_EVENT / LAST_HOLD_MS for programming
      on any key without 32 event handlers.

  Battery transitions (the Bond reports coarse OK/Low/Critical bands) fire
  their own events — a dead Sidekick battery is a service call that should
  have been a notification a year earlier.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "bond-keypad.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "bond-keypad.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local child = require("bond.child")

local DEFAULT_NAME_PREFIX = "Bond Keypad"
local MAX_KEYS = 8

--- Button link binding ids per gesture: link id = base + key.
local TAP_LINK_BASE = 209
local DOUBLE_TAP_LINK_BASE = 219
local HOLD_LINK_BASE = 199

--- Event id = (key-1)*5 + offset.
local EVENT_OFFSETS = {
  TAP = 1,
  DOUBLE_TAP = 2,
  HOLD_START = 3,
  HOLD_END = 4,
}
local EVENT_LABELS = {
  TAP = "Tap",
  DOUBLE_TAP = "Double Tap",
  HOLD_START = "Hold Start",
  HOLD_END = "Hold End",
}

local VARIABLES = {
  { "LAST_BUTTON", "0", "NUMBER" },
  { "LAST_EVENT", "", "STRING" },
  { "LAST_HOLD_MS", "0", "NUMBER" },
  { "BATTERY_LEVEL", "0", "NUMBER" },
}

gInitialized = false
gBatteryBand = nil

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

--- Registers the whole event vocabulary at init — XML events only register
--- when an instance is first added, and update-in-place installs must still
--- grow new ones.
local function registerEvents()
  for key = 1, MAX_KEYS do
    local base = (key - 1) * 5
    pcall(function()
      C4:AddEvent(base + 1, "Button " .. key .. " - Tap", "NAME button " .. key .. " tapped.")
      C4:AddEvent(base + 2, "Button " .. key .. " - Double Tap", "NAME button " .. key .. " double tapped.")
      C4:AddEvent(base + 3, "Button " .. key .. " - Hold Start", "NAME button " .. key .. " hold started.")
      C4:AddEvent(base + 4, "Button " .. key .. " - Hold End", "NAME button " .. key .. " hold released.")
    end)
  end
  pcall(function()
    C4:AddEvent(41, "Battery OK", "NAME battery back to OK.")
    C4:AddEvent(42, "Battery Low", "NAME battery low - replace within a year.")
    C4:AddEvent(43, "Battery Critical", "NAME battery critical - may fail at any time.")
  end)
end

--- Battery percent → band label, per the spec's rendering guidance.
local function batteryBand(level)
  if level == nil then
    return nil
  end
  if level <= 10 then
    return "Critical"
  elseif level <= 30 then
    return "Low"
  end
  return "OK"
end

--- Applies a state document ({battery, signal} for keypads).
local function applyState(state)
  local battery = tonumber(state.battery)
  local signal = tonumber(state.signal)
  if battery ~= nil then
    local band = batteryBand(battery)
    setVariable("BATTERY_LEVEL", battery)
    UpdateProperty("Battery", string.format("%s (%d%%)", band, battery))
    if gBatteryBand ~= nil and gBatteryBand ~= band then
      fireEvent("Battery " .. band)
    end
    gBatteryBand = band
  end
  if signal ~= nil then
    UpdateProperty("Signal", tostring(signal) .. "%")
  end
end

child.setup({
  defaultNamePrefix = DEFAULT_NAME_PREFIX,
  onIdentity = function(identity)
    UpdateProperty("Bond Device", identity.name)
    UpdateProperty("Keys", tostring((identity.props or {}).keys or "-"))
  end,
  onState = applyState,
})

-- ─── Key events ───────────────────────────────────────────────────────────────

--- One keystream push from the gateway: fire the Composer event, drive the
--- button links, update the programming variables.
local function handleKeystream(tParams)
  tParams = tParams or {}
  local key = tonumber(tParams.key)
  local event = tostring(tParams.event or "")
  -- HOLD repeats many times a second while a key is down: variables track
  -- it (hold-to-ramp programming reads LAST_HOLD_MS) but no event fires
  -- and no link clicks — the Hold link's push/release already bracket it.
  local isHoldRepeat = event == "HOLD"
  if key == nil or key < 1 or (EVENT_OFFSETS[event] == nil and not isHoldRepeat) then
    return
  end
  local holdMs = tonumber(tParams.hold_ms) or 0

  setVariable("LAST_BUTTON", key)
  setVariable("LAST_EVENT", event)
  if isHoldRepeat or event == "HOLD_END" then
    setVariable("LAST_HOLD_MS", holdMs)
  end
  if isHoldRepeat then
    return
  end
  UpdateProperty("Last Button", string.format("%d %s %s", key, EVENT_LABELS[event], os.date("%H:%M:%S")))

  if key <= MAX_KEYS then
    fireEvent(string.format("Button %d - %s", key, EVENT_LABELS[event]))
    if event == "TAP" then
      SendToProxy(TAP_LINK_BASE + key, "DO_CLICK", {})
    elseif event == "DOUBLE_TAP" then
      SendToProxy(DOUBLE_TAP_LINK_BASE + key, "DO_CLICK", {})
    elseif event == "HOLD_START" then
      SendToProxy(HOLD_LINK_BASE + key, "DO_PUSH", {})
    elseif event == "HOLD_END" then
      SendToProxy(HOLD_LINK_BASE + key, "DO_RELEASE", {})
    end
  else
    log:debug("Key %d is beyond the %d surfaced buttons; variables updated only", key, MAX_KEYS)
  end
end

RFP.BOND_KEYSTREAM = function(_, _, tParams)
  handleKeystream(tParams)
end
EC.BOND_KEYSTREAM = handleKeystream

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
  registerEvents()
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
    UpdateProperty("Keys", tostring((identity.props or {}).keys or "-"))
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

-- ─── Actions ──────────────────────────────────────────────────────────────────

function EC.REFRESH_FROM_GATEWAY()
  child.requestIdentity()
end

function EC.PRINT_DIAGNOSTICS()
  local identity = child.identity()
  log:print("== Bond Keypad (SBOS) diagnostics ==")
  log:print("  gateway device: %s", tostring(child.findGatewayDeviceId() or "NOT FOUND"))
  log:print(
    "  identity: %s",
    identity ~= nil and string.format("'%s' (%s/%s)", identity.name, identity.id, identity.fn) or "none"
  )
  log:print("  keys: %s | battery band: %s", tostring(((identity or {}).props or {}).keys), tostring(gBatteryBand))
end

function EC.FORGET_DEVICE()
  child.forget()
  gBatteryBand = nil
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
