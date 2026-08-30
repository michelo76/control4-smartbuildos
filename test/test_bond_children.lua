-- Tests for the Bond child drivers (fan / light / shade / fireplace /
-- generic) and src/bond/child.lua.
--
-- Each driver is loaded in turn against C4 stubs; the shared child module is
-- reset between loads. Every assertion is about the mapping each child owns:
--
--   * Fan: C4 speeds ↔ Bond SetSpeed with clamping to the device's real
--     max_speed; speed 0 = TurnOff; cycle-down from speed 1 turns off;
--     CURRENT_SPEED notifications track power+speed.
--   * Light: dimmable devices get SetBrightness, on/off-only devices map
--     any level to TurnLightOn and report 0/100 — never a fake brightness.
--   * Shade: THE inversion (C4 level 100=open, Bond position 100=closed);
--     positionless shades drop the slider (SET_HAS_LEVEL false) and Stop
--     maps to Hold; unknown position (-1) is reported as unknown, not 0.
--   * Fireplace: tile taps cycle flame/fan stops through Bond actions;
--     state pushes drive the tile icon states.
--   * Generic: toggle tile + relay vocabulary (CLOSE = on).
--
-- Run from the driver root:
--   make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

-- ─── Fakes ────────────────────────────────────────────────────────────────────

package.preload["cloud-client-byte"] = function()
  return {}
end

local store = {}
package.preload["lib.persist"] = function()
  return {
    get = function(_, key, default)
      local value = store[key]
      if value == nil then
        return default
      end
      return value
    end,
    set = function(_, key, value)
      store[key] = value
    end,
    delete = function(_, key)
      store[key] = nil
    end,
  }
end

C4 = C4 or {}

local proxySent = {}
function C4:SendToProxy(binding, command, params, message)
  table.insert(proxySent, { binding = binding, command = command, params = params, message = message })
end

local deviceSent = {}
function C4:SendToDevice(deviceId, command, params)
  table.insert(deviceSent, { device = deviceId, command = command, params = params })
end

--- The gateway the children discover by exact filename.
local GATEWAY_ID = 500
function C4:GetDevices()
  return { ["500"] = { driverFileName = "bond-bridge.c4z" } }
end

function C4:GetProxyDevices()
  return 9001
end

local props = {}

require("c4_shim")

function C4:UpdateProperty(name, value)
  props[name] = value
  if Properties[name] ~= nil then
    Properties[name] = value
  end
end

function C4:GetDriverConfigInfo(key)
  return ({ model = "Bond Child", version = "1.0.0", minimum_os_version = "3.2.0" })[key]
end

function C4:GetVersionInfo()
  return { version = "4.0.0" }
end

function C4:FireEvent() end
function C4:AddEvent() end
function C4:SetConditionalState() end
function C4:SetVariable() end
function C4:AddVariable() end
function C4:RenameDevice() end

-- ─── Helpers ──────────────────────────────────────────────────────────────────

--- Bond actions the child asked the gateway for, oldest first:
--- { action, argument }.
local function requestedActions()
  local actions = {}
  for _, s in ipairs(deviceSent) do
    if s.device == GATEWAY_ID and s.command == "BOND_ACTION" then
      table.insert(actions, { action = s.params.action, argument = s.params.argument })
    end
  end
  return actions
end

