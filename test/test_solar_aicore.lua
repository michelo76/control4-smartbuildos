-- Solar Position reports to AI Core (sbos.aireport, START mode; brief D7a).
--
-- The real driver.lua under the shim (set up as test_solarpos_driver.lua
-- does), the REAL Agent registry and bus and a fake AI Core answering
-- through AI Core's REAL validator (test/aicore_reporter_harness.lua); the
-- shared lifecycle checks are test/aicore_rollout_checks.lua.
-- Driver-specific: describe, the state (phase, daylight, facade counts and
-- NEVER the location), the location diagnostics.
-- Run from the driver root: make test

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")
local R = require("aicore_rollout_checks")
local H = require("aicore_reporter_harness")
local check = R.check

-- ── timers (manual clock, as test_logic_driver.lua) ─────────────────────────
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
-- 2026-06-21 16:00 UTC (noon in Miami): the sun is up.
local base = 1782057600
SOLAR_NOW = function()
  return base + clock.now / 1000
end
local realTime = os.time
os.time = function(t)
  if t then
    return realTime(t)
  end
  return base + math.floor(clock.now / 1000)
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end
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
  return P
end

local SELF = 12345
local projectLat, projectLon = "25.7617", "-80.1918"
C4.GetProjectItems = function(_, kind)
  if kind == "LOCATIONS" then
    return string.format(
      '<item majorversion="4"><id>1</id><name>Project</name><type>1</type><itemdata><latitude>%s</latitude><longitude>%s</longitude><city_name>Lauderhill</city_name></itemdata></item>',
      projectLat,
      projectLon
    )
  end
  return ""
end
C4.GetDeviceID = function()
  return SELF
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "SmartBuildOS Solar Position"
  end
  return "20261118.000001"
end
C4.FireEventByID = function() end
C4.FireEvent = function() end
C4.RegisterSystemEvent = function() end
C4.SetVariable = function() end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end
C4.UpdateProperty = function() end

R.loadProperties("smartbuildos-solar")
Properties["Facade 1 Name"] = "East"
Properties["Facade 1 Azimuth"] = "90"
R.watchPaints()
H.install({ selfId = SELF, file = "smartbuildos-solar.c4z" })
dofile("drivers/smartbuildos-solar/driver.lua")

R.lifecycle({
  H = H,
  moduleId = "solar",
  file = "smartbuildos-solar.c4z",
  sku = "SBOS_SOLAR",
  mode = "start",
  activity = function()
    advance(5 * 60000)
  end,
  describe = function(d)
    local classes = {}
    for _, c in ipairs(d.controls) do
      classes[#classes + 1] = c.class
    end
    check("describe: sun position and facades (weather, sensor)", table.concat(classes, ",") == "weather,weather,sensor")
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: tracking, a phase, daylight, facades counted",
      facts.solar_status == "tracking"
        and type(facts.day_phase) == "string"
        and facts.is_daylight == true
        and facts.facades == 1
        and type(facts.facades_in_sun) == "number",
      JSON:encode(facts)
    )
  end,
  -- the location never leaves the driver: no coordinates, no city
  forbid = { "25.76", "80.19", "Lauderhill", "latitude", "longitude" },
})

print("[5] the location diagnostics")
OnDriverInit()
OnDriverLateInit()
H.aiRegister()
H.pushDirectory()
local function lastDiag()
  local dg = H.reports("diagnostic")
  return dg[#dg] and dg[#dg].args
end
Properties["Location Source"] = "Manual Coordinates"
Properties["Latitude"] = "abc"
OnPropertyChanged("Location Source")
local dg = lastDiag()
check(
  "no usable location: location.unresolved (warning), the driver's own no_location",
  dg ~= nil and dg.code == "location.unresolved" and dg.severity == "warning" and Properties["Solar Status"] == "no_location",
  dg and JSON:encode(dg)
)
check("state: solar_status no_location, no phase", H.reports("state")[#H.reports("state")].args.facts.solar_status == "no_location")
Properties["Location Source"] = "Control4 Project"
OnPropertyChanged("Location Source")
dg = lastDiag()
check("resolved again: location.resolved (info)", dg ~= nil and dg.code == "location.resolved" and dg.severity == "info")
local everything = JSON:encode(H.reports())
check("still no coordinates or city in any report", everything:find("25.76", 1, true) == nil and everything:find("Lauderhill", 1, true) == nil)
check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))

R.finish()
