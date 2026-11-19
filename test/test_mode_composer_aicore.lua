-- Mode Composer as an AI Core reference driver (sbos.aireport, START mode,
-- `file` given: the driver has no DC_FILENAME).
--
-- The real driver.lua under the shim, the REAL Agent registry and bus, and a
-- fake AI Core that runs every report through AI Core's REAL validator
-- (test/aicore_reporter_harness.lua). Covered:
--   [1] AI Core absent: registered as mode_composer (verified), zero report
--       frames, no error, "Not installed"; modes still activate
--   [2] AI Core appears: describe accepted (controls, vocabulary, two
--       queries, one HIGH action with a bounded string param), state facts
--   [3] events (mode changed, countdown) and diagnostics (blocked, failed)
--   [4] the queries through the real bus
--   [5] the action: real outcome text, refusal of bad params, unknown and
--       disabled modes, declaration_changed, an unverified AI Core
--   [6] AI Core goes away and comes back
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

C4 = C4 or {}
require("c4_shim")
local JSON = require("JSON")
local H = require("aicore_reporter_harness")

-- Deterministic timers IN PLACE of the house timer lib (as test_mode_composer).
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  ONE_DAY = 86400000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    if type(id) == "string" then
      clock.timers[id] = nil
    end
  end
  function KillAllTimers()
    clock.timers = {}
  end
  return true
end
--- Runs the engine's paced queue (and nothing else that is due later).
local function drain(ms)
  local target = clock.now + (ms or 10000)
  while true do
    local bestId, bestAt
    for id, t in pairs(clock.timers) do
      if id:find("^McT") and t.at <= target and (bestAt == nil or t.at < bestAt) then
        bestId, bestAt = id, t.at
      end
    end
    if not bestId then
      break
    end
    clock.now = bestAt
    local t = clock.timers[bestId]
    clock.timers[bestId] = nil
    t.cb()
  end
  clock.now = target
end

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
  return P
end

local SELF = 12345
local PROJECT = {
  [SELF] = {
    deviceName = "Mode Composer",
    driverFileName = "smartbuildos-mode-composer.c4z",
    roomId = 1,
    roomName = "Equipment",
  },
  [H.AGENT] = { deviceName = "Agent", driverFileName = "smartbuildos.c4z", roomId = 1, roomName = "Equipment" },
}
local DEVICE_VARS = {}
for i = 1, 3 do
  PROJECT[1000 + i] =
    { deviceName = "Light " .. i, driverFileName = "control4_ldz.c4i", roomId = 10, roomName = "Kitchen" }
  DEVICE_VARS[1000 + i] = { { name = "LIGHT_STATE", value = "1" }, { name = "Brightness Percent", value = "65" } }
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
  return ({ version = "20261118.1", name = "SmartBuildOS Mode Composer" })[key]
end
function C4:GetVersionInfo()
  return { version = "4.0.0" }
end
function C4:GetDeviceID()
  return SELF
end
function C4:AddDynamicBinding() end
function C4:RemoveDynamicBinding() end
function C4:SendToProxy() end
function C4:SetVariable() end
function C4:AddVariable() end
function C4:AddEvent() end
function C4:FireEventByID() end
function C4:UpdatePropertyList() end
function C4:SetPropertyAttribs() end
function C4:RegisterVariableListener()
  return true
end
function C4:GetProxyDevices()
  return {}
