-- Load Shedding DRIVER under the shim with a scripted Agent, a fake project
-- (contact sensor, battery, loads, Flight Recorder): licence registration,
-- outage from a watched variable, tier shedding, restore sequencing, the
-- Composer surface, the Flight Recorder history, restore after a simulated
-- reboot mid-outage, a flapping grid, battery never reported, and a licence
-- halt mid-outage that must put every load back.
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
JSON = require("JSON")

-- ── timers ──────────────────────────────────────────────────────────────────
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    clock.timers[id] = nil
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
      if t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and id < bestId)) then
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
local realTime = os.time
local base = 1800000000
os.time = function(t)
  if t then
    return realTime(t)
  end
  return base + math.floor(clock.now / 1000)
end
local realDate = os.date
os.date = function(fmt, t)
  return realDate(fmt, t or os.time())
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end

-- ── persist (in memory, through a real JSON round trip) ────────────────────
local persisted = {}
package.preload["lib.persist"] = function()
  local P = {}
  function P:get(key, default)
    if persisted[key] == nil then
      return default
    end
    return JSON:decode(persisted[key])
  end
  function P:set(key, value)
    tostring_return_period = tostring_return_period or tostring
    persisted[key] = JSON:encode(value)
  end
  function P:delete(key)
    persisted[key] = nil
  end
  function P:reset() end
  return P
end

