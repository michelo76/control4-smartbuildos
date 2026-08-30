-- Mode Composer MANAGER driver test: loads the real driver.lua under the
-- shim and drives the dealer's journey end to end — init, create Away,
-- include devices, keypad slot gestures through to device commands, LED
-- feedback, dry run, capture, child-button protocol, license wiring.
-- This is the §126 acceptance test in shim form.
--
-- Run from the driver root: make test

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

C4 = C4 or {}
require("c4_shim")

-- ── Deterministic timer module preloaded IN PLACE of the house timer lib ──
local clock = { now = 0, timers = {}, nextSeq = 1 }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  ONE_DAY = 86400000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    clock.timers[id] = nil
  end
  function ExpireTimer(id)
    local t = clock.timers[id]
    if t then
      clock.timers[id] = nil
      t.cb()
    end
  end
  function KillAllTimers()
    clock.timers = {}
  end
  return true
end
local function advance(ms)
  local target = clock.now + ms
  while true do
    local bestId, bestAt
    for id, t in pairs(clock.timers) do
      if t.at <= target and (bestAt == nil or t.at < bestAt) then
        bestId, bestAt = id, t.at
      end
    end
    if not bestId then
      break
    end
    clock.now = bestAt
    local t = clock.timers[bestId]
    if t.every then
      t.at = clock.now + t.every
    else
      clock.timers[bestId] = nil
    end
    t.cb()
  end
  clock.now = target
end

-- ── In-memory persist ──
local persisted = {}
package.preload["lib.persist"] = function()
  local P = {}
  function P:get(key, default)
    if persisted[key] == nil then
      return default
    end
    return persisted[key]
  end
  function P:set(key, value)
    persisted[key] = value
  end
  function P:delete(key)
    persisted[key] = nil
  end
  function P:reset() end
  return P
end

-- ── Fake project ──
local PROJECT = {
  [12345] = {
    deviceName = "Mode Composer",
    driverFileName = "smartbuildos-mode-composer.c4z",
    roomId = 1,
    roomName = "Equipment",
  },
  [900] = { deviceName = "Agent", driverFileName = "smartbuildos.c4z", roomId = 1, roomName = "Equipment" },
}
local DEVICE_VARS = {}
local function addLight(id, name, room)
  PROJECT[id] = { deviceName = name, driverFileName = "control4_ldz.c4i", roomId = 10, roomName = room }
  DEVICE_VARS[id] = { { name = "LIGHT_STATE", value = "1" }, { name = "Brightness Percent", value = "65" } }
end
local function addShade(id, name)
  PROJECT[id] = { deviceName = name, driverFileName = "acme_blind.c4z", roomId = 11, roomName = "Living Room" }
  DEVICE_VARS[id] = { { name = "Level Target", value = "100" } }
end
for i = 1, 20 do
  addLight(1000 + i, "Light " .. i, "Kitchen")
end
for i = 1, 5 do
  addShade(2000 + i, "Shade " .. i)
end
PROJECT[3001] = { deviceName = "Front Door Lock", driverFileName = "acme_lock.c4z", roomId = 12, roomName = "Foyer" }
DEVICE_VARS[3001] = { { name = "LOCK_STATUS", value = "unlocked" } }

function C4:GetDevices()
  return PROJECT
end
function C4:GetDeviceVariables(id)
  return DEVICE_VARS[id] or {}
end
function C4:GetDriverConfigInfo(key)
  return ({ version = "20260829.1", model = "test", name = "test" })[key]
end
function C4:GetVersionInfo()
  return { version = "4.0.0" }
end

-- Dynamic bindings + proxy traffic capture.
local dynamicBindings = {}
function C4:AddDynamicBinding(bindingId, sType, provider, displayName, class)
  dynamicBindings[bindingId] = { class = class, name = displayName, provider = provider }
end
function C4:RemoveDynamicBinding(bindingId)
  dynamicBindings[bindingId] = nil
