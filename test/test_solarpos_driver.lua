-- Solar Position DRIVER under the shim: location from the project XML with a
-- manual override, licensing registration and enforcement, a simulated day
-- of one-minute ticks firing every phase and facade event exactly once,
-- variables painted, Director location events re-resolving.
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
-- UTC epoch without os.time's local-time table form.
local function utc(y, m, d, hh, mm)
  if m <= 2 then
    y = y - 1
    m = m + 12
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m - 3) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return (era * 146097 + doe - 719468) * 86400 + (hh or 12) * 3600 + (mm or 0) * 60
end
local realTime = os.time
local base = utc(2026, 6, 21, 4) -- 00:00 EDT, Miami
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
SOLAR_NOW = function()
  return base + clock.now / 1000
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end

-- ── persist (in memory) ─────────────────────────────────────────────────────
local persisted = {}
package.preload["lib.persist"] = function()
  local P = {}
  local EMPTY = {}
  function P:get(key, default)
    if default == nil then
      default = EMPTY
    end
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

-- ── fake Director ───────────────────────────────────────────────────────────
local AGENT_ID = 50
local SELF_ID = 12345
local agentPresent = false
local sent = {}
local fired = {}
local props = {}
local vars = {}
local setVarCalls = 0
local systemEvents = {}
local projectLat, projectLon = "25.7617", "-80.1918"
C4.GetDevices = function()
  local d = { [12] = { deviceName = "Hall Keypad", driverFileName = "keypad.c4z", roomId = 3, roomName = "Hall" } }
  if agentPresent then
    d[AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" }
  end
  return d
end
C4.GetProjectItems = function(_, kind)
  if kind == "LOCATIONS" then
    return string.format(
      '<item majorversion="4"><id>1</id><name>Project</name><type>1</type><itemdata><scale>FAHRENHEIT</scale><latitude>%s</latitude><longitude>%s</longitude><city_name>Lauderhill</city_name></itemdata></item>',
      projectLat,
      projectLon
    )
  end
  return ""
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "Solar Position"
  end
  return "20261109.000000"
end
C4.SendToDevice = function(_, device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
end
C4.FireEventByID = function(_, id)
  fired[#fired + 1] = id
end
C4.FireEvent = function() end
C4.RegisterSystemEvent = function(_, id, dev)
  systemEvents[#systemEvents + 1] = { id = id, dev = dev }
end
C4.SetVariable = function(_, name, value)
  vars[name] = value
  setVarCalls = setVarCalls + 1
end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.UpdateProperty = function(_, name, value)
  props[name] = value
  Properties[name] = value
end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-solar/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    Properties[name] = default
  end
end

dofile("drivers/smartbuildos-solar/driver.lua")

local function prop(name)
  return props[name] or Properties[name]
end
local function count(id)
  local n = 0
  for _, f in ipairs(fired) do
    if f == id then
      n = n + 1
    end
  end
  return n
end
local function lastSent(command)
  local out
  for _, s in ipairs(sent) do
    if s.command == command then
      out = s
    end
  end
  return out
end

print("[1] starts: location from the project, tracking at once, no Agent yet")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", props["Driver Status"] == "Online")
check(
  "location from the project with its city label",
  prop("Location"):find("Lauderhill %(project: 25.7617, %-80.1918%)") ~= nil,
  prop("Location")
)
check("status tracking", prop("Solar Status") == "tracking", prop("Solar Status"))
check(
  "midnight: night phase, not daylight",
  vars["DAY_PHASE"] == "night" and vars["IS_DAYLIGHT"] == false,
  vars["DAY_PHASE"]
)
check("elevation well below the horizon", tonumber(vars["SUN_ELEVATION"]) < -20, vars["SUN_ELEVATION"])
check("Sun Now painted", prop("Sun Now"):find("elevation") ~= nil, prop("Sun Now"))
check("Today painted with next sunrise", prop("Today"):find("next sunrise") ~= nil, prop("Today"))
check(
  "minutes to sunrise positive",
  tonumber(vars["MINUTES_TO_SUNRISE"]) > 0 and tonumber(vars["MINUTES_TO_SUNRISE"]) < 24 * 60
)
check("location source variable", vars["LOCATION_SOURCE"] == "project")
check("system events 52/53/54 registered system-wide", #systemEvents == 3 and systemEvents[1].dev == 0)
check("licence: No Agent", prop("License Status") == "No SmartBuildOS Agent Found", prop("License Status"))
check("no Location Changed event at startup", count(12) == 0)
check("conditionals: not daylight, not golden", TC.IS_DAYLIGHT() == false and TC.IS_GOLDEN_HOUR() == false)
check("minute tick armed", clock.timers["SolarTick"] ~= nil)

print("[2] the Agent appears: licence registration")
agentPresent = true
EC.REGISTER_NOW()
check(
  "registered under SBOS_SOLAR",
  lastSent("SBOS_REGISTER_DRIVER") ~= nil and lastSent("SBOS_REGISTER_DRIVER").params.sku == "SBOS_SOLAR"
)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_SOLAR",
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "subscription",
  registered = "true",
  subscription_tier = "Professional",
  company_name = "Skynet AV",
})
check(
  "licence painted",
  prop("License Status"):find("Licensed") ~= nil and prop("Subscription Tier") == "Professional",
  prop("License Status")
)

print("[3] facades configured, then a full Miami June day at one-minute ticks")
Properties["Facade 1 Name"] = "East"
Properties["Facade 1 Azimuth"] = "90"
Properties["Facade 2 Name"] = "South"
Properties["Facade 2 Azimuth"] = "180"
Properties["Facade 3 Name"] = "West"
Properties["Facade 3 Azimuth"] = "270"
for _, p in ipairs({
  "Facade 1 Name",
  "Facade 1 Azimuth",
  "Facade 2 Name",
  "Facade 2 Azimuth",
  "Facade 3 Name",
  "Facade 3 Azimuth",
}) do
  OnPropertyChanged(p)
end
check(
  "Facade Status lists the three in shade at midnight",
  prop("Facade Status") == "East: shade; South: shade; West: shade",
  prop("Facade Status")
)
fired = {}
advance(24 * 60 * 60 * 1000)
check("Civil Dawn once", count(2) == 1, count(2))
check("Golden Hour Started twice", count(1) == 2, count(1))
check("Civil Dusk once", count(3) == 1, count(3))
check("Sun Hits/Leaves Facade 1 once each", count(4) == 1 and count(5) == 1, count(4) .. "/" .. count(5))
check("Sun Hits/Leaves Facade 2 once each", count(6) == 1 and count(7) == 1, count(6) .. "/" .. count(7))
check("Sun Hits/Leaves Facade 3 once each", count(8) == 1 and count(9) == 1, count(8) .. "/" .. count(9))
check("facade 4 (unnamed) never fires", count(10) == 0 and count(11) == 0)
check("no Location Changed during the day", count(12) == 0)
check(
  "order: dawn before east hit, west left before dusk",
  (function()
    local pos = {}
    for i, id in ipairs(fired) do
      pos[id] = pos[id] or i
    end
    return pos[2] < pos[4] and pos[9] < pos[3]
  end)()
)
check("back to night at the end", vars["DAY_PHASE"] == "night")

print("[4] midday check: variables and conditionals")
advance(13 * 60 * 60 * 1000 + 20 * 60 * 1000) -- ~13:20 EDT next day
check(
  "day phase, daylight, high sun",
  vars["DAY_PHASE"] == "day" and vars["IS_DAYLIGHT"] == true and tonumber(vars["SUN_ELEVATION"]) > 80,
  vars["SUN_ELEVATION"]
)
check("conditional IS_DAYLIGHT true", TC.IS_DAYLIGHT() == true)
check("NEXT_SUNSET is a local HH:MM", tostring(vars["NEXT_SUNSET"]):match("^%d%d:%d%d$") ~= nil, vars["NEXT_SUNSET"])
check(
  "minutes to sunset under 8 hours",
  tonumber(vars["MINUTES_TO_SUNSET"]) > 0 and tonumber(vars["MINUTES_TO_SUNSET"]) < 480,
  vars["MINUTES_TO_SUNSET"]
)

print("[5] manual coordinates override the project")
fired = {}
Properties["Location Source"] = "Manual Coordinates"
Properties["Latitude"] = "51.4779"
Properties["Longitude"] = "-0.0015"
OnPropertyChanged("Location Source")
check("location now manual", prop("Location"):find("manual: 51.4779") ~= nil, prop("Location"))
check("Location Changed fired once", count(12) == 1, count(12))
check("LOCATION_SOURCE manual", vars["LOCATION_SOURCE"] == "manual")
Properties["Latitude"] = "abc"
OnPropertyChanged("Latitude")
check(
  "invalid manual coordinates: no_location with a reason",
  prop("Solar Status") == "no_location" and prop("Last Solar Error"):find("Manual Coordinates needs") ~= nil,
  prop("Last Solar Error")
)
check("Location Changed fired for the loss too", count(12) == 2)
check("tick without a location is a no-op", EC.RECOMPUTE() == nil and prop("Solar Status") == "no_location")

print("[6] Director location event re-resolves the project location")
Properties["Location Source"] = "Control4 Project"
OnPropertyChanged("Location Source")
check("back on the project", prop("Location"):find("project: 25.7617") ~= nil)
fired = {}
projectLat = "26.1224"
OSE.OnLatitudeChanged()
check("new project latitude picked up", prop("Location"):find("26.1224") ~= nil, prop("Location"))
check("Location Changed fired", count(12) == 1)
fired = {}
OSE.OnZipcodeChanged()
check("same coordinates again: no event", count(12) == 0)

print("[7] licence enforcement halts the tick; uncertainty never does")
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_SOLAR",
  status = "CLOUD_VALIDATION_REQUIRED",
  registered = "true",
  enforcement = "enforce",
})
check("uncertain + enforce keeps tracking", prop("Solar Status") == "tracking")
EC.SBOS_ENTITLEMENT({ sku = "SBOS_SOLAR", status = "NOT_ENTITLED", registered = "true", enforcement = "enforce" })
check("definitive denial + enforce: unlicensed", prop("Solar Status") == "unlicensed", prop("Solar Status"))
local elBefore = vars["SUN_ELEVATION"]
advance(5 * 60 * 1000)
check("sun variables frozen while halted", vars["SUN_ELEVATION"] == elBefore)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_SOLAR", status = "NOT_ENTITLED", registered = "true", enforcement = "observe" })
check("observe mode resumes tracking", prop("Solar Status") == "tracking")
EC.SBOS_ENTITLEMENT({ sku = "SBOS_SOLAR", status = "AUTHORIZED_SUBSCRIPTION", registered = "true" })

print("[8] actions and commands do not throw")
local okP = pcall(function()
  EC.PRINT_STATUS()
  EC.RECOMPUTE_SUN()
  EC.REDISCOVER_LOCATION()
  EC.REFRESH_STATUS()
end)
check("actions run", okP)
OnDriverDestroyed()
check("timers cancelled on destroy", clock.timers["SolarTick"] == nil and clock.timers["SolarStatus"] == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