-- ── fake project ────────────────────────────────────────────────────────────
local AGENT_ID, SELF_ID, FR_ID = 50, 12345, 60
local CONTACT_ID, BATT_ID = 70, 71
local V_CONTACT, V_BATT = 1001, 1002
local sent, fired, vars, props, lists, listeners = {}, {}, {}, {}, {}, {}
local devVars = {
  [CONTACT_ID] = { [V_CONTACT] = { name = "STATE", value = "0" } },
  [BATT_ID] = { [V_BATT] = { name = "BATTERY_LEVEL", value = "" } },
  [101] = { [10] = { name = "STATE", value = "1" } }, -- relay, closed
  [102] = { [20] = { name = "LIGHT_STATE", value = "1" }, [21] = { name = "Brightness Percent", value = "60" } },
  [103] = { [30] = { name = "HVAC_MODE", value = "Heat" }, [31] = { name = "HEAT_SETPOINT_F", value = "70" } },
  [104] = { [40] = { name = "LIGHT_STATE", value = "1" }, [41] = { name = "Brightness Percent", value = "100" } },
}
local devices = {
  [AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
  [SELF_ID] = { deviceName = "Load Shedding", driverFileName = "smartbuildos-load-shedding.c4z" },
  [FR_ID] = { deviceName = "Flight Recorder", driverFileName = "smartbuildos-flight-recorder.c4z" },
  [CONTACT_ID] = { deviceName = "Grid Sensor", roomName = "Garage", driverFileName = "x.c4z" },
  [BATT_ID] = { deviceName = "Battery", roomName = "Garage", driverFileName = "x.c4z" },
  [101] = { deviceName = "Pool Pump", roomName = "Yard", driverFileName = "x.c4z" },
  [102] = { deviceName = "Kitchen Lights", roomName = "Kitchen", driverFileName = "x.c4z" },
  [103] = { deviceName = "Main Thermostat", roomName = "Hall", driverFileName = "x.c4z" },
  [104] = { deviceName = "Spare Lights", roomName = "Den", driverFileName = "x.c4z" },
}
C4.GetDevices = function()
  return devices
end
C4.GetDeviceVariables = function(_, id)
  return devVars[id] or {}
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "Load Shedding"
  end
  return "20261112.000000"
end
C4.SendToDevice = function(_, device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
end
C4.FireEventByID = function(_, id)
  fired[#fired + 1] = id
end
C4.FireEvent = function() end
C4.SetVariable = function(_, name, value)
  vars[name] = value
end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.UpdateProperty = function(_, name, value)
  props[name] = value
  Properties[name] = value
end
C4.UpdatePropertyList = function(_, name, joined)
  lists[name] = joined
end
C4.RegisterVariableListener = function(_, d, v)
  listeners[d .. ":" .. v] = true
end
C4.UnregisterVariableListener = function(_, d, v)
  listeners[d .. ":" .. v] = nil
end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-load-shedding/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    Properties[name] = block:match("<default>(.-)</default>") or ""
  end
end

dofile("drivers/smartbuildos-load-shedding/driver.lua")

local function prop(name)
  return props[name] or Properties[name]
end
local function firedCount(id)
  local n = 0
  for _, f in ipairs(fired) do
    if f == id then
      n = n + 1
    end
  end
  return n
end
local function cmdsTo(id)
  local o = {}
  for _, s in ipairs(sent) do
    if s.device == id then
      o[#o + 1] = s.command
    end
  end
  return table.concat(o, ",")
end
local function frNames()
  local o = {}
  for _, s in ipairs(sent) do
    if s.device == FR_ID and s.command == "RECORD_EVENT" then
      o[#o + 1] = s.params.NAME
    end
  end
  return table.concat(o, "|")
end
local function setProp(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end
local function setVarValue(dev, vid, value)
  devVars[dev][vid].value = value
  OnWatchedVariableChanged(dev, vid, value)
end

print("[1] start: online, licence registered under the SKU, lists filled")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", props["Driver Status"] == "Online")
local reg
for _, s in ipairs(sent) do
  if s.command == "SBOS_REGISTER_DRIVER" then
    reg = s
  end
end
check("registration to the Agent with SKU", reg ~= nil and reg.device == AGENT_ID and reg.params.sku == "SBOS_LOAD_SHEDDING")
EC.SBOS_ENTITLEMENT({ sku = "SBOS_LOAD_SHEDDING", status = "AUTHORIZED_SUBSCRIPTION", license_type = "subscription", registered = "true", subscription_tier = "Professional" })
check("licence painted", prop("License Status"):find("Licensed") ~= nil)
check("device list uses Name (Room) · id", (lists["Load 1 Device"] or ""):find("Pool Pump (Yard) · 101", 1, true) ~= nil, lists["Load 1 Device"])
check("lists start with the none entry", (lists["Outage Device"] or ""):sub(1, 2) == "-,")
check("idle status", prop("Shed Status") == "Normal" and TC.OUTAGE_ACTIVE() == false and TC.LS_ACTIVE() == true)

print("[2] setup from properties")
setProp("Outage Device", "Grid Sensor (Garage) · 70")
setProp("Outage Variable", "STATE")
setProp("Outage When Value Is", "1,closed")
setProp("Battery Device", "Battery (Garage) · 71")
setProp("Battery Variable", "BATTERY_LEVEL")
setProp("Load 1 Device", "Pool Pump (Yard) · 101")
setProp("Load 1 Kind", "Relay")
setProp("Load 1 Tier", "1")
setProp("Load 2 Device", "Kitchen Lights (Kitchen) · 102")
setProp("Load 2 Kind", "Light")
setProp("Load 2 Tier", "2")
setProp("Load 3 Device", "Main Thermostat (Hall) · 103")
setProp("Load 3 Kind", "Thermostat setback")
setProp("Load 3 Tier", "2")
setProp("Load 3 Setback F", "62")
setProp("Load 4 Device", "Spare Lights (Den) · 104")
setProp("Load 4 Kind", "Light")
setProp("Load 4 Tier", "3")
check("outage and battery variables are watched", listeners["70:1001"] and listeners["71:1002"])
check("test mode lists without sending", (function()
  local n = #sent
  EC.TEST_MODE()
  return #sent == n and prop("Last Test Result"):find("8 step") ~= nil
end)(), prop("Last Test Result"))

print("[3] outage: variable flips, tier 1 sheds, events and history")
setVarValue(BATT_ID, V_BATT, "90")
fired = {}
sent = {}
setVarValue(CONTACT_ID, V_CONTACT, "1")
check("Outage Started fired", firedCount(1) == 1)
check("relay opened", cmdsTo(101) == "OPEN")
check("tier 2/3 untouched", cmdsTo(102) == "" and cmdsTo(104) == "")
check("variables", vars["OUTAGE_ACTIVE"] == "True" and vars["TIER_SHED"] == 1 and vars["LOADS_SHED"] == 1 and vars["OUTAGE_STATE"] == "Outage")
check("conditionals", TC.OUTAGE_ACTIVE() and TC.TIER_1_SHED() and not TC.TIER_2_SHED())
check("Flight Recorder told", frNames():find("Outage started", 1, true) ~= nil and frNames():find("Tier 1 shed", 1, true) ~= nil, frNames())

print("[4] battery drops: tiers 2 and 3")
fired = {}
setVarValue(BATT_ID, V_BATT, "45")
check("tier 2 shed with LAST_TIER_SHED=2", TC.TIER_2_SHED() and vars["LAST_TIER_SHED"] == 2 and firedCount(2) == 1)
check("light off, thermostat set back", cmdsTo(102) == "OFF" and cmdsTo(103) == "SET_SETPOINT_HEAT")
setVarValue(BATT_ID, V_BATT, "15")
check("tier 3 shed", TC.TIER_3_SHED() and cmdsTo(104) == "OFF" and vars["BATTERY_PERCENT"] == 15)
check("Summary", prop("Summary"):find("4 load%(s%) shed") ~= nil, prop("Summary"))

print("[5] power returns and holds: restore order tier 3 -> 1")
fired = {}
sent = {}
setVarValue(CONTACT_ID, V_CONTACT, "0")
check("Restore Delayed fired, holding", firedCount(4) == 1 and vars["OUTAGE_STATE"]:find("waiting") ~= nil and cmdsTo(101) == "" and cmdsTo(104) == "")
advance(121000)
check("tier 3 first", cmdsTo(104) == "ON" and cmdsTo(101) == "")
advance(31000)
check("then tier 2", cmdsTo(102) == "RAMP_TO_LEVEL" and cmdsTo(103) == "SET_SETPOINT_HEAT")
advance(31000)
check("tier 1 last, Restored fired", cmdsTo(101) == "CLOSE" and firedCount(3) == 1 and not TC.OUTAGE_ACTIVE())
check("history has the restore", frNames():find("all loads restored", 1, true) ~= nil)

print("[6] flapping grid: no restore until the hold is served in full")
sent = {}
setVarValue(BATT_ID, V_BATT, "90")
setVarValue(CONTACT_ID, V_CONTACT, "1")
setVarValue(CONTACT_ID, V_CONTACT, "0")
advance(60000)
setVarValue(CONTACT_ID, V_CONTACT, "1")
advance(100000)
check("nothing restored through the flap", cmdsTo(101) == "OPEN" and TC.OUTAGE_ACTIVE())
setVarValue(CONTACT_ID, V_CONTACT, "0")
advance(100000)
check("still holding at 100 s of the new hold", cmdsTo(101) == "OPEN")
advance(30000)
check("restored after a full quiet hold", cmdsTo(101) == "OPEN,CLOSE")

print("[7] reboot mid-outage: state survives and the outage still restores")
sent = {}
setVarValue(BATT_ID, V_BATT, "10")
setVarValue(CONTACT_ID, V_CONTACT, "1")
check("shed through tier 3", TC.TIER_3_SHED())
advance(3000) -- persist timer
OnDriverDestroyed()
clock.timers = {}
listeners = {}
fired = {}
vars = {}
-- the controller was down while power came back
devVars[CONTACT_ID][V_CONTACT].value = "0"
clock.now = clock.now + 90000
OnDriverInit()
OnDriverLateInit("DIT_UPDATING")
check("state restored from persistence", TC.TIER_3_SHED() and TC.TIER_1_SHED())
check("input re-read: hold started", vars["OUTAGE_STATE"] ~= nil and vars["OUTAGE_STATE"]:find("waiting") ~= nil, vars["OUTAGE_STATE"])
advance(130000)
advance(70000)
check("every load restored from the saved prior states", cmdsTo(101) == "OPEN,CLOSE" and cmdsTo(104) == "OFF,ON" and cmdsTo(102) == "OFF,RAMP_TO_LEVEL", cmdsTo(101) .. "|" .. cmdsTo(102))
check("back to normal", prop("Shed Status") == "Normal")

print("[8] battery never reported: shed by time")
devVars[BATT_ID][V_BATT].value = ""
setProp("Battery Device", "-")
sent = {}
EC.SET_OUTAGE({ STATE = "On" })
check("Set Outage On starts it without a sensor change", TC.OUTAGE_ACTIVE() and cmdsTo(101) == "OPEN")
advance(16 * 60000)
check("tier 2 after 15 min with no battery data", TC.TIER_2_SHED() and not TC.TIER_3_SHED())
advance(31 * 60000)
check("tier 3 after 45 min", TC.TIER_3_SHED())
EC.SET_OUTAGE({ STATE = "Off" })
advance(500000)
check("restored", not TC.TIER_1_SHED() and cmdsTo(101) == "OPEN,CLOSE")

print("[9] Set Outage is not undone by the sensor poll; commands validate")
EC.SET_OUTAGE({ STATE = "On" })
advance(61000)
check("poll leaves a commanded outage alone", TC.OUTAGE_ACTIVE())
EC.SET_OUTAGE({ STATE = "maybe" })
check("bad STATE refused", prop("Last Refusal"):find("Set Outage: STATE must be On or Off") ~= nil)
EC.SET_BATTERY({ PERCENT = "x" })
check("bad battery refused", prop("Last Refusal"):find("Set Battery") ~= nil)
EC.SHED_TIER({ TIER = "3" })
check("manual shed tier 3", TC.TIER_3_SHED())
EC.RESTORE_ALL()
advance(500000)
check("restore all clears everything", not TC.TIER_1_SHED() and not TC.TIER_2_SHED() and not TC.TIER_3_SHED())

print("[10] programming-window variable pick")
EC.WATCH_OUTAGE_VARIABLE({ VARIABLE = "", WHEN = "1" })
check("empty pick refused", prop("Last Refusal"):find("no variable picked") ~= nil)
EC.WATCH_OUTAGE_VARIABLE({ VARIABLE = "70,1001", WHEN = "" })
check("empty WHEN refused", prop("Last Refusal"):find("WHEN is empty") ~= nil)
devVars[CONTACT_ID][V_CONTACT].value = "0"
EC.WATCH_OUTAGE_VARIABLE({ VARIABLE = "70,1001", WHEN = "1,closed" })
check("persisted pick", persisted["ls_sources_v1"] ~= nil and persisted["ls_sources_v1"]:find("1001", 1, true) ~= nil)

print("[11] re-shed (opt-in)")
EC.RESTORE_ALL()
advance(500000)
setProp("Re-shed Loads Turned On", "Yes")
check("feedback variables watched", listeners["102:20"] and listeners["101:10"])
sent = {}
setVarValue(CONTACT_ID, V_CONTACT, "1")
setVarValue(BATT_ID, V_BATT, "10")
setProp("Battery Device", "Battery (Garage) · 71")
setVarValue(BATT_ID, V_BATT, "10")
advance(10000)
fired = {}
setVarValue(102, 20, "1")
check("a shed light switched on is shed again, event fired", cmdsTo(102):find("OFF,OFF") ~= nil and firedCount(5) == 1, cmdsTo(102))

print("[12] licence halt mid-outage: everything restored, then read-only")
sent = {}
EC.SBOS_ENTITLEMENT({ sku = "SBOS_LOAD_SHEDDING", status = "CLOUD_VALIDATION_REQUIRED", registered = "true", enforcement = "enforce" })
check("uncertain status changes nothing", TC.LS_ACTIVE() and TC.OUTAGE_ACTIVE())
fired = {}
EC.SBOS_ENTITLEMENT({ sku = "SBOS_LOAD_SHEDDING", status = "NOT_ENTITLED", registered = "true", enforcement = "enforce" })
advance(200000)
check("read-only event and status", firedCount(7) == 1 and prop("Shed Status") == "read-only (licence)" and TC.LS_ACTIVE() == false)
check("loads put back before going read-only", cmdsTo(101):find("CLOSE") ~= nil and cmdsTo(104):find("ON") ~= nil and cmdsTo(102):find("RAMP") ~= nil, cmdsTo(101) .. "|" .. cmdsTo(104))
check("nothing left shed", vars["LOADS_SHED"] == 0 and not TC.TIER_1_SHED())
sent = {}
setVarValue(CONTACT_ID, V_CONTACT, "0")
setVarValue(CONTACT_ID, V_CONTACT, "1")
EC.SHED_TIER({ TIER = "1" })
EC.SET_OUTAGE({ STATE = "On" })
check("read-only sheds nothing and says so", cmdsTo(101) == "" and cmdsTo(102) == "" and prop("Last Refusal"):find("read%-only") ~= nil, prop("Last Refusal"))
EC.SBOS_ENTITLEMENT({ sku = "SBOS_LOAD_SHEDDING", status = "NOT_ENTITLED", registered = "true", enforcement = "observe" })
check("observe mode: active again, input re-read, event 8", firedCount(8) == 1 and TC.LS_ACTIVE() and TC.OUTAGE_ACTIVE())

print("[13] bad load definitions are left out, status runs")
setProp("Load 5 Device", "Pool Pump (Yard) · 101")
setProp("Load 5 Kind", "Thermostat setback")
check("thermostat without a setback is not used", select(1, require("loadshed.engine").normaliseLoad({ slot = 5, device_id = 1, kind = "thermostat", tier = 1 })) == nil)
check("print status runs", pcall(EC.PRINT_STATUS))
check("refresh lists runs", pcall(EC.REFRESH_LISTS))

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