end
local proxySent = {}
function C4:SendToProxy(idBinding, cmd, params)
  table.insert(proxySent, { binding = idBinding, cmd = cmd, params = params })
end
local deviceSent = {}
function C4:SendToDevice(id, cmd, params)
  table.insert(deviceSent, { device = id, cmd = cmd, params = params })
end
local variables = {}
function C4:SetVariable(name, value)
  variables[name] = value
end
function C4:AddVariable() end
local firedEvents = {}
function C4:AddEvent() end
function C4:FireEventByID(id)
  table.insert(firedEvents, id)
end
function C4:UpdatePropertyList(name, list, default)
  Properties[name .. "__list"] = list
end
function C4:SetPropertyAttribs() end
function C4:RegisterVariableListener()
  return true
end
function C4:GetProxyDevices()
  return {}
end
-- The shim's C4:UpdateProperty is a no-op; assertions need the write-back.
function C4:UpdateProperty(name, value)
  Properties[name] = tostring(value)
end

-- Real UpdateProperty must write back into Properties (the shim's is a
-- no-op and every status assertion would read stale defaults).
Properties = {
  ["Log Level"] = "1 - Error",
  ["Log Mode"] = "Print",
  ["Selected Mode"] = "-",
  ["New Mode Name"] = "",
  ["New Mode Type"] = "Custom Lifestyle",
  ["History Size"] = "100",
  ["Advanced Settings"] = "Hide",
  ["Selected Keypad Slot"] = "-",
}

dofile("drivers/smartbuildos-mode-composer/driver.lua")

-- The handlers global UpdateProperty refuses unknown names; register the
-- rest of the XML properties it will touch.
for _, p in ipairs({
  "Driver Status",
  "Driver Version",
  "Presence Mode",
  "Lifestyle Mode",
  "Mode Color",
  "Mode Enabled",
  "Mode Priority",
  "Mode Inherits From",
  "Transition Style",
  "Departure Countdown Seconds",
  "Hold To Confirm Seconds",
  "Mode Duration Minutes",
  "Slot Tap",
  "Slot Double Tap",
  "Slot Triple Tap",
  "Slot Hold",
  "Slot Long Hold",
  "Slot Very Long Hold",
  "Slot LED Follows",
  "Security User Code",
  "Import Configuration",
  "Add Trigger Rule JSON",
  "Double Tap Window ms",
  "Hold Seconds",
  "Long Hold Seconds",
  "Very Long Hold Seconds",
  "Inter-Command Delay ms",
  "License Status",
  "License Source",
  "Subscription Tier",
  "SmartBuildOS Company",
}) do
  Properties[p] = Properties[p] or ""
end

print("\n[1] Lifecycle: init + late init on an empty config")
OnDriverInit()
OnDriverLateInit()
check("driver online", Properties["Driver Status"] == "Online", Properties["Driver Status"])
check("version painted", Properties["Driver Version"] == "20260829.1")
check(
  "two bootstrap keypad slots",
  (function()
    local n = 0
    for _ in pairs(gConfig.slots) do
      n = n + 1
    end
    return n == 2
  end)()
)
check(
  "license registered with the Agent",
  (function()
    for _, s in ipairs(deviceSent) do
      if s.device == 900 and s.cmd == "SBOS_REGISTER_DRIVER" and s.params.sku == "SBOS_MODE_COMPOSER" then
        return true
      end
    end
    return false
  end)()
)

print("\n[2] Create Away, include devices, dry run")
Properties["New Mode Type"] = "Away"
EC.CREATE_MODE()
local away = nil
for _, m in pairs(gConfig.modes) do
  if m.kind == "AWAY" then
    away = m
  end