local function lastAction()
  local actions = requestedActions()
  return actions[#actions]
end

local function proxyNotifies(binding, command)
  local hits = {}
  for _, s in ipairs(proxySent) do
    if s.binding == binding and s.command == command then
      table.insert(hits, s)
    end
  end
  return hits
end

local function resetTraffic()
  proxySent = {}
  deviceSent = {}
end

--- Loads one child driver fresh: shared module reset, dispatch tables
--- cleared, persist wiped, properties seeded.
local function loadChild(dir, properties)
  store = {}
  props = {}
  resetTraffic()
  package.loaded["bond.child"] = nil
  -- Fresh dispatch tables, not nil: the handlers module is require-cached,
  -- so its file-scope `RFP = {}` only ever runs once. Dispatch happens via
  -- the global NAME at call time, so replacing the tables is clean.
  RFP, EC, OPC, TC, OBC = {}, {}, {}, {}, {}
  Properties = properties
  local loaded, err = pcall(dofile, "drivers/" .. dir .. "/driver.lua")
  if not loaded and tostring(err):find("No such file") then
    loaded, err = pcall(dofile, "../drivers/" .. dir .. "/driver.lua")
  end
  assert(loaded, dir .. "/driver.lua failed to load: " .. tostring(err))
  OnDriverInit()
  OnDriverLateInit()
  resetTraffic()
end

local CHILD_PROPS = {
  ["Bond Device"] = "Not bound",
  ["Gateway Link"] = "",
  ["Last Control"] = "-",
  ["Driver Status"] = "Starting",
  ["Driver Version"] = "unknown",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
}

local function childProps(extra)
  local merged = {}
  for k, v in pairs(CHILD_PROPS) do
    merged[k] = v
  end
  for k, v in pairs(extra or {}) do
    merged[k] = v
  end
  return merged
end

--- Sends the gateway's identity answer through the EC path.
local function identify(device)
  EC.BOND_DEVICE({
    id = device.id,
    fn = device.fn,
    name = device.name,
    type = device.type or "",
    location = "",
    actions_json = JSON:encode(device.actions),
    props_json = JSON:encode(device.props or {}),
    state_json = JSON:encode(device.state or {}),
  })
end

local function pushState(state)
  EC.BOND_STATE({ id = "x", state_json = JSON:encode(state) })
end

-- ═══ FAN ══════════════════════════════════════════════════════════════════════

print("\n[fan] identity, speed mapping, clamping, notifications")

loadChild("bond-fan", childProps({ ["Fan"] = "-", ["Speed"] = "-", ["Direction"] = "-" }))

identify({
  id = "fan1",
  fn = "FAN",
  name = "Master Fan",
  type = "CF",
  actions = { "TurnOn", "TurnOff", "TogglePower", "SetSpeed", "IncreaseSpeed", "DecreaseSpeed", "SetDirection" },
  props = { max_speed = 4 },
  state = { power = 1, speed = 2, direction = 1 },
})

check("identity names the device", props["Bond Device"] == "Master Fan", props["Bond Device"])
local speeds = proxyNotifies(5001, "CURRENT_SPEED")
check("identity state notified CURRENT_SPEED", #speeds >= 1)
check("current speed is 2", speeds[#speeds].params.SPEED == 2)
check("direction notified", #proxyNotifies(5001, "DIRECTION") >= 1)

resetTraffic()
RFP.SET_SPEED(5001, nil, { SPEED = 3 })
local a = lastAction()
check("SET_SPEED 3 → SetSpeed 3", a ~= nil and a.action == "SetSpeed" and a.argument == "3", a and a.action)

resetTraffic()
RFP.SET_SPEED(5001, nil, { SPEED = 6 })
a = lastAction()
check("SET_SPEED 6 clamps to max_speed 4", a ~= nil and a.action == "SetSpeed" and a.argument == "4", a and a.argument)

resetTraffic()
RFP.SET_SPEED(5001, nil, { SPEED = 0 })
a = lastAction()
check("SET_SPEED 0 → TurnOff", a ~= nil and a.action == "TurnOff")

resetTraffic()
RFP.ON(5001)
a = lastAction()
check("ON → TurnOn (Bond restores last speed)", a ~= nil and a.action == "TurnOn")

resetTraffic()
pushState({ power = 1, speed = 1 })
RFP.CYCLE_SPEED_DOWN(5001)
a = lastAction()
check("cycle down at speed 1 → TurnOff", a ~= nil and a.action == "TurnOff", a and a.action)

resetTraffic()
pushState({ power = 0, speed = 3 })
speeds = proxyNotifies(5001, "CURRENT_SPEED")
check("power off notifies speed 0", #speeds >= 1 and speeds[#speeds].params.SPEED == 0)
local leds = proxyNotifies(300, "MATCH_LED_STATE")
check("toggle link LED tracks power off", #leds >= 1 and leds[#leds].params.STATE == "0")

resetTraffic()
RFP.DO_CLICK(300)
a = lastAction()
check("toggle link click → TogglePower", a ~= nil and a.action == "TogglePower")
resetTraffic()
RFP.DO_CLICK(302)
a = lastAction()
check("speed up link click → IncreaseSpeed", a ~= nil and a.action == "IncreaseSpeed")

-- ═══ LIGHT ════════════════════════════════════════════════════════════════════

print("\n[light] dimmable vs on/off-only")

loadChild("bond-light", childProps({ ["Light"] = "-", ["Brightness"] = "-" }))

identify({
  id = "fan1",
  fn = "LIGHT",
  name = "Master Fan Light",
  actions = { "TurnLightOn", "TurnLightOff", "ToggleLight", "SetBrightness" },
  state = { light = 1, brightness = 60 },
})

local levels = proxyNotifies(5001, "LIGHT_BRIGHTNESS_CHANGED")
check(
  "dimmable identity reports true brightness",
  #levels >= 1 and levels[#levels].params.LIGHT_BRIGHTNESS_CURRENT == 60
)

resetTraffic()
RFP.SET_BRIGHTNESS_TARGET(5001, nil, { LIGHT_BRIGHTNESS_TARGET = 45 })
a = lastAction()
check("level 45 → SetBrightness 45", a ~= nil and a.action == "SetBrightness" and a.argument == "45", a and a.action)

resetTraffic()
RFP.SET_BRIGHTNESS_TARGET(5001, nil, { LIGHT_BRIGHTNESS_TARGET = 0 })
a = lastAction()
check("level 0 → TurnLightOff", a ~= nil and a.action == "TurnLightOff")

-- Reload as an on/off-only light.
loadChild("bond-light", childProps({ ["Light"] = "-", ["Brightness"] = "-" }))
identify({
  id = "fp1",
  fn = "LIGHT",
  name = "Fireplace Light",
  actions = { "TurnLightOn", "TurnLightOff", "ToggleLight" },
  state = { light = 1 },
})

levels = proxyNotifies(5001, "LIGHT_BRIGHTNESS_CHANGED")
check("on/off-only reports 100 when on", #levels >= 1 and levels[#levels].params.LIGHT_BRIGHTNESS_CURRENT == 100)

resetTraffic()
RFP.SET_BRIGHTNESS_TARGET(5001, nil, { LIGHT_BRIGHTNESS_TARGET = 45 })
a = lastAction()
check("partial level on non-dimmable → TurnLightOn", a ~= nil and a.action == "TurnLightOn", a and a.action)

resetTraffic()
RFP.DO_CLICK(301)
a = lastAction()
check("on link click → TurnLightOn", a ~= nil and a.action == "TurnLightOn")
resetTraffic()
pushState({ light = 1 })
local offLed = proxyNotifies(302, "MATCH_LED_STATE")
check("off link LED inverse of lit", #offLed >= 1 and offLed[#offLed].params.STATE == "0")

-- ═══ SHADE ════════════════════════════════════════════════════════════════════

print("\n[shade] the inversion, stop, positionless honesty")

loadChild("bond-shade", childProps({ ["Position"] = "-" }))

identify({
  id = "shade1",
  fn = "SHADE",
  name = "Patio Shade",
  type = "MS",
  actions = { "Open", "Close", "ToggleOpen", "SetPosition", "Hold", "Preset" },
  props = { open_raises = true },
  state = { open = 1, position = 0 },
})

local hasLevel = proxyNotifies(5001, "SET_HAS_LEVEL")
check("positional shade announces HAS_LEVEL true", #hasLevel >= 1 and hasLevel[#hasLevel].params.HAS_LEVEL == "true")
local stops = proxyNotifies(5001, "STOPPED")
check("position 0 (retracted) reports level 100 (open)", #stops >= 1 and stops[#stops].params.LEVEL == 100)

resetTraffic()
RFP.SET_LEVEL_TARGET(5001, nil, { LEVEL_TARGET = 25 })
a = lastAction()
check(
  "C4 level 25 → SetPosition 75 (inverted)",
  a ~= nil and a.action == "SetPosition" and a.argument == "75",
  a and a.argument
)

resetTraffic()
RFP.SET_LEVEL_TARGET(5001, nil, { LEVEL_TARGET = 100 })
a = lastAction()
check("level 100 → Open", a ~= nil and a.action == "Open")

resetTraffic()
RFP.SET_LEVEL_TARGET(5001, nil, { LEVEL_TARGET = 50 })
local moving = proxyNotifies(5001, "MOVING")
check("movement feedback announced", #moving >= 1)
check(
  "ramp scales the default travel by distance (100→50 = half of 20s)",
  #moving >= 1 and moving[#moving].params.RAMP_RATE == 10000,
  #moving >= 1 and moving[#moving].params.RAMP_RATE
)
check(
  "movement carries start and target",
  #moving >= 1 and moving[#moving].params.LEVEL == 100 and moving[#moving].params.LEVEL_TARGET == 50
)

resetTraffic()
RFP.STOP(5001)
a = lastAction()
check("Stop → Hold", a ~= nil and a.action == "Hold")
local stopped = proxyNotifies(5001, "STOPPED")
check("Stop halts the animation at the last known level", #stopped >= 1 and stopped[#stopped].params.LEVEL == 100)

resetTraffic()
RFP.DO_CLICK(302)
a = lastAction()
check("down link click → Close", a ~= nil and a.action == "Close")

resetTraffic()
pushState({ open = 0, position = -1 })
stops = proxyNotifies(5001, "STOPPED")
check("unknown position (-1) sends no STOPPED level", #stops == 0, #stops)
check("Position property says unknown", tostring(props["Position"]):find("unknown") ~= nil, props["Position"])

-- Reload as a positionless shade.
loadChild("bond-shade", childProps({ ["Position"] = "-" }))
identify({
  id = "shade2",
  fn = "SHADE",
  name = "Screen",
  type = "MS",
  actions = { "Open", "Close", "ToggleOpen", "Hold" },
  state = { open = 0 },
})

hasLevel = proxyNotifies(5001, "SET_HAS_LEVEL")
check(
  "positionless shade announces HAS_LEVEL false",
  #hasLevel >= 1 and hasLevel[#hasLevel].params.HAS_LEVEL == "false"
)
stops = proxyNotifies(5001, "STOPPED")
check("closed positionless reports level 0", #stops >= 1 and stops[#stops].params.LEVEL == 0)

resetTraffic()
RFP.SET_LEVEL_TARGET(5001, nil, { LEVEL_TARGET = 60 })
a = lastAction()
check("partial level without Preset → Open (nearest end)", a ~= nil and a.action == "Open", a and a.action)

-- ═══ FIREPLACE ════════════════════════════════════════════════════════════════

print("\n[fireplace] tile taps and icon states")

loadChild("bond-fireplace", childProps({ ["Fireplace"] = "-", ["Flame"] = "-", ["Fireplace Fan"] = "-" }))

identify({
  id = "fp1",
  fn = "FIREPLACE",
  name = "Living Room Fireplace",
  type = "FP",
  actions = { "TurnOn", "TurnOff", "TogglePower", "SetFlame", "IncreaseFlame", "DecreaseFlame" },
  state = { power = 1, flame = 33 },
})

local icons = proxyNotifies(5001, "ICON_CHANGED")
check("power tile shows On", #icons >= 1 and icons[#icons].params.icon == "On")
icons = proxyNotifies(5002, "ICON_CHANGED")
check(
  "flame tile shows Low at 33%",
  #icons >= 1 and icons[#icons].params.icon == "Low",
  icons[#icons] and icons[#icons].params.icon
)

resetTraffic()
RFP.SELECT(5001)
a = lastAction()
check("power tap → TogglePower", a ~= nil and a.action == "TogglePower")

resetTraffic()
RFP.SELECT(5002)
a = lastAction()
check("flame tap at 33 → SetFlame 66", a ~= nil and a.action == "SetFlame" and a.argument == "66", a and a.argument)

resetTraffic()
pushState({ power = 1, flame = 100 })
RFP.SELECT(5002)
a = lastAction()
check("flame tap at 100 wraps → TurnOff", a ~= nil and a.action == "TurnOff", a and a.action)

resetTraffic()
RFP.SELECT(5003)
a = lastAction()
check("flame up tap → IncreaseFlame", a ~= nil and a.action == "IncreaseFlame")

resetTraffic()
RFP.DO_CLICK(300)
a = lastAction()
check("toggle link click → TogglePower", a ~= nil and a.action == "TogglePower")

resetTraffic()
RFP.SELECT(5005)
check("fan tap without FpFan does nothing", lastAction() == nil)

resetTraffic()
pushState({ power = 0, flame = 100 })
icons = proxyNotifies(5001, "ICON_CHANGED")
check("power off → power tile Off", #icons >= 1 and icons[#icons].params.icon == "Off")
icons = proxyNotifies(5002, "ICON_CHANGED")
check("power off → flame tile Off despite flame memory", #icons >= 1 and icons[#icons].params.icon == "Off")

-- ═══ GENERIC ══════════════════════════════════════════════════════════════════

print("\n[generic] toggle tile + relay vocabulary")

loadChild("bond-generic", childProps({ ["Power"] = "-" }))

identify({
  id = "gx1",
  fn = "GENERIC",
  name = "Patio Heater",
  type = "HT",
  actions = { "TurnOn", "TurnOff", "TogglePower", "SetHeat" },
  state = { power = 1 },
})

icons = proxyNotifies(5001, "ICON_CHANGED")
check("tile shows On", #icons >= 1 and icons[#icons].params.icon == "On")
check("relay notified CLOSED", #proxyNotifies(200, "CLOSED") >= 1)

resetTraffic()
RFP.SELECT(5001)
a = lastAction()
check("tile tap → TogglePower", a ~= nil and a.action == "TogglePower")

resetTraffic()
RFP.CLOSE(200)
a = lastAction()
check("relay CLOSE → TurnOn", a ~= nil and a.action == "TurnOn")

resetTraffic()
RFP.OPEN(200)
a = lastAction()
check("relay OPEN → TurnOff", a ~= nil and a.action == "TurnOff")

resetTraffic()
RFP.DO_CLICK(301)
a = lastAction()
check("on link click → TurnOn", a ~= nil and a.action == "TurnOn")

-- ─── Summary ──────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
