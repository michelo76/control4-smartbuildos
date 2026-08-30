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

-- ═══ HEATER ═══════════════════════════════════════════════════════════════════

print("\n[heater] thermostat dial = heat level, Extras timer, derivation")

local model = require("bond.model")
local fns = model.deriveFunctions("HT", { "TurnOn", "TurnOff", "TogglePower", "SetHeat" })
check("HT with SetHeat derives HEATER", #fns == 1 and fns[1] == "HEATER", table.concat(fns, "+"))
fns = model.deriveFunctions("HT", { "TurnOn", "TurnOff", "TogglePower" })
check("HT without SetHeat stays GENERIC", #fns == 1 and fns[1] == "GENERIC", table.concat(fns, "+"))

loadChild("bond-heater", childProps({ ["Heater"] = "-", ["Heat Level"] = "-", ["Timer"] = "-" }))

identify({
  id = "ht1",
  fn = "HEATER",
  name = "Patio Heater",
  type = "HT",
  actions = { "TurnOn", "TurnOff", "TogglePower", "SetHeat", "IncreaseHeat", "DecreaseHeat", "SetTimer" },
  props = { default_auto_timer_s = 7200 },
  state = { power = 1, heat = 60, timer = 0 },
})

local modes = proxyNotifies(5001, "HVAC_MODE_CHANGED")
check("mode Heat while on", #modes >= 1 and modes[#modes].params.MODE == "Heat")
local setpoints = proxyNotifies(5001, "HEAT_SETPOINT_CHANGED")
check(
  "setpoint is the heat level, Celsius-pinned",
  #setpoints >= 1 and setpoints[#setpoints].params.SETPOINT == 60 and setpoints[#setpoints].params.SCALE == "CELSIUS"
)
check("relay CLOSED while on", #proxyNotifies(200, "CLOSED") >= 1)
check("Extras setup announced at identity", #proxyNotifies(5001, "EXTRAS_SETUP_CHANGED") >= 1)

resetTraffic()
RFP.SET_SETPOINT_HEAT(5001, nil, { SETPOINT = 80 })
a = lastAction()
check("dial 80 → SetHeat 80", a ~= nil and a.action == "SetHeat" and a.argument == "80", a and a.argument)

resetTraffic()
RFP.SET_SETPOINT_HEAT(5001, nil, { SETPOINT = 0 })
a = lastAction()
check("dial 0 → TurnOff", a ~= nil and a.action == "TurnOff")

resetTraffic()
RFP.SET_MODE_HVAC(5001, nil, { MODE = "Off" })
a = lastAction()
check("mode Off → TurnOff", a ~= nil and a.action == "TurnOff")
resetTraffic()
RFP.SET_MODE_HVAC(5001, nil, { MODE = "Heat" })
a = lastAction()
check("mode Heat → TurnOn (restores last level)", a ~= nil and a.action == "TurnOn")

resetTraffic()
RFP.SET_TIMER_MINUTES(5001, nil, { VALUE = 30 })
a = lastAction()
check(
  "Extras 30 min → SetTimer 1800s",
  a ~= nil and a.action == "SetTimer" and a.argument == "1800",
  a and a.argument
)
check("Extras command acked with a state notify", #proxyNotifies(5001, "EXTRAS_STATE_CHANGED") >= 1)

resetTraffic()
RFP.DO_CLICK(301)
a = lastAction()
check("heat up link → IncreaseHeat", a ~= nil and a.action == "IncreaseHeat")

resetTraffic()
pushState({ power = 1, heat = 10 })
RFP.DO_CLICK(302)
a = lastAction()
check("heat down at the floor → TurnOff", a ~= nil and a.action == "TurnOff", a and a.action)

resetTraffic()
pushState({ power = 0, heat = 60 })
modes = proxyNotifies(5001, "HVAC_MODE_CHANGED")
check("power off → mode Off", #modes >= 1 and modes[#modes].params.MODE == "Off")
check("relay OPENED when off", #proxyNotifies(200, "OPENED") >= 1)
setpoints = proxyNotifies(5001, "HEAT_SETPOINT_CHANGED")
check("setpoint keeps the remembered level while off", #setpoints >= 1 and setpoints[#setpoints].params.SETPOINT == 60)

resetTraffic()
pushState({ power = 0, heat = 60, timer = 300 })
local extras = proxyNotifies(5001, "EXTRAS_STATE_CHANGED")
check(
  "timer state flows to the Extras tab",
  #extras >= 1 and tostring(extras[#extras].params.XML):find('value="5"') ~= nil
)

-- ═══ KEYPAD ═══════════════════════════════════════════════════════════════════

print("\n[keypad] keystream to events, links, and battery bands")

-- Capture events from here on (earlier sections used a no-op stub).
local firedEvents = {}
function C4:FireEvent(name)
  table.insert(firedEvents, name)
end

loadChild("bond-keypad", childProps({ ["Keys"] = "-", ["Battery"] = "-", ["Signal"] = "-", ["Last Button"] = "-" }))

identify({
  id = "sk1",
  fn = "KEYPAD",
  name = "Bedroom Sidekick",
  type = "SK",
  actions = {},
  props = { keys = 3, model = "SKN-386" },
  state = { battery = 90, signal = 97 },
})

check("keys published", props["Keys"] == "3", props["Keys"])
check("battery band + percent", props["Battery"] == "OK (90%)", props["Battery"])
check("signal published", props["Signal"] == "97%", props["Signal"])

resetTraffic()
firedEvents = {}
EC.BOND_KEYSTREAM({ id = "sk1", event = "TAP", key = "2" })
check("tap fires the button event", firedEvents[#firedEvents] == "Button 2 - Tap", firedEvents[#firedEvents])
check("tap clicks the tap link", #proxyNotifies(211, "DO_CLICK") == 1)

resetTraffic()
firedEvents = {}
EC.BOND_KEYSTREAM({ id = "sk1", event = "DOUBLE_TAP", key = "3" })
check("double tap fires its event", firedEvents[#firedEvents] == "Button 3 - Double Tap")
check("double tap clicks the double tap link", #proxyNotifies(222, "DO_CLICK") == 1)

resetTraffic()
firedEvents = {}
EC.BOND_KEYSTREAM({ id = "sk1", event = "HOLD_START", key = "1" })
check("hold start pushes the hold link", #proxyNotifies(200, "DO_PUSH") == 1)
EC.BOND_KEYSTREAM({ id = "sk1", event = "HOLD_END", key = "1", hold_ms = "1760" })
check("hold end releases the hold link", #proxyNotifies(200, "DO_RELEASE") == 1)
check("both hold events fired", firedEvents[1] == "Button 1 - Hold Start" and firedEvents[2] == "Button 1 - Hold End")

resetTraffic()
firedEvents = {}
EC.BOND_KEYSTREAM({ id = "sk1", event = "HOLD", key = "1", hold_ms = "900" })
check("repeating HOLD updates variables only, no event", #firedEvents == 0 and #proxySent == 0)

EC.BOND_KEYSTREAM({ id = "sk1", event = "TAP" })
check("keystream without a key is ignored", #firedEvents == 0)

firedEvents = {}
pushState({ battery = 25 })
check("battery drop shows the band", props["Battery"] == "Low (25%)", props["Battery"])
check("battery transition fires Battery Low", firedEvents[#firedEvents] == "Battery Low")
firedEvents = {}
pushState({ battery = 8 })
check("critical band fires Battery Critical", firedEvents[#firedEvents] == "Battery Critical")

-- ═══ WEATHER ══════════════════════════════════════════════════════════════════

print("\n[weather] measurements, value connections, transition events")

loadChild(
  "bond-weather",
  childProps({
    ["Temperature"] = "-",
    ["Humidity"] = "-",
    ["Wind Speed"] = "-",
    ["Rain"] = "-",
    ["Sun Level"] = "-",
    ["Solar Battery"] = "-",
    ["Backup Battery"] = "-",
    ["Sensor Status"] = "-",
    ["Last Measured"] = "-",
    ["Display Units"] = "Fahrenheit",
  })
)

firedEvents = {}
identify({
  id = "ws1",
  fn = "WEATHER",
  name = "Patio Breeze",
  type = "WS",
  actions = {},
  props = { model = "BWS-1000" },
  state = {
    status = "idle",
    data_temperature_dc = 212,
    data_humidity_percent = 65,
    data_wind_speed_dms = 32,
    data_rain_mmh = 0,
    data_sun_level = 0,
    is_raining = false,
    battery = 80,
    battery_voltage_dV = 24,
    battery_2 = 77,
    status_flag_no_data = false,
    status_flag_battery_low = false,
  },
})

check("temperature in Fahrenheit by default", props["Temperature"] == "70.2 F", props["Temperature"])
check("humidity published", props["Humidity"] == "65%", props["Humidity"])
check("wind in m/s from dm/s", props["Wind Speed"] == "3.2 m/s", props["Wind Speed"])
check("sun level 0 reads Dark", props["Sun Level"] == "Dark", props["Sun Level"])
check("solar battery with voltage", props["Solar Battery"] == "80% (2.4V)", props["Solar Battery"])
check("first sight is baseline - no transition events", #firedEvents == 0, firedEvents[1])

local temps = proxyNotifies(100, "VALUE_CHANGED")
check("outdoor temperature published to the value connection", #temps >= 1)
check(
  "both scales carried",
  #temps >= 1 and temps[#temps].params.CELSIUS == "21.2" and temps[#temps].params.FAHRENHEIT == "70.2",
  #temps >= 1 and temps[#temps].params.CELSIUS
)
local hums = proxyNotifies(101, "VALUE_CHANGED")
check("humidity published to its value connection", #hums >= 1 and hums[#hums].params.VALUE == 65)

resetTraffic()
firedEvents = {}
pushState({ is_raining = true, data_rain_mmh = 4 })
check("rain transition fires Rain Started", firedEvents[#firedEvents] == "Rain Started", firedEvents[#firedEvents])
check("rain property updated", props["Rain"] == "4 mm/h", props["Rain"])

firedEvents = {}
pushState({ status = "triggered_wind" })
check("status transition fires Wind Triggered", firedEvents[#firedEvents] == "Wind Triggered")

resetTraffic()
firedEvents = {}
pushState({ status_flag_no_data = true })
check("no-data transition fires Data Lost", firedEvents[#firedEvents] == "Data Lost")
check(
  "value connections report unavailable, not stale",
  #proxyNotifies(100, "VALUE_UNAVAILABLE") >= 1 and #proxyNotifies(101, "VALUE_UNAVAILABLE") >= 1
)

resetTraffic()
firedEvents = {}
pushState({ status_flag_no_data = false, data_temperature_dc = 200 })
check("recovery fires Data Restored", firedEvents[#firedEvents] == "Data Restored")
temps = proxyNotifies(100, "VALUE_CHANGED")
check("temperature flows again after recovery", #temps >= 1 and temps[#temps].params.CELSIUS == "20.0")

resetTraffic()
RFP.GET_SENSOR_VALUE(100)
check("a consumer's request republishes the value", #proxyNotifies(100, "VALUE_CHANGED") >= 1)

-- ═══ COLOR LIGHT ══════════════════════════════════════════════════════════════

print("\n[color light] xy<->HSV mapping, CCT clamping and fallback")

-- Deterministic conversion stubs — the driver never does colorimetry math
-- of its own, so the tests pin only that the right helper feeds the right
-- Bond action.
function C4:ColorXYtoHSV(x, y)
  return 120, 80, 100
end
function C4:ColorHSVtoXY(h, s, v)
  return 0.41, 0.42
end
function C4:ColorXYtoCCT(x, y)
  return gTestCct or 3000
end
function C4:ColorCCTtoXY(k)
  return 0.38, 0.39
end

local model = require("bond.model")
local fns = model.deriveFunctions("LT", { "TurnLightOn", "TurnLightOff", "ToggleLight", "SetBrightness", "SetHSV" })
check("SetHSV derives COLOR_LIGHT, not LIGHT", #fns == 1 and fns[1] == "COLOR_LIGHT", table.concat(fns, "+"))

loadChild(
  "bond-color-light",
  childProps({
    ["Light"] = "-",
    ["Brightness"] = "-",
    ["Color"] = "-",
    ["Color Temperature"] = "-",
  })
)

firedEvents = {}
identify({
  id = "ff1",
  fn = "COLOR_LIGHT",
  name = "Patio Firefly",
  type = "LT",
  actions = { "TurnLightOn", "TurnLightOff", "ToggleLight", "SetBrightness", "SetHSV", "SetColorTemp" },
  props = { min_color_temp = 2200, max_color_temp = 6500 },
  state = { light = 1, brightness = 60, hsv = { h = 30, s = 90, v = 60 } },
})

check("brightness published", props["Brightness"] == "60%", props["Brightness"])
check("color property", props["Color"] == "hue 30, saturation 90%", props["Color"])
local colors = proxyNotifies(5001, "LIGHT_COLOR_CHANGED")
check("color notified to the proxy in xy", #colors >= 1)
check(
  "full-color mode with converted coordinates",
  #colors >= 1
    and colors[#colors].params.LIGHT_COLOR_CURRENT_X == 0.41
    and colors[#colors].params.LIGHT_COLOR_CURRENT_COLOR_MODE == 0
)
check("first sight is baseline - no Color Changed event", #firedEvents == 0, firedEvents[1])

resetTraffic()
RFP.SET_COLOR_TARGET(5001, nil, { LIGHT_COLOR_TARGET_X = 0.2, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_MODE = 0 })
a = lastAction()
local colorArg = a ~= nil and JSON:decode(a.argument or "") or nil
check("color wheel → SetHSV", a ~= nil and a.action == "SetHSV")
check(
  "h and s only, no brightness",
  type(colorArg) == "table" and colorArg.h == 120 and colorArg.s == 80 and colorArg.v == nil
)

resetTraffic()
gTestCct = 3000
RFP.SET_COLOR_TARGET(5001, nil, { LIGHT_COLOR_TARGET_X = 0.4, LIGHT_COLOR_TARGET_Y = 0.4, LIGHT_COLOR_TARGET_MODE = 1 })
a = lastAction()
check("CCT picker → SetColorTemp", a ~= nil and a.action == "SetColorTemp" and a.argument == "3000", a and a.argument)

resetTraffic()
gTestCct = 1500
RFP.SET_COLOR_TARGET(
  5001,
  nil,
  { LIGHT_COLOR_TARGET_X = 0.5, LIGHT_COLOR_TARGET_Y = 0.41, LIGHT_COLOR_TARGET_MODE = 1 }
)
a = lastAction()
check("CCT below the device range clamps to min", a ~= nil and a.argument == "2200", a and a.argument)

resetTraffic()
firedEvents = {}
pushState({ light = 1, brightness = 60, hsv = { h = 200, s = 50, v = 60 } })
check("color transition fires Color Changed", firedEvents[#firedEvents] == "Color Changed")

resetTraffic()
pushState({ light = 1, brightness = 60, hsv = { h = 0, s = 0, v = 60 }, color_temp = 2700 })
colors = proxyNotifies(5001, "LIGHT_COLOR_CHANGED")
check(
  "white at a known temperature reports CCT mode",
  #colors >= 1 and colors[#colors].params.LIGHT_COLOR_CURRENT_COLOR_MODE == 1
)

-- Reload as a Firefly WITHOUT ColorTemp: CCT degrades to white.
loadChild(
  "bond-color-light",
  childProps({ ["Light"] = "-", ["Brightness"] = "-", ["Color"] = "-", ["Color Temperature"] = "-" })
)
identify({
  id = "ff2",
  fn = "COLOR_LIGHT",
  name = "Strip",
  actions = { "TurnLightOn", "TurnLightOff", "ToggleLight", "SetBrightness", "SetHSV" },
  state = { light = 1, brightness = 100, hsv = { h = 10, s = 10, v = 100 } },
})
resetTraffic()
gTestCct = 4000
RFP.SET_COLOR_TARGET(
  5001,
  nil,
  { LIGHT_COLOR_TARGET_X = 0.38, LIGHT_COLOR_TARGET_Y = 0.38, LIGHT_COLOR_TARGET_MODE = 1 }
)
a = lastAction()
colorArg = a ~= nil and JSON:decode(a.argument or "") or nil
check(
  "CCT without the feature degrades to white HSV",
  a ~= nil and a.action == "SetHSV" and type(colorArg) == "table" and colorArg.s == 0,
  a and a.action
)

-- ─── Summary ──────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