end
check("away exists", away ~= nil)
check("selected", Properties["Selected Mode"] == "Away", Properties["Selected Mode"])
EC.Include_All_Lights({ NAME = "Away", SETTING = "off" })
EC.Include_All_Shades({ NAME = "Away", SETTING = "closed" })
EC.Include_Device_In_Mode({ NAME = "Away", DEVICE = 3001, SETTING = "locked" })
EC.Set_Device_Criticality({ NAME = "Away", DEVICE = 3001, CRITICALITY = "CRITICAL" })
local n = 0
for _ in pairs(away.desired_states) do
  n = n + 1
end
check("26 device entries", n == 26, n)
deviceSent = {}
EC.DRY_RUN()
check("dry run sent nothing", #deviceSent == 0, #deviceSent)

print("\n[3] Keypad slot: map hold=Away, press and hold the button")
-- Deterministic slot choice: configure slot_1 and push ITS binding —
-- pairs() order over two slots is hash-seed-dependent in LuaJIT and a
-- mismatched pick made this test flaky.
local slotKey = "slot_1"
local slotBinding = (function()
  local b = require("lib.bindings"):getDynamicBinding("slot", slotKey)
  return b and b.bindingId
end)()
check(
  "BUTTON_LINK binding exists",
  slotBinding ~= nil and dynamicBindings[slotBinding] ~= nil and dynamicBindings[slotBinding].class == "BUTTON_LINK",
  slotBinding
)
Properties["Selected Keypad Slot"] = gConfig.slots[slotKey].name
OPC.Selected_Keypad_Slot(gConfig.slots[slotKey].name)
OPC.Slot_Hold("Activate: Away")
check("gesture stored", gConfig.slots[gSelectedSlotKey].gestures.hold.action == "ACTIVATE")
OPC.Slot_LED_Follows("Global Presence Mode")

deviceSent, proxySent, firedEvents = {}, {}, {}
RFP.DO_PUSH(slotBinding)
advance(1100) -- past the 1s hold threshold: fire-at-crossing
RFP.DO_RELEASE(slotBinding)
advance(10000) -- let the paced queue drain
local lightsOff, lockCmd = 0, nil
for _, s in ipairs(deviceSent) do
  if s.cmd == "OFF" then
    lightsOff = lightsOff + 1
  end
  if s.cmd == "LOCK" then
    lockCmd = s
  end
  if s.cmd == "SET_LEVEL_TARGET" then
    check("shade closed = level 0", s.params.LEVEL_TARGET == 0, s.params.LEVEL_TARGET)
    break
  end
end
check("20 lights off", lightsOff == 20, lightsOff)
check("front door locked", lockCmd ~= nil)
check(
  "away is active",
  gEngine:activeModes().PRESENCE ~= nil and gConfig.modes[gEngine:activeModes().PRESENCE].kind == "AWAY"
)
check("presence variable set", variables["CURRENT_PRESENCE_MODE"] == "Away", variables["CURRENT_PRESENCE_MODE"])
check("presence property painted", Properties["Presence Mode"] == "Away")
check(
  "presence-changed event fired",
  (function()
    for _, id in ipairs(firedEvents) do
      if id == 1 then
        return true
      end
    end
    return false
  end)()
)

print("\n[4] House-button LED shows Away blue")
local colors, match = nil, nil
for _, s in ipairs(proxySent) do
  if s.binding == slotBinding and s.cmd == "BUTTON_COLORS" then
    colors = s.params
  end
  if s.binding == slotBinding and s.cmd == "MATCH_LED_STATE" then
    match = s.params
  end
end
check("colors sent", colors ~= nil and colors.ON_COLOR.COLOR_STR == "2266dd", colors and colors.ON_COLOR.COLOR_STR)
check("LED lit", match ~= nil and match.STATE == "1", match and match.STATE)
local before = #proxySent
gEngine:activate(away.id, "COMPOSER", {}) -- no-op: already active
advance(1000)
check("no LED traffic for a no-op (§17)", #proxySent == before, #proxySent - before)

print("\n[5] History + last-activation detail carry the keypad story")
local line = nil
pcall(function()
  line = require("modes.history").renderLine(gHistory:list(1)[1], function(id)
    return gConfig.modes[id] and gConfig.modes[id].name or id
  end)
end)
check("history recorded via keypad", line ~= nil and line:find("KEYPAD", 1, true) ~= nil, line)
check("gesture in the record", line ~= nil and line:find("hold", 1, true) ~= nil, line)

print("\n[6] Child protocol: MC_GET_STATE / MC_SELECT")
deviceSent = {}
EC.MC_GET_STATE({ requester = "777" })
local statePush = nil
for _, s in ipairs(deviceSent) do
  if s.device == 777 and s.cmd == "MC_STATE" then
    statePush = s.params
  end
end
check("child got MC_STATE", statePush ~= nil)
local decoded = JSON:decode(statePush.modes)
check(
  "payload lists Away as active",
  (function()
    for _, m in ipairs(decoded) do
      if m.name == "Away" and m.active then
        return true
      end
    end
    return false
  end)()
)
-- Create Home, select via child: activates.
Properties["New Mode Type"] = "Home"
Properties["New Mode Name"] = ""
EC.CREATE_MODE()
local homeMode = model_findByName_helper ~= nil and nil
  or (function()
    for _, m in pairs(gConfig.modes) do
      if m.kind == "HOME" then
        return m
      end
    end
  end)()
deviceSent = {}
EC.MC_SELECT({ requester = "777", mode_id = homeMode.id })
advance(5000)
check("navigator select activated Home", gEngine:activeModes().PRESENCE == homeMode.id)

print("\n[7] Capture Current State reads the fake house honestly")
Properties["New Mode Type"] = "Movie"
Properties["New Mode Name"] = ""
EC.CREATE_MODE()
local movie = (function()
  for _, m in pairs(gConfig.modes) do
    if m.kind == "MOVIE" then
      return m
    end
  end
end)()
EC.Capture_Current_State({ NAME = "Movie" })
local captured = 0
local lockEntry = nil
for key, entry in pairs(movie.desired_states) do
  captured = captured + 1
  if key == "3001" then
    lockEntry = entry
  end
end
check("captured the readable devices", captured >= 26, captured)
check(
  "unlocked lock captured as LOCKED (§106)",
  lockEntry ~= nil and lockEntry.state.locked == true,
  lockEntry and tostring(lockEntry.state.locked)
)

print("\n[8] Sensitive action refused until explicitly allowed")
EC.Include_Device_In_Mode({ NAME = "Movie", DEVICE = 3001, SETTING = "unlocked" })
local plan = require("modes.plan").build(gConfig, movie.id, {
  resolve = function(k)
    return nil
  end,
  secrets = {},
})
-- Use the driver's own dry run instead: unsupported entry must appear.
gSelectedModeId = movie.id
deviceSent = {}
EC.TEST_MODE()
advance(10000)
check(
  "unlock never sent without Allow Sensitive Action",
  (function()
    for _, s in ipairs(deviceSent) do
      if s.cmd == "UNLOCK" then
        return false
      end
    end
    return true
  end)()
)

print("\n[9] Export -> import round trip stays intact")
local exported = require("modes.store").export(gConfig)
local json = JSON:encode(exported)
local modesBefore = 0
for _ in pairs(gConfig.modes) do
  modesBefore = modesBefore + 1
end
OPC.Import_Configuration(json)
local modesAfter = 0
for _ in pairs(gConfig.modes) do
  modesAfter = modesAfter + 1
end
check("mode count survives round trip", modesAfter == modesBefore, modesAfter)
OPC.Import_Configuration("{ this is not json")
local modesAfterBad = 0
for _ in pairs(gConfig.modes) do
  modesAfterBad = modesAfterBad + 1
end
check("bad import leaves config untouched", modesAfterBad == modesBefore)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