end
local everPainted = {}
function C4:UpdateProperty(name, value)
  Properties[name] = tostring(value)
  if name == "AI Core" then
    everPainted[#everPainted + 1] = tostring(value)
  end
end
Properties = {
  ["Log Level"] = "1 - Error",
  ["Log Mode"] = "Off",
  ["Selected Mode"] = "-",
  ["New Mode Name"] = "",
  ["New Mode Type"] = "Custom Lifestyle",
  ["History Size"] = "100",
  ["Advanced Settings"] = "Hide",
  ["Selected Keypad Slot"] = "-",
  ["AI Core"] = "Searching…",
}

H.install({ selfId = SELF, file = "smartbuildos-mode-composer.c4z" })
dofile("drivers/smartbuildos-mode-composer/driver.lua")
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
  "Devices In Selected Mode",
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
local aireport = require("sbos.aireport")

local function createMode(typeLabel, name)
  Properties["New Mode Type"] = typeLabel
  Properties["New Mode Name"] = name or ""
  EC.CREATE_MODE()
end

print("[1] AI Core absent")
OnDriverInit()
local okLate, lateErr = pcall(OnDriverLateInit)
check("OnDriverLateInit runs", okLate, lateErr)
check(
  "helper in start mode with the given file",
  aireport.mode() == "start" and aireport._state().file == "smartbuildos-mode-composer.c4z"
)
local row = H.registry:find("mode_composer", tostring(SELF))
check("registered with the Agent as mode_composer, verified", row ~= nil and row.verified == true)
check("no report frame while AI Core is absent", H.reportFrames() == 0, H.reportFrames())
check("property: Not installed", Properties["AI Core"] == "Not installed", Properties["AI Core"])
createMode("Home")
createMode("Away")
createMode("Movie")
createMode("Vacation")
EC.Include_All_Lights({ NAME = "Away", SETTING = "off" })
EC.Activate_Mode({ NAME = "Home" })
drain()
check(
  "modes still activate",
  gEngine:activeModes().PRESENCE ~= nil and Properties["Presence Mode"] == "Home",
  Properties["Presence Mode"]
)
check("still no report frame", H.reportFrames() == 0, H.reportFrames())

print("[2] AI Core appears: describe and state")
H.aiRegister()
H.pushDirectory()
local describes = H.reports("describe")
local d = describes[#describes] and describes[#describes].args
check("a describe arrived and AI Core accepted everything so far", d ~= nil and H.allValid(), select(2, H.allValid()))
check(
  "describe: file and sku",
  d.driver.file == "smartbuildos-mode-composer.c4z" and d.driver.sku == "SBOS_MODE_COMPOSER"
)
check(
  "controls: presence and lifestyle mode",
  #d.controls == 2 and d.controls[1].class == "mode" and d.controls[2].class == "mode"
)
check("vocabulary: homeowner words", table.concat(d.vocabulary, "|"):find("away", 1, true) ~= nil)
check(
  "queries: current_modes, recent_activations",
  #d.queries == 2 and d.queries[1].id == "current_modes" and d.queries[2].id == "recent_activations"
)
local act = d.actions[1]
check(
  "one action: activate_mode, risk HIGH, one required bounded string",
  #d.actions == 1
    and act.id == "activate_mode"
    and act.risk == "high"
    and #act.params == 1
    and act.params[1].type == "string"
    and act.params[1].max_len == 64
    and act.params[1].required == true,
  JSON:encode(d.actions)
)
check(
  "property: Found — reporting",
  Properties["AI Core"] == "Found — reporting (v20261118.2)",
  Properties["AI Core"]
)
local states = H.reports("state")
local facts = states[#states].args.facts
check(
  "state: active modes and counts",
  facts.presence_mode == "Home"
    and facts.lifestyle_mode == ""
    and facts.presence_modes == 3
    and facts.lifestyle_modes == 1
    and facts.transitioning == false
    and facts.last_activation_result == "SUCCESS",
  JSON:encode(facts)
)

print("[3] events and diagnostics")
local e0 = #H.reports("event")
EC.Activate_Mode({ NAME = "Away" })
drain()
local evs = H.reports("event")
local changed = nil
for i = e0 + 1, #evs do
  if evs[i].args.type == "mode.changed" then
    changed = evs[i].args
  end
end
check(
  "a mode change is an event",
  changed ~= nil and changed.text == "The presence mode is now Away" and changed.data.previous == "Home",
  changed and JSON:encode(changed)
)
check("state follows", H.reports("state")[#H.reports("state")].args.facts.presence_mode == "Away")
EC.Add_Preflight_Check({ NAME = "Vacation", DEVICE = 3001, EXPECT = "LOCKED", POLICY = "BLOCK" })
local dg0 = #H.reports("diagnostic")
EC.Activate_Mode({ NAME = "Vacation" })
drain()
local dg = H.reports("diagnostic")[dg0 + 1]
check(
  "a blocked activation is a diagnostic",
  dg ~= nil and dg.args.code == "activation.blocked" and dg.args.severity == "warning",
  dg and JSON:encode(dg.args)
)
check("every report valid for AI Core", H.allValid())

print("[4] queries through the bus")
local r = H.aiAsk("mode_composer", "ai.query", { query_id = "current_modes", params = {} })
local names = {}
for _, m in ipairs(r and r.result and r.result.data.modes or {}) do
  names[#names + 1] = m.name .. (m.active and "*" or "")
end
check(
  "current_modes: every mode, the active one marked",
  r
    and r.status == "ok"
    and r.result.data.presence_mode == "Away"
    and table.concat(names, ",") == "Home,Away*,Movie,Vacation",
  table.concat(names, ",")
)
r = H.aiAsk("mode_composer", "ai.query", { query_id = "recent_activations", params = { count = 2 } })
local acts = r and r.result and r.result.data.activations or {}
check(
  "recent_activations: newest first, bounded by count",
  #acts == 2
    and acts[1].mode == "Vacation"
    and acts[1].result == "BLOCKED"
    and acts[2].mode == "Away"
    and acts[2].source == "composer",
  JSON:encode(acts)
)
r = H.aiAsk("mode_composer", "ai.query", { query_id = "recent_activations", params = { count = 11 } })
check("count out of range refused", r and r.error_code == "invalid_args")

print("[5] the declared action")
local hash = aireport.declarationHash()
local function act(params, over)
  local args = {
    action_id = "activate_mode",
    params = params,
    ai_action_id = "act-" .. tostring(os.clock()),
    declaration_hash = hash,
  }
  for k, v in pairs(over or {}) do
    args[k] = v
  end
  return H.aiAsk("mode_composer", "ai.action", args)
end
local sentBefore = H.count("OFF")
r = act({ mode = "Movie" })
check(
  "activate an empty mode: finished at once, real outcome",
  r and r.status == "ok" and r.result.ok == true and r.result.result_text == "Movie is active",
  r and JSON:encode(r)
)
check(
  "…the lifestyle mode really changed",
  gEngine:activeModes().LIFESTYLE ~= nil and Properties["Lifestyle Mode"] == "Movie"
)
EC.Activate_Mode({ NAME = "Home" })
drain()
r = act({ mode = "Away" })
check(
  "activate a mode with device commands: says they are being sent, never 'done'",
  r
    and r.result.ok == true
    and r.result.result_text == "Activating Away: 3 device command(s) are being sent; the outcome follows as an event",
  r and JSON:encode(r)
)
drain()
check(
  "…and then it really is Away (3 lights off)",
  Properties["Presence Mode"] == "Away" and H.count("OFF") == sentBefore + 3,
  H.count("OFF") - sentBefore
)
r = act({ mode = "Away" })
check("already active: said so", r and r.result.ok == true and r.result.result_text == "Away is already active")
r = act({ mode = "Vacation" })
check(
  "blocked by preflight: ok = false, the reason",
  r and r.result.ok == false and r.result.result_text == "Vacation was blocked by its preflight checks",
  r and JSON:encode(r)
)
r = act({ mode = "Garage" })
check("unknown mode: ok = false", r and r.result.ok == false and r.result.result_text == "No mode is named Garage")
for _, m in pairs(gConfig.modes) do
  if m.name == "Movie" then
    m.enabled = false
  end
end
r = act({ mode = "Movie" })
check(
  "a switched-off mode: ok = false",
  r and r.result.ok == false and r.result.result_text == "Movie is switched off",
  r and JSON:encode(r)
)
local before = Properties["Presence Mode"]
r = act({})
check(
  "missing param refused (invalid_args), nothing ran",
  r and r.error_code == "invalid_args" and Properties["Presence Mode"] == before
)
r = act({ mode = string.rep("x", 65) })
check("over-long param refused", r and r.error_code == "invalid_args")
r = act({ mode = "Home\1" })
check("a control character refused", r and r.error_code == "invalid_args")
r = act({ mode = 3 })
check("wrong type refused", r and r.error_code == "invalid_args")
r = act({ mode = "Home", device = 1001 })
check(
  "an extra key (device id) refused",
  r and r.error_code == "invalid_args" and Properties["Presence Mode"] == before
)
r = act({ mode = "Home" }, { action_id = "run_lua" })
check("an undeclared action refused", r and r.error_code == "invalid_args")
-- declaration_changed: any change to the describe voids the approved hash.
aireport.describe({ summary = "House modes, changed." })
r = act({ mode = "Home" })
check(
  "declaration_changed: the old hash refused, nothing ran",
  r
    and r.error_code == "not_permitted"
    and r.result.reason == "declaration_changed"
    and Properties["Presence Mode"] == before,
  r and JSON:encode(r)
)
hash = aireport.declarationHash()
-- An unverified AI Core may not invoke the action.
H.aiRegister({ unverified = true }) -- re-registers; Director gives no answer for the file
H.pushDirectory()
local unverified = H.registry:find("ai_core", tostring(H.AICORE))
r = act({ mode = "Home" })
check(
  "an unverified AI Core is refused (requester_unverified)",
  unverified ~= nil
    and unverified.verified == false
    and r
    and r.error_code == "not_permitted"
    and r.result.reason == "requester_unverified"
    and Properties["Presence Mode"] == before,
  r and JSON:encode(r)
)
H.aiRegister()
H.pushDirectory()
r = act({ mode = "Home" })
drain()
check("verified again: runs", r and r.result.ok == true and Properties["Presence Mode"] == "Home", r and JSON:encode(r))

print("[6] AI Core goes away and comes back")
H.aiRemove()
H.pushDirectory()
check("property: Not installed", Properties["AI Core"] == "Not installed", Properties["AI Core"])
local frames = H.reportFrames()
EC.Activate_Mode({ NAME = "Away" })
drain()
check("no report frame while it is gone", H.reportFrames() == frames)
H.aiRegister()
H.pushDirectory()
check("back: Found — reporting", Properties["AI Core"] == "Found — reporting (v20261118.2)", Properties["AI Core"])
check("every report AI Core ever got was valid", H.allValid())
local outside = {}
for _, v in ipairs(everPainted) do
  if not aireport.isValue(v) then
    outside[#outside + 1] = v
  end
end
check("only closed values were painted", #outside == 0, table.concat(outside, " | "))
OnDriverDestroyed()
check("destroyed: unregistered from the Agent", H.registry:find("mode_composer", tostring(SELF)) == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
